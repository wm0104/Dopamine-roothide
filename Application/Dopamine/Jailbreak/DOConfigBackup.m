//
//  DOConfigBackup.m
//  Dopamine
//

#import "DOConfigBackup.h"
#import "DOUIManager.h"

#import <dirent.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <limits.h>
#import <string.h>
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

// The bootstrap keeps its own var as a platform link, so the real path is only reachable
// through that link. Same anchor rule the Irisin backup engine uses.
static NSString *DOPlatformDirectory(NSString *path)
{
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved)) {
        return [NSString stringWithUTF8String:resolved];
    }
    return path;
}

#pragma mark - Backup roots

static NSArray<NSDictionary<NSString *, id> *> *DOBackupRoots(void)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *roots = [NSMutableArray array];
    NSString *libraryPath = [DOPlatformDirectory(@"/var") stringByAppendingPathComponent:@"mobile/Library"];
    NSArray<NSString *> *configNames = @[ @"Preferences", @"ControlCenter", @"CallAssist", @"RootHide", @"CallAssistActivation", @"Snapper3" ];

    for (NSString *name in configNames) {
        [roots addObject:@{
            @"relative": [@"config" stringByAppendingPathComponent:name],
            @"source": [libraryPath stringByAppendingPathComponent:name],
        }];
    }

    NSString *jailbreakRoot = DOJailbreakRootPath();
    NSString *sourcesPath = jailbreakRoot.length > 0 ? [jailbreakRoot stringByAppendingPathComponent:@"etc/apt/sources.list.d"] : [DOPlatformDirectory(@"/etc") stringByAppendingPathComponent:@"apt/sources.list.d"];
    [roots addObject:@{
        @"relative": @"sources/sources.list.d",
        @"source": sourcesPath,
    }];

    return roots;
}

#pragma mark - POSIX helpers

static BOOL DOPathIsDirectory(NSString *path)
{
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        return NO;
    }
    return S_ISDIR(info.st_mode);
}

static void DOApplyOwnership(NSString *path, BOOL isDirectory)
{
    const char *filePath = path.fileSystemRepresentation;
    if (!filePath) {
        return;
    }
    if ([path hasPrefix:@"/var/mobile/"] || [path hasPrefix:@"/private/var/mobile/"]) {
        chown(filePath, 501, 501);
    }
    chmod(filePath, isDirectory ? 0755 : 0644);
}

// Mirrors the Irisin tree walk: entries are read with lstat, links and special files are
// never followed, regular files are copied as-is.
static BOOL DOCopyDirectoryContents(NSString *sourceDirectory, NSString *destinationDirectory, NSUInteger *fileCount, unsigned long long *totalBytes, NSError *_Nullable *_Nullable error)
{
    DIR *directory = opendir(sourceDirectory.fileSystemRepresentation);
    if (!directory) {
        if (error) {
            *error = DOConfigBackupErrorForCode(3);
        }
        return NO;
    }

    BOOL succeeded = YES;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }

        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (name.length == 0) {
            continue;
        }
        NSString *sourcePath = [sourceDirectory stringByAppendingPathComponent:name];
        NSString *destinationPath = [destinationDirectory stringByAppendingPathComponent:name];

        struct stat info;
        if (lstat(sourcePath.fileSystemRepresentation, &info) != 0) {
            continue;
        }
        if (S_ISLNK(info.st_mode)) {
            continue;
        }

        if (S_ISDIR(info.st_mode)) {
            mkdir(destinationPath.fileSystemRepresentation, 0755);
            if (!DOCopyDirectoryContents(sourcePath, destinationPath, fileCount, totalBytes, error)) {
                succeeded = NO;
                break;
            }
            continue;
        }

        if (!S_ISREG(info.st_mode)) {
            continue;
        }

        unsigned long long size = (unsigned long long)info.st_size;
        if (size > DOConfigBackupMaximumFileBytes || (totalBytes != NULL && *totalBytes + size > DOConfigBackupMaximumTotalBytes)) {
            if (error) {
                *error = DOConfigBackupErrorForCode(2);
            }
            succeeded = NO;
            break;
        }

        int sourceFD = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (sourceFD < 0) {
            if (error) {
                *error = DOConfigBackupErrorForCode(3);
            }
            succeeded = NO;
            break;
        }

        unlink(destinationPath.fileSystemRepresentation);
        int destinationFD = open(destinationPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (destinationFD < 0) {
            close(sourceFD);
            if (error) {
                *error = DOConfigBackupErrorForCode(2);
            }
            succeeded = NO;
            break;
        }

        char buffer[64 * 1024];
        BOOL copied = YES;
        while (YES) {
            ssize_t readBytes = read(sourceFD, buffer, sizeof(buffer));
            if (readBytes < 0) {
                copied = NO;
                break;
            }
            if (readBytes == 0) {
                break;
            }

            ssize_t writtenBytes = 0;
            while (writtenBytes < readBytes) {
                ssize_t result = write(destinationFD, buffer + writtenBytes, (size_t)(readBytes - writtenBytes));
                if (result <= 0) {
                    copied = NO;
                    break;
                }
                writtenBytes += result;
            }
            if (!copied) {
                break;
            }
        }

        fsync(destinationFD);
        close(destinationFD);
        close(sourceFD);

        if (!copied) {
            if (error) {
                *error = DOConfigBackupErrorForCode(2);
            }
            succeeded = NO;
            break;
        }

        DOApplyOwnership(destinationPath, NO);
        if (fileCount) {
            {
                *fileCount += 1;
            }
        }
        if (totalBytes) {
            *totalBytes += size;
        }
    }

    closedir(directory);
    return succeeded;
}

static BOOL DORemoveTree(NSString *path)
{
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        return YES;
    }
    if (!S_ISDIR(info.st_mode)) {
        return unlink(path.fileSystemRepresentation) == 0;
    }

    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) {
        return NO;
    }

    struct dirent *entry = NULL;
    BOOL succeeded = YES;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name.length) {
            continue;
        }
        if (!DORemoveTree([path stringByAppendingPathComponent:name])) {
            succeeded = NO;
        }
    }
    closedir(directory);

    if (rmdir(path.fileSystemRepresentation) != 0) {
        succeeded = NO;
    }
    return succeeded;
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
        if (!DOPathIsDirectory(path)) {
            continue;
        }

        NSData *manifestData = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:DOConfigBackupManifestName]];
        if (!manifestData) {
            continue;
        }
        id manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];

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

    for (NSUInteger index = maximumCount; index < backups.count; index++) {
        DORemoveTree(backups[index][@"path"]);
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
    for (NSUInteger suffix = 2; [[NSFileManager defaultManager] fileExistsAtPath:folderPath]; suffix++) {
        folderPath = [basePath stringByAppendingPathComponent:[baseName stringByAppendingFormat:@"-%lu", (unsigned long)suffix]];
    }

    mkdir(folderPath.fileSystemRepresentation, 0755);

    NSUInteger fileCount = 0;
    unsigned long long totalBytes = 0;
    NSMutableArray<NSString *> *capturedRoots = [NSMutableArray array];
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];

    for (NSDictionary *root in DOBackupRoots()) {
        NSString *sourcePath = root[@"source"];
        NSString *relativePath = root[@"relative"];
        if (!DOPathIsDirectory(sourcePath)) {
            [diagnostics addObject:[NSString stringWithFormat:@"%@: missing", sourcePath]];
            continue;
        }

        NSUInteger filesBefore = fileCount;
        NSString *destinationPath = [folderPath stringByAppendingPathComponent:relativePath];
        mkdir(destinationPath.fileSystemRepresentation, 0755);

        NSError *copyError = nil;
        if (!DOCopyDirectoryContents(sourcePath, destinationPath, &fileCount, &totalBytes, &copyError)) {
            DORemoveTree(folderPath);
            if (error) {
                *error = copyError ?: DOConfigBackupErrorForCode(2);
            }
            return NO;
        }

        [diagnostics addObject:[NSString stringWithFormat:@"%@: %lu files", sourcePath, (unsigned long)(fileCount - filesBefore)]];
        [capturedRoots addObject:relativePath];
    }

    if (fileCount == 0) {
        DORemoveTree(folderPath);
        if (error) {
            NSString *detail = [diagnostics componentsJoinedByString:@"\n"];
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@\n%@", DOLocalizedString(@"Backup_Error_Nothing"), detail] }];
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
        DORemoveTree(folderPath);
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
    if (!DOPathIsDirectory(path)) {
        if (error) {
            *error = DOConfigBackupErrorForCode(5);
        }
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:DOConfigBackupManifestName]]) {
        if (error) {
            *error = DOConfigBackupErrorForCode(5);
        }
        return NO;
    }

    NSUInteger restoredFileCount = 0;

    for (NSDictionary *root in DOBackupRoots()) {
        NSString *sourcePath = [path stringByAppendingPathComponent:root[@"relative"]];
        if (!DOPathIsDirectory(sourcePath)) {
            continue;
        }

        NSString *destinationPath = root[@"source"];
        if (!DOPathIsDirectory(destinationPath)) {
            mkdir(destinationPath.fileSystemRepresentation, 0755);
            if (!DOPathIsDirectory(destinationPath)) {
                if (error) {
                    *error = DOConfigBackupErrorForCode(2);
                }
                return NO;
            }
        }

        NSUInteger copiedCount = 0;
        if (!DOCopyDirectoryContents(sourcePath, destinationPath, &copiedCount, NULL, error)) {
            return NO;
        }
        restoredFileCount += copiedCount;
        DOApplyOwnership(destinationPath, YES);
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
