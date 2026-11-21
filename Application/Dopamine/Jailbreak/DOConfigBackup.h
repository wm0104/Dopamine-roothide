//
//  DOConfigBackup.h
//  Dopamine
//
//  Backs up tweak preferences and package sources so they can be restored later.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const DOConfigBackupErrorDomain;

@interface DOConfigBackup : NSObject

// Directory that holds the backup folders (inside the app container by default).
+ (NSString *)backupDirectory;

// Folder that the user picked through the document picker, nil when the default folder is used.
+ (NSURL *_Nullable)configuredBackupDirectoryURL;
+ (void)setConfiguredBackupDirectoryURL:(NSURL *_Nullable)url;

// Folder that backups are actually written to, created on demand.
+ (NSURL *)backupDirectoryURL;
+ (NSURL *)defaultBackupDirectoryURL;

// Newest first. Every entry contains path, name, date and size keys.
+ (NSArray<NSDictionary *> *)availableBackups;

// Copies the current configuration into a new dated folder. Call this while running as root.
+ (BOOL)createBackupWithError:(NSError *_Nullable *_Nullable)error;

// Restores a folder created by createBackupWithError:. Call this while running as root.
+ (BOOL)restoreBackupAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
