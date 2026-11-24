// language: Objective-C++, file: twin/bypass.mm, target: iOS 15+, arm64
// *one job: feed the KAlert license client a yes, keep every other request real*
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// license endpoints the client polls; any response we fabricate must satisfy the
// shape the client parses, so we answer with the same envelope the real server uses
static NSString *const kVerifyPath = @"/kalert/verify5.php";
static NSString *const kStatusPath = @"/kalert/status5.php";
static NSString *const kConfigPath = @"/kalert/config5.json";

static NSData *json_data(NSDictionary *d) {
    return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
}

// the envelope: ok/token/expiry/licenseType; lifetime set far enough out that
// the client never re-checks inside a session
static NSData *license_ok(void) {
    return json_data(@{
        @"ok": @YES,
        @"success": @YES,
        @"code": @200,
        @"status": @"active",
        @"message": @"ok",
        @"token": @"twin-local-token",
        @"licenseType": @"permanent",
        @"expiresAt": @9999999999,
        @"sourceExpiresAt": @9999999999,
        @"trialExpiresAt": @9999999999,
        @"licensed": @YES,
    });
}

static NSData *config_all_on(void) {
    return json_data(@{
        @"ok": @YES,
        @"CFKCombatRectV583": @YES,
        @"CFKCombatAimModeV57": @YES,
        @"CFKCombatAutoHeadshotV5826": @YES,
        @"CFKCombatWallV5826": @YES,
        @"CFKCombatSkeletonV57": @YES,
        @"CFKCombatHealthV57": @YES,
        @"CFKCombatLabelV57": @YES,
        @"CFKCombatLineV57": @YES,
        @"CFKCombatHeadDotV57": @YES,
        @"CFKCombatNoRecoilV5815": @YES,
    });
}

static BOOL is_license_request(NSURL *url) {
    NSString *p = url.path ?: @"";
    return [p hasSuffix:kVerifyPath] || [p hasSuffix:kStatusPath] || [p hasSuffix:kConfigPath];
}

static NSData *fake_body(NSURL *url) {
    if ([url.path hasSuffix:kConfigPath]) return config_all_on();
    return license_ok();
}

// hook the completion-based dataTaskWithRequest:
static void swizzle_completion(void) {
    Class C = NSURLSession.class;
    SEL orig = @selector(dataTaskWithRequest:completionHandler:);
    SEL repl = @selector(twin_dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(C, orig);
    Method m2 = class_getInstanceMethod(C, repl);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

@implementation NSURLSession (TwinLicense)
- (NSURLSessionDataTask *)twin_dataTaskWithRequest:(NSURLRequest *)req
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    if (req.URL && is_license_request(req.URL) && h) {
        NSData *body = fake_body(req.URL);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:@{@"Content-Type": @"application/json"}];
        // answer on the next runloop turn so the caller's state machine advances normally
        dispatch_async(dispatch_get_main_queue(), ^{ h(body, resp, nil); });
        return nil;
    }
    return [self twin_dataTaskWithRequest:req completionHandler:h];
}
@end

__attribute__((constructor))
static void twin_bypass_boot(void) {
    swizzle_completion();
    NSLog(@"[twin] license bypass armed");
}
