//
//  DOConfigBackup.m
//  Dopamine
//

#import "DOConfigBackup.h"
#import "DOUIManager.h"
#import "Dopamine-Swift.h"

#import <dispatch/dispatch.h>

NSString *const DOConfigBackupErrorDomain = @"DOConfigBackupErrorDomain";

static NSString *const DOConfigBackupDirectoryPathKey = @"DOConfigBackupDirectoryPath";

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

static NSError *DOConfigBackupWrappedError(NSError *underlying, NSString *key)
{
    NSString *message = DOLocalizedString(key);
    if (underlying.localizedDescription.length > 0) {
        message = [NSString stringWithFormat:@"%@\n%@", message, underlying.localizedDescription];
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
    [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    return directoryURL;
}

+ (NSArray<NSDictionary *> *)availableBackups
{
    return [DOConfigurationBackupBridge backupsInDirectory:[self backupDirectoryURL]] ?: @[];
}

+ (BOOL)createBackupWithError:(NSError **)error
{
    NSError *bridgeError = nil;
    [DOConfigurationBackupBridge createBackupInDirectory:[self backupDirectoryURL] root:(DOJailbreakRootPath() ?: @"/") error:&bridgeError];
    if (bridgeError) {
        if (error) {
            *error = DOConfigBackupWrappedError(bridgeError, @"Backup_Error_Write");
        }
        return NO;
    }
    return YES;
}

+ (BOOL)restoreBackupAtPath:(NSString *)path error:(NSError **)error
{
    NSError *bridgeError = nil;
    [DOConfigurationBackupBridge restoreBackupAtPath:path root:(DOJailbreakRootPath() ?: @"/") error:&bridgeError];
    if (bridgeError) {
        if (error) {
            *error = DOConfigBackupWrappedError(bridgeError, @"Backup_Error_Invalid");
        }
        return NO;
    }
    return YES;
}

@end
