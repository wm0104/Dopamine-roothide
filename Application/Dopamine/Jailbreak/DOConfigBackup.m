//
//  DOConfigBackup.m
//  Dopamine
//

#import "DOConfigBackup.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"

#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const DOConfigBackupErrorDomain = @"DOConfigBackupErrorDomain";

static NSString *const DOConfigBackupDirectoryPathKey = @"DOConfigBackupDirectoryPath";

#define DO_CONFIG_BACKUP_MAX_COUNT 2

#pragma mark - Little endian helpers

static void DOAppendLE16(NSMutableData *data, uint16_t value)
{
    uint8_t bytes[2] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void DOAppendLE32(NSMutableData *data, uint32_t value)
{
    uint8_t bytes[4] = { (uint8_t)(value & 0xFF), (uint8_t)((value >> 8) & 0xFF), (uint8_t)((value >> 16) & 0xFF), (uint8_t)((value >> 24) & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t DOReadLE16(const uint8_t *bytes)
{
    return (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t DOReadLE32(const uint8_t *bytes)
{
    return (uint32_t)((uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24));
}

static uint32_t DOCRC32(const uint8_t *bytes, size_t length)
{
    static uint32_t table[256];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t value = i;
            for (int bit = 0; bit < 8; bit++) {
                value = (value & 1) ? (0xEDB88320U ^ (value >> 1)) : (value >> 1);
            }
            table[i] = value;
        }
    });

    uint32_t crc = 0xFFFFFFFFU;
    for (size_t i = 0; i < length; i++) {
        crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFU;
}

static void DODosDateTime(NSDate *date, uint16_t *outTime, uint16_t *outDate)
{
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDateComponents *components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) fromDate:date];
    NSInteger year = components.year < 1980 ? 1980 : components.year;
    *outDate = (uint16_t)(((year - 1980) << 9) | (components.month << 5) | components.day);
    *outTime = (uint16_t)((components.hour << 11) | (components.minute << 5) | (components.second / 2));
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

static NSArray<NSDictionary *> *DOBackupSources(void)
{
    NSMutableArray<NSDictionary *> *sources = [NSMutableArray array];
    [sources addObject:@{ @"path": @"/var/mobile/Library/Preferences", @"archive": @"rootfs/var/mobile/Library/Preferences", @"mode": @"plist" }];

    NSString *jailbreakRoot = DOJailbreakRootPath();
    if (jailbreakRoot) {
        [sources addObject:@{ @"path": [jailbreakRoot stringByAppendingPathComponent:@"/var/mobile/Library/Preferences"], @"archive": @"jbroot/var/mobile/Library/Preferences", @"mode": @"plist" }];
        [sources addObject:@{ @"path": [jailbreakRoot stringByAppendingPathComponent:@"/etc/apt/sources.list.d"], @"archive": @"jbroot/etc/apt/sources.list.d", @"mode": @"apt" }];
        [sources addObject:@{ @"path": [jailbreakRoot stringByAppendingPathComponent:@"/etc/apt/preferences.d"], @"archive": @"jbroot/etc/apt/preferences.d", @"mode": @"apt" }];
    }
    return sources;
}

// Maps an entry name back to the absolute path it should be restored to.
// Returns nil for entries that are not part of the backed up configuration.
static NSString *DODestinationPathForEntryName(NSString *name)
{
    if ([name hasPrefix:@"rootfs/var/mobile/Library/Preferences/"]) {
        return [@"/" stringByAppendingString:[name substringFromIndex:@"rootfs/".length]];
    }

    NSString *jailbreakRoot = DOJailbreakRootPath();
    if (!jailbreakRoot) {
        return nil;
    }

    NSArray<NSString *> *allowed = @[
        @"jbroot/var/mobile/Library/Preferences/",
        @"jbroot/etc/apt/sources.list.d/",
        @"jbroot/etc/apt/preferences.d/"
    ];
    for (NSString *prefix in allowed) {
        if ([name hasPrefix:prefix]) {
            return [jailbreakRoot stringByAppendingPathComponent:[name substringFromIndex:@"jbroot/".length]];
        }
    }
    return nil;
}

static void DOFixRestoredFileOwnership(NSString *destination)
{
    const char *filePath = destination.fileSystemRepresentation;
    if ([destination containsString:@"/var/mobile/"]) {
        // Preferences must stay writable by the mobile user, otherwise tweaks can no longer save settings.
        chown(filePath, 501, 501);
    }
    chmod(filePath, 0644);
}

#pragma mark - DOConfigBackup

@implementation DOConfigBackup

+ (NSString *)backupDirectory
{
    return [self backupDirectoryURL].path;
}

+ (NSURL *)defaultBackupDirectoryURL
{
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!documents) {
        documents = NSTemporaryDirectory();
    }
    return [NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"ConfigurationBackups"] isDirectory:YES];
}

+ (NSURL *)configuredBackupDirectoryURL
{
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:DOConfigBackupDirectoryPathKey];
    if (!path.length) {
        return nil;
    }
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

+ (void)setConfiguredBackupDirectoryURL:(NSURL *)url
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!url) {
        [defaults removeObjectForKey:DOConfigBackupDirectoryPathKey];
    }
    else {
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
    NSString *directory = ([self configuredBackupDirectoryURL] ?: [self defaultBackupDirectoryURL]).path;
    NSArray<NSString *> *items = [fileManager contentsOfDirectoryAtPath:directory error:nil];
    NSMutableArray<NSDictionary *> *backups = [NSMutableArray array];

    for (NSString *item in items) {
        if (![item.pathExtension isEqualToString:@"zip"]) {
            continue;
        }
        NSString *path = [directory stringByAppendingPathComponent:item];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
        if (!attributes) {
            continue;
        }
        [backups addObject:@{
            @"path": path,
            @"name": item,
            @"date": attributes[NSFileModificationDate] ?: [NSDate date],
            @"size": attributes[NSFileSize] ?: @0
        }];
    }

    [backups sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        return [rhs[@"name"] compare:lhs[@"name"]];
    }];
    return backups;
}

+ (BOOL)createBackupWithError:(NSError *_Nullable *_Nullable)error
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    for (NSDictionary *source in DOBackupSources()) {
        NSString *directory = source[@"path"];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }

        BOOL plistOnly = [source[@"mode"] isEqualToString:@"plist"];
        for (NSString *item in [fileManager contentsOfDirectoryAtPath:directory error:nil]) {
            if ([item hasPrefix:@"."]) {
                continue;
            }
            if (plistOnly && ![item.pathExtension isEqualToString:@"plist"]) {
                continue;
            }

            NSString *absolutePath = [directory stringByAppendingPathComponent:item];
            BOOL itemIsDirectory = NO;
            if (![fileManager fileExistsAtPath:absolutePath isDirectory:&itemIsDirectory] || itemIsDirectory) {
                continue;
            }

            NSData *contents = [NSData dataWithContentsOfFile:absolutePath];
            if (!contents) {
                continue;
            }

            [entries addObject:@{ @"name": [source[@"archive"] stringByAppendingPathComponent:item], @"data": contents }];
        }
    }

    if (entries.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Nothing") }];
        }
        return NO;
    }

    NSDictionary *manifest = @{
        @"version": [[DOEnvironmentManager sharedManager] appVersion] ?: @"",
        @"date": [NSDate date].description ?: @"",
        @"files": @(entries.count)
    };
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    if (manifestData) {
        [entries insertObject:@{ @"name": @"manifest.json", @"data": manifestData } atIndex:0];
    }

    NSMutableData *archive = [NSMutableData data];
    NSMutableData *centralDirectory = [NSMutableData data];
    uint16_t dosTime = 0;
    uint16_t dosDate = 0;
    DODosDateTime([NSDate date], &dosTime, &dosDate);
    uint16_t entryCount = 0;

    for (NSDictionary *entry in entries) {
        NSData *contents = entry[@"data"];
        NSData *nameData = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!nameData) {
            continue;
        }

        uint32_t crc = DOCRC32(contents.bytes, contents.length);
        uint32_t offset = (uint32_t)archive.length;
        uint32_t size = (uint32_t)contents.length;

        DOAppendLE32(archive, 0x04034B50);
        DOAppendLE16(archive, 20);
        DOAppendLE16(archive, 0x0800);
        DOAppendLE16(archive, 0);
        DOAppendLE16(archive, dosTime);
        DOAppendLE16(archive, dosDate);
        DOAppendLE32(archive, crc);
        DOAppendLE32(archive, size);
        DOAppendLE32(archive, size);
        DOAppendLE16(archive, (uint16_t)nameData.length);
        DOAppendLE16(archive, 0);
        [archive appendData:nameData];
        [archive appendData:contents];

        DOAppendLE32(centralDirectory, 0x02014B50);
        DOAppendLE16(centralDirectory, 20);
        DOAppendLE16(centralDirectory, 20);
        DOAppendLE16(centralDirectory, 0x0800);
        DOAppendLE16(centralDirectory, 0);
        DOAppendLE16(centralDirectory, dosTime);
        DOAppendLE16(centralDirectory, dosDate);
        DOAppendLE32(centralDirectory, crc);
        DOAppendLE32(centralDirectory, size);
        DOAppendLE32(centralDirectory, size);
        DOAppendLE16(centralDirectory, (uint16_t)nameData.length);
        DOAppendLE16(centralDirectory, 0);
        DOAppendLE16(centralDirectory, 0);
        DOAppendLE16(centralDirectory, 0);
        DOAppendLE16(centralDirectory, 0);
        DOAppendLE32(centralDirectory, 0);
        DOAppendLE32(centralDirectory, offset);
        [centralDirectory appendData:nameData];

        entryCount++;
    }

    uint32_t centralDirectoryOffset = (uint32_t)archive.length;
    [archive appendData:centralDirectory];

    DOAppendLE32(archive, 0x06054B50);
    DOAppendLE16(archive, 0);
    DOAppendLE16(archive, 0);
    DOAppendLE16(archive, entryCount);
    DOAppendLE16(archive, entryCount);
    DOAppendLE32(archive, (uint32_t)centralDirectory.length);
    DOAppendLE32(archive, centralDirectoryOffset);
    DOAppendLE16(archive, 0);

    NSString *directory = [self backupDirectoryURL].path;
    [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *fileName = [NSString stringWithFormat:@"Configuration-%@.zip", [formatter stringFromDate:[NSDate date]]];
    NSString *path = [directory stringByAppendingPathComponent:fileName];

    if (![archive writeToFile:path atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:2 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Write") }];
        }
        return NO;
    }

    // Keep only the most recent archives so the app container does not grow forever.
    NSArray<NSDictionary *> *backups = [self availableBackups];
    if (backups.count > DO_CONFIG_BACKUP_MAX_COUNT) {
        for (NSUInteger index = DO_CONFIG_BACKUP_MAX_COUNT; index < backups.count; index++) {
            [fileManager removeItemAtPath:backups[index][@"path"] error:nil];
        }
    }

    return YES;
}

+ (BOOL)restoreBackupAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSData *archive = [NSData dataWithContentsOfFile:path];
    if (!archive) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:3 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Read") }];
        }
        return NO;
    }

    const uint8_t *bytes = archive.bytes;
    NSUInteger length = archive.length;
    if (length < 22) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:4 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Truncated") }];
        }
        return NO;
    }

    NSInteger endOfCentralDirectory = -1;
    for (NSInteger index = (NSInteger)length - 22; index >= 0; index--) {
        if (DOReadLE32(bytes + index) == 0x06054B50) {
            endOfCentralDirectory = index;
            break;
        }
    }
    if (endOfCentralDirectory < 0) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:5 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Invalid") }];
        }
        return NO;
    }

    uint16_t totalEntries = DOReadLE16(bytes + endOfCentralDirectory + 10);
    uint32_t centralDirectorySize = DOReadLE32(bytes + endOfCentralDirectory + 12);
    uint32_t centralDirectoryOffset = DOReadLE32(bytes + endOfCentralDirectory + 16);
    if ((NSUInteger)centralDirectoryOffset + centralDirectorySize > length) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:6 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Corrupted") }];
        }
        return NO;
    }

    NSUInteger cursor = centralDirectoryOffset;
    NSUInteger restoredCount = 0;

    for (uint16_t index = 0; index < totalEntries; index++) {
        if (cursor + 46 > length || DOReadLE32(bytes + cursor) != 0x02014B50) {
            break;
        }

        uint16_t nameLength = DOReadLE16(bytes + cursor + 28);
        uint16_t extraLength = DOReadLE16(bytes + cursor + 30);
        uint16_t commentLength = DOReadLE16(bytes + cursor + 32);
        uint32_t uncompressedSize = DOReadLE32(bytes + cursor + 24);
        uint32_t localHeaderOffset = DOReadLE32(bytes + cursor + 42);

        NSString *name = nil;
        if (cursor + 46 + nameLength <= length) {
            name = [[NSString alloc] initWithBytes:bytes + cursor + 46 length:nameLength encoding:NSUTF8StringEncoding];
        }
        cursor += (NSUInteger)46 + nameLength + extraLength + commentLength;

        if (!name || [name isEqualToString:@"manifest.json"]) {
            continue;
        }

        NSString *destination = DODestinationPathForEntryName(name);
        if (!destination) {
            continue;
        }
        if ((NSUInteger)localHeaderOffset + 30 > length) {
            continue;
        }

        uint16_t localNameLength = DOReadLE16(bytes + localHeaderOffset + 26);
        uint16_t localExtraLength = DOReadLE16(bytes + localHeaderOffset + 28);
        NSUInteger dataOffset = (NSUInteger)localHeaderOffset + 30 + localNameLength + localExtraLength;
        if (dataOffset + uncompressedSize > length) {
            continue;
        }

        NSString *parentDirectory = [destination stringByDeletingLastPathComponent];
        [fileManager createDirectoryAtPath:parentDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        NSData *contents = [archive subdataWithRange:NSMakeRange(dataOffset, uncompressedSize)];
        if (![contents writeToFile:destination atomically:YES]) {
            continue;
        }

        DOFixRestoredFileOwnership(destination);
        restoredCount++;
    }

    if (restoredCount == 0) {
        if (error) {
            *error = [NSError errorWithDomain:DOConfigBackupErrorDomain code:7 userInfo:@{ NSLocalizedDescriptionKey: DOLocalizedString(@"Backup_Error_Empty") }];
        }
        return NO;
    }

    return YES;
}

@end
