// language: Objective-C++, file: twin_unban.mm, target: iOS 15+, arm64
// *ban is a fingerprint match; rotate the fingerprint, let the server forget the face*
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/types.h>
#include <unistd.h>

static NSString *const kUDIDHash       = @"udidHash";
static NSString *const kUniqueDevice   = @"UniqueDeviceID";
static NSString *const kDeviceCode     = @"deviceCode";
static NSString *const kDeviceVerify   = @"deviceVerification";
static NSString *const kSourceExpires  = @"sourceExpiresAt";
static NSString *const kTrialExpires   = @"trialExpiresAt";
static NSString *const kToken          = @"token";

static NSString *const kKeychainService = @"com.ioskuka.kalert";
static NSString *const kCaptureKey      = @"KAlertCapturedUDIDV53";

#pragma mark - helpers

// sha256 hex; the author keys udidHash off the raw unique id string
static NSString *sha256_hex(NSString *s) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(s.UTF8String, (CC_LONG)strlen(s.UTF8String), d);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", d[i]];
    return hex;
}

// 32 hex chars of fresh entropy, no dashes, matches the shape the game stores
static NSString *random_hex32(void) {
    uint8_t buf[16];
    arc4random_buf(buf, sizeof(buf));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", buf[i]];
    return s;
}

static BOOL keychain_set(NSString *service, NSString *account, NSData *data) {
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: service,
                         (__bridge id)kSecAttrAccount: account };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)q,
                                (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
    if (st == errSecSuccess) return YES;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    return SecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecSuccess;
}

static void keychain_delete(NSString *service, NSString *account) {
    NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecAttrService: service,
                         (__bridge id)kSecAttrAccount: account };
    SecItemDelete((__bridge CFDictionaryRef)q);
}

#pragma mark - public

// 清除设备封禁: rotate every server-visible identifier in one pass, then drop the
// cached udid copy so the enrollment page never sees the old value again
NSDictionary *twin_unban_clear(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    NSString *newUdid   = random_hex32();
    NSString *newHash   = sha256_hex(newUdid);
    NSString *newDevice = random_hex32();

    // old values captured for the log line before the write, never persisted
    NSString *oldHash = [ud objectForKey:kUDIDHash] ?: @"";

    [ud setObject:newHash    forKey:kUDIDHash];
    [ud setObject:newUdid    forKey:kUniqueDevice];
    [ud setObject:newDevice  forKey:kDeviceCode];
    [ud removeObjectForKey:kDeviceVerify];
    [ud removeObjectForKey:kSourceExpires];
    [ud removeObjectForKey:kTrialExpires];
    [ud removeObjectForKey:kToken];
    [ud synchronize];

    // the author's own cache slot — a stale copy here re-fills udidHash on next launch
    keychain_delete(kKeychainService, kCaptureKey);
    keychain_delete(kKeychainService, @"enrollment-token");
    keychain_delete(kKeychainService, @"KAlertEnrollmentTokenV532");

    // read back so the UI can show what actually landed
    NSUserDefaults *after = [NSUserDefaults standardUserDefaults];
    NSLog(@"[twin] unban old=%@ new=%@", [oldHash substringToIndex:MIN(8ul, oldHash.length)],
          [newHash substringToIndex:8]);

    return @{ @"udidHash": [after objectForKey:kUDIDHash] ?: @"",
              @"deviceCode": [after objectForKey:kDeviceCode] ?: @"",
              @"rotated": @YES,
              @"needsColdStart": @YES };
}

// 检测屏蔽 info: report which of the three traps currently hold a value
NSDictionary *twin_unban_status(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    id hash = [ud objectForKey:kUDIDHash];
    id code = [ud objectForKey:kDeviceCode];
    id tok  = [ud objectForKey:kToken];
    id exp  = [ud objectForKey:kSourceExpires];
    return @{ @"udidHash":    hash ? @YES : @NO,
              @"deviceCode":  code ? @YES : @NO,
              @"token":       tok  ? @YES : @NO,
              @"sourceExpires": exp ? @YES : @NO,
              @"shieldCount": @((hash?1:0) + (code?1:0) + (tok?1:0)) };
}
