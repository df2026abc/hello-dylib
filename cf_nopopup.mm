// language: Objective-C++, file: nopop/cf_nopopup.mm, target: iOS 15+, arm64
// Intercept the KAlert promo popup at runtime. Nothing in KAlert's image is
// modified, so its __TEXT fingerprint check still passes.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---- promo popup detection ----
static BOOL is_promo_alert(UIViewController *vc) {
    if (![vc isKindOfClass:UIAlertController.class]) {
        // custom full-screen promo panel: look at its view hierarchy text
        if (vc.view && vc.presentingViewController) {
            NSMutableString *text = [NSMutableString string];
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
            int guard = 0;
            while (stack.count && guard++ < 400) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:UILabel.class]) {
                    NSString *t = ((UILabel *)v).text;
                    if (t) [text appendString:t];
                } else if ([v isKindOfClass:UIButton.class]) {
                    NSString *t = [((UIButton *)v) titleForState:UIControlStateNormal];
                    if (t) [text appendString:t];
                }
                [stack addObjectsFromArray:v.subviews];
            }
            static NSArray<NSString *> *needles;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                needles = @[@"酷卡分享", @"禁止倒卖", @"iOSTuka", @"ioskuka"];
            });
            for (NSString *n in needles)
                if ([text rangeOfString:n].location != NSNotFound) return YES;
        }
        return NO;
    }
    UIAlertController *ac = (UIAlertController *)vc;
    NSMutableString *all = [NSMutableString string];
    if (ac.title) [all appendString:ac.title];
    if (ac.message) [all appendString:ac.message];
    for (UIAlertAction *a in ac.actions) if (a.title) [all appendString:a.title];
    static NSArray<NSString *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[@"酷卡分享", @"禁止倒卖", @"加入 TG 频道", @"加入 TG 群聊",
                    @"酷卡官网", @"购买证书", @"24 小时内删除"];
    });
    for (NSString *n in needles)
        if ([all rangeOfString:n].location != NSNotFound) return YES;
    return NO;
}

@implementation UIViewController (CfNoPop)

- (void)cfnp_present:(UIViewController *)vc
            animated:(BOOL)animated
          completion:(void (^)(void))completion {
    if (is_promo_alert(vc)) {
        NSLog(@"[cf_nopop] suppressed promo panel: %@", NSStringFromClass(vc.class));
        if (completion) completion();
        return;
    }
    [self cfnp_present:vc animated:animated completion:completion];
}

@end

// ---- kill ioskuka link-outs from the panel buttons ----
static BOOL is_promo_url(NSURL *url) {
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    if (!s) return NO;
    static NSArray<NSString *> *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"ioskuka.com", @"t.me/ioskuka", @"telegram.me/ioskuka",
                @"t.me/gekugou", @"telegram.me/gekugou", @"fk.ioskuka.com"];
    });
    for (NSString *b in bad) if ([s rangeOfString:b].location != NSNotFound) return YES;
    return NO;
}

@implementation UIApplication (CfNoLink)

- (BOOL)cfnp_openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey,id> *)options
 completionHandler:(void (^)(BOOL))completion {
    if (is_promo_url(url)) {
        NSLog(@"[cf_nopop] blocked link: %@", url.absoluteString);
        if (completion) completion(NO);
        return NO;
    }
    return [self cfnp_openURL:url options:options completionHandler:completion];
}

@end

__attribute__((constructor))
static void cf_nopop_boot(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        {
            Class c = UIViewController.class;
            Method a = class_getInstanceMethod(c, @selector(presentViewController:animated:completion:));
            Method b = class_getInstanceMethod(c, @selector(cfnp_present:animated:completion:));
            if (a && b) method_exchangeImplementations(a, b);
        }
        {
            Class c = UIApplication.class;
            Method a = class_getInstanceMethod(c, @selector(openURL:options:completionHandler:));
            Method b = class_getInstanceMethod(c, @selector(cfnp_openURL:options:completionHandler:));
            if (a && b) method_exchangeImplementations(a, b);
        }
        NSLog(@"[cf_nopop] armed");
    });
}
