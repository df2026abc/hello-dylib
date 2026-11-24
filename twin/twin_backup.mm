// language: Objective-C++, file: twin_backup.mm, target: iOS 15+, arm64
// *snapshot first, write second, verify third — a half-restored inventory loses skins permanently*
#import "il2cpp_kit.h"
#import <Foundation/Foundation.h>

static NSString *const kBackupName   = @"CounterFlameSettingsBackup.json";
static NSString *const kInventoryRaw = @"CFKAlert551NativeInventoryOriginalRawV4";
static NSString *const kInvEnabled   = @"CFKAlert551NativeInventoryEnabledV4";
static NSString *const kInvInit      = @"CFKAlert551PersistentInventoryInitializedV5";
static NSString *const kLastCosmetic = @"CFKAlert551LastCosmetic";
static NSString *const kFavorites    = @"CFKAlert551Favorites";
static NSString *const kEquipPrefs   = @"equipmentPreferences";
static NSString *const kEquipSaved   = @"equipmentSavedAt";

static NSString *backup_path(void) {
    // game sandbox DOCUMENTS; twin dylib runs inside the host app so NSSearchPath returns its container
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kBackupName];
}

// keys the author round-trips; every entry mirrors a CFK* default plus two payload blobs
static NSArray<NSString *> *tracked_keys(void) {
    return @[ kInventoryRaw, kInvEnabled, kInvInit, kLastCosmetic,
              kFavorites, kEquipPrefs, kEquipSaved ];
}

static NSDictionary *snapshot_of(NSUserDefaults *ud) {
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (NSString *k in tracked_keys()) {
        id v = [ud objectForKey:k];
        if (v) snap[k] = v;
    }
    snap[@"__savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    return snap;
}

static BOOL write_snapshot(NSDictionary *snap, NSString *path) {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:snap
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!json) { NSLog(@"[twin] snapshot encode failed: %@", err); return NO; }
    // atomic: temp file then rename, crash mid-write leaves the old backup intact
    return [json writeToFile:path options:NSDataWritingAtomic error:&err];
}

static NSDictionary *read_snapshot(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

#pragma mark - public

// 立即备份: grab the live defaults dictionary and persist it
BOOL twin_backup_save(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *snap = snapshot_of(ud);
    BOOL ok = write_snapshot(snap, backup_path());
    NSLog(@"[twin] backup %@ -> %@ (%lu keys)", ok ? @"ok" : @"FAIL", backup_path(), (unsigned long)snap.count);
    return ok;
}

// 恢复备份: clear tracked keys first so stale leftovers never survive into the restore
BOOL twin_backup_restore(void) {
    NSString *path = backup_path();
    NSDictionary *snap = read_snapshot(path);
    if (!snap) { NSLog(@"[twin] restore skipped: no backup at %@", path); return NO; }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in tracked_keys()) [ud removeObjectForKey:k];
    for (NSString *k in tracked_keys()) {
        id v = snap[k];
        if (v) [ud setObject:v forKey:k];
    }
    [ud synchronize];

    // read back; a key that failed to land means the defaults domain rejected it
    NSUserDefaults *after = [NSUserDefaults standardUserDefaults];
    NSUInteger restored = 0;
    for (NSString *k in tracked_keys()) if ([after objectForKey:k]) restored++;
    NSLog(@"[twin] restore done: %lu/%lu keys from %@", (unsigned long)restored,
          (unsigned long)tracked_keys().count, [snap objectForKey:@"__savedAt"]);
    return restored > 0;
}

// wipe: drop every tracked key plus the backup file itself
BOOL twin_backup_clear(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in tracked_keys()) [ud removeObjectForKey:k];
    [ud synchronize];
    NSError *err = nil;
    NSString *p = backup_path();
    [[NSFileManager defaultManager] removeItemAtPath:p error:&err];
    return err == nil;
}

// does a backup exist and how old
NSDictionary *twin_backup_info(void) {
    NSString *p = backup_path();
    NSDictionary *snap = read_snapshot(p);
    if (!snap) return @{ @"exists": @NO };
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    return @{ @"exists": @YES,
              @"path": p,
              @"savedAt": snap[@"__savedAt"] ?: @0,
              @"size": attrs[NSFileSize] ?: @0,
              @"keys": @(snap.count - 1) };
}
