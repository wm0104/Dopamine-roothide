//
//  DOConfigBackup.m
//  Dopamine
//

#import "DOConfigBackup.h"
#import "DOUIManager.h"

#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const DOConfigBackupErrorDomain = @"DOConfigBackupErrorDomain";

static NSString *const DOConfigBackupDirectoryPathKey = @"DOConfigBackupDirectoryPath";
static NSString *const DOConfigBackupNamePrefix = @"Configuration-";
static NSString *const DOConfigBackupManifestName = @"manifest.json";

#define DO_CONFIG_BACKUP_MAX_COUNT 2

static const unsigned long long DOConfigBackupMaximumFileBytes = 32ULL * 1024ULL * 1024ULL;
static const unsigned long long DOConfigBackupMaximumTotalBytes = 128ULL * 1024ULL * 1024ULL;

#pragma mark - Errors

static NSError *DOConfigBackupErrorWithKey(NSInteger code, NSString *key)
{
    return [NSError errorWithDomain:DOConfigBackupErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(key) }];
}

static NSError *DOConfigBackupErrorForCode(NSInteger code)
{
    switch (code) {
        case 1: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Nothing");
        case 2: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Write");
        case 3: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Read");
        case 5: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Invalid");
        case 7: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Empty");
        default: return DOConfigBackupErrorWithKey(code, @"Backup_Error_Corrupted");
    }
}

#pragma mark - Jailbreak paths

static NSString *DOJailbreakRootPath(void)
{
    static NSString *cachedRoot = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleContainer = @"/var/containers/Bundle/Application";
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleContainer error:nil];
        for (NSString *item in items) {
            if (![item hasPrefix:@".jbroot-"] || item.length != 24) {
                continue;
            }
            cachedRoot = [bundleContainer stringByAppendingPathComponent:item];
            break;
        }
    });
    return cachedRoot;
}

#pragma mark - Backup roots

// The same seven groups Irisin backs up: tweak and system configuration under the real
// /var/mobile/Library (the bootstrap links its own var to it) plus the APT source lists
// that live inside the jailbreak root.
static NSArray<NSDictionary<NSString *, NSString *> *> *DOBackupRoots(void)
{
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *roots = [NSMutableArray array];
    NSString *libraryPath = @"/var/mobile/Library";
    NSArray<NSString *> *configNames = @[ @"Preferences", @"ControlCenter", @"CallAssist", @"RootHide", @"CallAssistActivation", @"Snapper3" ];
    for (NSString *name in configNames) {
        [roots addObject:@{
            @"relative": [@"config" stringByAppendingPathComponent:name],
            @"source": [libraryPath stringByAppendingPathComponent:name],
        }];
    }

    NSString *jailbreakRoot = DOJailbreakRootPath();
    if (jailbreakRoot.length > 0) {
        [roots addObject:@{
            @"relative": @"sources/sources.list.d",
            @"source": [jailbreakRoot stringByAppendingPathComponent:@"etc/apt/sources.list.d"],
        }];
    }

    return roots;
}

#pragma mark - Filesystem helpers

static NSArray<NSString *> *DOEnumerateRelativePaths(NSString *rootPath)
{
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *rootPrefix = [rootPath stringByAppendingString:@"/"];
    NSURL *rootURL = [NSURL fileURLWithPath:rootPath isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:rootURL includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey] options:0 errorHandler:nil];
    for (NSURL *url in enumerator) {
        id isSymbolicLink = nil;
        [url getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if ([isSymbolicLink boolValue]) {
            [enumerator skipDescendants];
            continue;
        }

        NSString *path = url.path;
        if (![path hasPrefix:rootPrefix]) {
            continue;
        }
        [relativePaths addObject:[path substringFromIndex:rootPrefix.length]];
    }
    return relativePaths;
}

static void DOFixItemOwnership(NSString *path, BOOL isDirectory)
{
    const char *filePath = path.fileSystemRepresentation;
    if (!filePath) {
        return;
    }
    if ([path hasPrefix:@"/var/mobile/"]) {
        chown(filePath, 501, 501);
    }
    chmod(filePath, isDirectory ? 0755 : 0644);
}

static void DOFixTreeOwnership(NSString *rootPath)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:rootPath isDirectory:&isDirectory]) {
        return;
    }
    DOFixItemOwnership(rootPath, isDirectory);

    for (NSString *relativePath in DOEnumerateRelativePaths(rootPath)) {
        NSString *path = [rootPath stringByAppendingPathComponent:relativePath];
        BOOL itemIsDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&itemIsDirectory]) {
            continue;
        }
        DOFixItemOwnership(path, itemIsDirectory);
    }
}

static BOOL DOCopyTree(NSString *sourcePath, NSString *destinationPath, NSUInteger *fileCount, unsigned long long *totalBytes, NSError *_Nullable *_Nullable error)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:destinationPath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    for (NSString *relativePath in DOEnumerateRelativePaths(sourcePath)) {
        NSString *fromPath = [sourcePath stringByAppendingPathComponent:relativePath];
        NSString *toPath = [destinationPath stringByAppendingPathComponent:relativePath];

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:fromPath isDirectory:&isDirectory]) {
            continue;
        }

        if (isDirectory) {
            if (![fileManager createDirectoryAtPath:toPath withIntermediateDirectories:YES attributes:nil error:error]) {
                return NO;
            }
            continue;
        }

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:fromPath error:nil];
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        if (size > DOConfigBackupMaximumFileBytes || (totalBytes != NULL && *totalBytes + size > DOConfigBackupMaximumTotalBytes)) {
            if (error) {
                *error = DOConfigBackupErrorForCode(2);
            }
            return NO;
        }

        if (![fileManager createDirectoryAtPath:[toPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:error]) {
            return NO;
        }
        [fileManager removeItemAtPath:toPath error:nil];
        if (![fileManager copyItemAtPath:fromPath toPath:toPath error:error]) {
            return NO;
        }

        if (fileCount) {
            *fileCount += 1;
        }
        if (totalBytes) {
            *totalBytes += size;
        }
    }

    return YES;
}

#pragma mark - DOConfigBackup

@interface DOConfigBackup ()
+ (void)removeOldBackupsBeyond:(NSUInteger)maximumCount;
@end

@implementation DOConfigBackup

+ (NSURL *)defaultBackupDirectoryURL
{
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    if (!documentsURL) {
        documentsURL = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    }
    return [documentsURL URLByAppendingPathComponent:@"ConfigurationBackups" isDirectory:YES];
}

+ (NSString *)backupDirectory
{
    return [self backupDirectoryURL].path;
}

+ (NSURL *)configuredBackupDirectoryURL
{
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:DOConfigBackupDirectoryPathKey];
    if (path.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

+ (void)setConfiguredBackupDirectoryURL:(NSURL *)url
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!url.path.length) {
        [defaults removeObjectForKey:DOConfigBackupDirectoryPathKey];
    } else {
        [defaults setObject:url.path forKey:DOConfigBackupDirectoryPathKey];
    }
    [defaults synchronize];
}

+ (NSURL *)backupDirectoryURL
{
    NSURL *directoryURL = [self configuredBackupDirectoryURL] ?: [self defaultBackupDirectoryURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    return directoryURL;
}

+ (NSArray<NSDictionary *> *)availableBackups
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *basePath = ([self configuredBackupDirectoryURL] ?: [self defaultBackupDirectoryURL]).path;
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:basePath error:nil];
    NSMutableArray<NSDictionary *> *backups = [NSMutableArray array];

    for (NSString *entry in entries) {
        if (![entry hasPrefix:DOConfigBackupNamePrefix]) {
            continue;
        }

        NSString *path = [basePath stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }

        NSData *manifestData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:DOConfigBackupManifestName]];
        if (!manifestData) {
            continue;
        }
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
        id totalBytes = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"totalBytes"] : nil;
        [backups addObject:@{
            @"path": path,
            @"name": entry,
            @"date": attributes[NSFileModificationDate] ?: [NSDate date],
            @"size": [totalBytes isKindOfClass:[NSNumber class]] ? totalBytes : @0,
        }];
    }

    [backups sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        return [second[@"name"] compare:first[@"name"]];
    }];

    return backups;
}

+ (void)removeOldBackupsBeyond:(NSUInteger)maximumCount
{
    NSArray<NSDictionary *> *backups = [self availableBackups];
    if (backups.count <= maximumCount) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger index = maximumCount; index < backups.count; index++) {
        [fileManager removeItemAtPath:backups[index][@"path"] error:nil];
    }
}

+ (BOOL)createBackupWithError:(NSError **)error
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *basePath = [self backupDirectoryURL].path;
    if (basePath.length == 0) {
        if (error) {
            *error = DOConfigBackupErrorForCode(2);
        }
        return NO;
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.timeZone = [NSTimeZone localTimeZone];
    dateFormatter.dateFormat = @"yyyyMMdd-HHmmss";

    NSString *baseName = [DOConfigBackupNamePrefix stringByAppendingString:[dateFormatter stringFromDate:[NSDate date]]];
    NSString *folderPath = [basePath stringByAppendingPathComponent:baseName];
    for (NSUInteger suffix = 2; [fileManager fileExistsAtPath:folderPath]; suffix++) {
        folderPath = [basePath stringByAppendingPathComponent:[baseName stringByAppendingFormat:@"-%lu", (unsigned long)suffix]];
    }

    NSError *createError = nil;
    if (![fileManager createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&createError]) {
        if (error) {
            *error = createError ?: DOConfigBackupErrorForCode(2);
        }
        return NO;
    }

    NSUInteger fileCount = 0;
    unsigned long long totalBytes = 0;
    NSMutableArray<NSString *> *capturedRoots = [NSMutableArray array];

    for (NSDictionary *root in DOBackupRoots()) {
        NSString *sourcePath = root[@"source"];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:sourcePath isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }

        NSString *destinationPath = [folderPath stringByAppendingPathComponent:root[@"relative"]];
        NSError *copyError = nil;
        if (!DOCopyTree(sourcePath, destinationPath, &fileCount, &totalBytes, &copyError)) {
            [fileManager removeItemAtPath:folderPath error:nil];
            if (error) {
                *error = copyError ?: DOConfigBackupErrorForCode(2);
            }
            return NO;
        }

        [capturedRoots addObject:root[@"relative"]];
    }

    if (fileCount == 0) {
        [fileManager removeItemAtPath:folderPath error:nil];
        if (error) {
            *error = DOConfigBackupErrorForCode(1);
        }
        return NO;
    }

    NSDateFormatter *isoFormatter = [[NSDateFormatter alloc] init];
    isoFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    isoFormatter.timeZone = [NSTimeZone localTimeZone];
    isoFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";

    id appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSDictionary *manifest = @{
        @"version": [appVersion isKindOfClass:[NSString class]] ? appVersion : @"",
        @"date": [isoFormatter stringFromDate:[NSDate date]],
        @"roots": capturedRoots,
        @"fileCount": @(fileCount),
        @"totalBytes": @(totalBytes),
    };

    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (!manifestData || ![manifestData writeToFile:[folderPath stringByAppendingPathComponent:DOConfigBackupManifestName] atomically:YES]) {
        [fileManager removeItemAtPath:folderPath error:nil];
        if (error) {
            *error = DOConfigBackupErrorForCode(2);
        }
        return NO;
    }

    [self removeOldBackupsBeyond:DO_CONFIG_BACKUP_MAX_COUNT];
    return YES;
}

+ (BOOL)restoreBackupAtPath:(NSString *)path error:(NSError **)error
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        if (error) {
            *error = DOConfigBackupErrorForCode(5);
        }
        return NO;
    }
    if (![fileManager fileExistsAtPath:[path stringByAppendingPathComponent:DOConfigBackupManifestName]]) {
        if (error) {
            *error = DOConfigBackupErrorForCode(5);
        }
        return NO;
    }

    NSUInteger restoredFileCount = 0;

    for (NSDictionary *root in DOBackupRoots()) {
        NSString *sourcePath = [path stringByAppendingPathComponent:root[@"relative"]];
        BOOL sourceIsDirectory = NO;
        if (![fileManager fileExistsAtPath:sourcePath isDirectory:&sourceIsDirectory] || !sourceIsDirectory) {
            continue;
        }

        NSString *destinationPath = root[@"source"];
        BOOL destinationIsDirectory = NO;
        if (![fileManager fileExistsAtPath:destinationPath isDirectory:&destinationIsDirectory]) {
            if (![fileManager createDirectoryAtPath:destinationPath withIntermediateDirectories:YES attributes:nil error:error]) {
                return NO;
            }
        } else if (!destinationIsDirectory) {
            if (error) {
                *error = DOConfigBackupErrorForCode(5);
            }
            return NO;
        }

        NSUInteger copiedCount = 0;
        if (!DOCopyTree(sourcePath, destinationPath, &copiedCount, NULL, error)) {
            return NO;
        }
        restoredFileCount += copiedCount;
        DOFixTreeOwnership(destinationPath);
    }

    if (restoredFileCount == 0) {
        if (error) {
            *error = DOConfigBackupErrorForCode(7);
        }
        return NO;
    }

    return YES;
}

@end
