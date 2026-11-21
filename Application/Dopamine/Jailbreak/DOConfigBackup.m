//
//  DOConfigBackup.m
//  Dopamine
//

#import "DOConfigBackup.h"
#import "DOUIManager.h"
#import "Dopamine-Swift.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <limits.h>
#import <libjailbreak/info.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const DOConfigBackupErrorDomain = @"DOConfigBackupErrorDomain";

static NSString *const DOConfigBackupDirectoryPathKey = @"DOConfigBackupDirectoryPath";

// Defined in DOBootstrapper.m; the value is checked against the jbrand before it is used.
extern NSString *find_jbroot(bool force);

static BOOL DOPathIsDirectory(NSString *path)
{
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

// Walks the path component by component and reports the first entry that is not a plain directory,
// so a failed backup can say exactly which link or file broke the chain.
static NSString *DOProbePath(NSString *path)
{
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    NSString *current = @"";
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0) {
            continue;
        }
        current = [current stringByAppendingFormat:@"/%@", component];
        struct stat info;
        if (lstat(current.fileSystemRepresentation, &info) != 0) {
            [notes addObject:[NSString stringWithFormat:@"%@ errno=%d %s", current, errno, strerror(errno)]];
            break;
        }
        if (S_ISLNK(info.st_mode)) {
            char target[PATH_MAX] = {0};
            ssize_t length = readlink(current.fileSystemRepresentation, target, sizeof(target) - 1);
            NSString *linkTarget = length > 0 ? [NSString stringWithUTF8String:target] : nil;
            [notes addObject:[NSString stringWithFormat:@"%@ -> %@", current, linkTarget ?: @"?"]];
        } else if (!S_ISDIR(info.st_mode)) {
            [notes addObject:[NSString stringWithFormat:@"%@ is not a directory", current]];
            break;
        }
    }
    return [notes componentsJoinedByString:@" | "];
}

static NSString *DOJailbreakRootPath(void)
{
    static NSString *cachedRoot = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Prefer the bootstrap root Dopamine itself resolved and validated.
        NSString *root = find_jbroot(false);
        if (!root.length) {
            const char *reported = gSystemInfo.jailbreakInfo.rootPath;
            if (reported && reported[0] == '/') {
                root = [NSString stringWithUTF8String:reported];
            }
        }
        if (!DOPathIsDirectory([(root ?: @"/") stringByAppendingPathComponent:@"etc/apt"])) {
            NSString *bundleContainer = @"/var/containers/Bundle/Application";
            for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleContainer error:nil]) {
                if (![item hasPrefix:@".jbroot-"] || item.length != 24) {
                    continue;
                }
                NSString *candidate = [bundleContainer stringByAppendingPathComponent:item];
                if (DOPathIsDirectory([candidate stringByAppendingPathComponent:@"etc/apt"])) {
                    root = candidate;
                    break;
                }
            }
        }
        cachedRoot = root;
    });
    return cachedRoot;
}

static void DOCreateDirectoryTree(NSString *path)
{
    NSString *current = @"";
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0) {
            continue;
        }
        current = [current stringByAppendingFormat:@"/%@", component];
        mkdir(current.fileSystemRepresentation, 0755);
    }
}

static NSString *DOBackupDiagnostics(NSString *root, NSURL *destination)
{
    NSString *resolvedRoot = root.length ? root : @"/";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"jbroot: %@", root.length ? root : @"(none)"]];
    [lines addObject:[NSString stringWithFormat:@"rootfs /var: %@", DOProbePath(@"/var")]];
    [lines addObject:[NSString stringWithFormat:@"rootfs /etc/apt: %@", DOProbePath(@"/etc/apt")]];
    [lines addObject:[NSString stringWithFormat:@"jbroot /var: %@", DOProbePath([resolvedRoot stringByAppendingPathComponent:@"var"])]];
    [lines addObject:[NSString stringWithFormat:@"jbroot /etc/apt: %@", DOProbePath([resolvedRoot stringByAppendingPathComponent:@"etc/apt"])]];
    [lines addObject:[NSString stringWithFormat:@"destination: %@", DOProbePath(destination.path)]];
    return [lines componentsJoinedByString:@"\n"];
}

static NSError *DOConfigBackupWrappedError(NSError *underlying, NSString *key, NSString *detail)
{
    NSString *message = DOLocalizedString(key);
    if (underlying.localizedDescription.length > 0) {
        message = [NSString stringWithFormat:@"%@\n%@", message, underlying.localizedDescription];
    }
    if (detail.length > 0) {
        message = [NSString stringWithFormat:@"%@\n\n%@", message, detail];
    }
    return [NSError errorWithDomain:DOConfigBackupErrorDomain code:underlying.code userInfo:@{ NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: underlying }];
}

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
    DOCreateDirectoryTree(directoryURL.path);
    return directoryURL;
}

+ (NSArray<NSDictionary *> *)availableBackups
{
    return [DOConfigurationBackupBridge backupsInDirectory:[self backupDirectoryURL]] ?: @[];
}

+ (BOOL)createBackupWithError:(NSError **)error
{
    NSURL *destination = [self backupDirectoryURL];
    NSString *root = DOJailbreakRootPath();
    NSError *bridgeError = nil;
    [DOConfigurationBackupBridge createBackupInDirectory:destination root:(root ?: @"/") error:&bridgeError];
    if (bridgeError) {
        if (error) {
            *error = DOConfigBackupWrappedError(bridgeError, @"Backup_Error_Write", DOBackupDiagnostics(root, destination));
        }
        return NO;
    }
    return YES;
}

+ (BOOL)restoreBackupAtPath:(NSString *)path error:(NSError **)error
{
    NSURL *destination = [NSURL fileURLWithPath:path isDirectory:YES];
    NSString *root = DOJailbreakRootPath();
    NSError *bridgeError = nil;
    [DOConfigurationBackupBridge restoreBackupAtPath:path root:(root ?: @"/") error:&bridgeError];
    if (bridgeError) {
        if (error) {
            *error = DOConfigBackupWrappedError(bridgeError, @"Backup_Error_Invalid", DOBackupDiagnostics(root, destination));
        }
        return NO;
    }
    return YES;
}

@end
