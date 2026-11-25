// language: Objective-C++, file: cf_nopopup.mm, target: iOS 15+, arm64
// Suppress the KAlert promo popup at runtime without touching its bytes.
// Strategy: intercept UIAlertController presentation and swallow any alert whose
// text matches the promo. KAlert's integrity check hashes its own dylib, not ours,
// so this leaves the fingerprint intact.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL looks_like_promo(UIAlertController *ac) {
    NSMutableString *all = [NSMutableString string];
    if (ac.title) [all appendString:ac.title];
    if (ac.message) [all appendString:ac.message];
    for (UIAlertAction *a in ac.actions) {
        if (a.title) [all appendString:a.title];
    }
    static NSArray<NSString *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@"酷卡", @"ioskuka", @"iOSTuka", @"禁止倒卖",
                    @"加入 TG", @"酷卡官网", @"购买证书", @"24 小时内"];
    });
    for (NSString *n in needles) {
        if ([all rangeOfString:n].location != NSNotFound) return YES;
    }
    return NO;
}

@implementation UIViewController (CfNoPopup)

// every presentation funnels through here on iOS 13+
- (void)cf_presentViewController:(UIViewController *)vc
                        animated:(BOOL)animated
                      completion:(void (^)(void))completion {
    if ([vc isKindOfClass:UIAlertController.class] && looks_like_promo((UIAlertController *)vc)) {
        NSLog(@"[cf_nopopup] suppressed promo alert: %@", ((UIAlertController *)vc).title);
        if (completion) completion();
        return;
    }
    [self cf_presentViewController:vc animated:animated completion:completion];
}

@end

__attribute__((constructor))
static void cf_nopopup_boot(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = UIViewController.class;
        Method orig = class_getInstanceMethod(cls, @selector(presentViewController:animated:completion:));
        Method repl = class_getInstanceMethod(cls, @selector(cf_presentViewController:animated:completion:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
            NSLog(@"[cf_nopopup] armed");
        }
    });
}
