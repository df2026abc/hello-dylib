// language: Objective-C++, file: twin/twin_ui.mm, target: iOS 15+, arm64
// *floating ball opens a panel; every switch flips a shared bool the modules read each frame*
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// shared switches, read by twin_esp / twin_aim / shield
// plain C++ linkage: all twin_*.mm are compiled as ObjC++ so names match
bool twin_cfg_esp   = true;
bool twin_cfg_aim   = true;
bool twin_cfg_shield = true;

// these live in twin_*.mm and are plain C++ too
BOOL twin_backup_save(void);
BOOL twin_backup_restore(void);
BOOL twin_backup_clear(void);
NSDictionary *twin_unban_clear(void);
BOOL twin_shield_arm(void);

static const CGFloat kBallSize = 44.f;

@interface TwinBall : UIView
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint ballStart;
@end

@implementation TwinBall
- (instancetype)initWithFrame:(CGRect)f {
    if (self = [super initWithFrame:f]) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        self.layer.cornerRadius = kBallSize / 2;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.5 alpha:0.9].CGColor;
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"T";
        l.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.5 alpha:1];
        l.font = [UIFont boldSystemFontOfSize:20];
        l.textAlignment = NSTextAlignmentCenter;
        l.userInteractionEnabled = NO;
        [self addSubview:l];
    }
    return self;
}
@end

@interface TwinPanel : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *status;
@end

@implementation TwinPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    self.stack = [[UIStackView alloc] initWithFrame:CGRectMake(16, 40, self.view.bounds.size.width - 32, 0)];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 12;
    self.stack.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.scroll addSubview:self.stack];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"twin";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.5 alpha:1];
    [self.stack addArrangedSubview:title];

    self.status = [[UILabel alloc] initWithFrame:CGRectZero];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.status.textColor = UIColor.lightGrayColor;
    [self.stack addArrangedSubview:self.status];

    [self addSwitch:@"方框透视" on:twin_cfg_esp tag:1];
    [self addSwitch:@"自瞄锁头" on:twin_cfg_aim tag:2];
    [self addSwitch:@"检测屏蔽" on:twin_cfg_shield tag:3];

    [self addButton:@"立即备份" color:[UIColor systemGreenColor] action:@selector(doBackup)];
    [self addButton:@"恢复备份" color:[UIColor systemBlueColor] action:@selector(doRestore)];
    [self addButton:@"清除设备封禁" color:[UIColor systemOrangeColor] action:@selector(doUnban)];
    [self addButton:@"清除配置" color:[UIColor systemRedColor] action:@selector(doClear)];

    [self addButton:@"关闭" color:UIColor.darkGrayColor action:@selector(doClose)];
    [self relayout];
}

- (void)relayout {
    CGSize s = self.stack.systemLayoutSizeFittingSize:CGSizeMake(self.view.bounds.size.width - 32, 0)
                    withCompressionResistancePriority:UILayoutPriorityDefaultHigh
                              forOrientation:UILayoutConstraintAxisVertical];
    self.stack.frame = CGRectMake(16, 40, self.view.bounds.size.width - 32, s.height);
    self.scroll.contentSize = CGSizeMake(self.view.bounds.size.width, s.height + 80);
}

- (void)addSwitch:(NSString *)label on:(bool)on tag:(NSInteger)tag {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.stack.frame.size.width, 44)];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, row.bounds.size.width - 70, 44)];
    l.text = label; l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [row addSubview:l];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(row.bounds.size.width - 60, 6, 51, 31)];
    sw.on = on;
    sw.tag = tag;
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    [self.stack addArrangedSubview:row];
}

- (void)addButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [color colorWithAlphaComponent:0.75];
    b.layer.cornerRadius = 8;
    b.frame = CGRectMake(0, 0, self.stack.frame.size.width, 44);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:b];
}

- (void)switchChanged:(UISwitch *)sw {
    bool v = sw.isOn;
    if (sw.tag == 1) twin_cfg_esp = v;
    if (sw.tag == 2) twin_cfg_aim = v;
    if (sw.tag == 3) { twin_cfg_shield = v; if (v) twin_shield_arm(); }
    NSLog(@"[twin] switch %ld -> %d", (long)sw.tag, v);
}

- (void)doBackup  { BOOL ok = twin_backup_save();    [self toast:ok ? @"已备份" : @"备份失败"]; }
- (void)doRestore { BOOL ok = twin_backup_restore(); [self toast:ok ? @"已恢复" : @"无备份"]; }
- (void)doUnban   { twin_unban_clear();              [self toast:@"已重置设备指纹，冷启动生效"]; }
- (void)doClear   { twin_backup_clear();             [self toast:@"已清除"]; }
- (void)doClose   { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)toast:(NSString *)msg {
    self.status.text = msg;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.status.text = @"";
    });
}

@end

@interface TwinHost : NSObject
+ (instancetype)shared;
- (void)install;
@end

@implementation TwinHost

+ (instancetype)shared { static TwinHost *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [TwinHost new]; }); return s; }

- (UIWindow *)host {
    for (UIWindowScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in sc.windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)install {
    UIWindow *win = [self host];
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self install]; }); return; }

    CGSize s = win.bounds.size;
    TwinBall *ball = [[TwinBall alloc] initWithFrame:CGRectMake(s.width - kBallSize - 12, s.height * 0.35, kBallSize, kBallSize)];
    ball.userInteractionEnabled = YES;
    [win addSubview:ball];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [ball addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [ball addGestureRecognizer:tap];
    objc_setAssociatedObject(win, "twin.ball", ball, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *ball = g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(ball, "start", [NSValue valueWithCGPoint:ball.center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint start = [(NSValue *)objc_getAssociatedObject(ball, "start") CGPointValue];
        CGPoint t = [g translationInView:ball.superview];
        ball.center = CGPointMake(start.x + t.x, start.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [UIView animateWithDuration:0.25 animations:^{
            CGFloat maxX = ball.superview.bounds.size.width - ball.bounds.size.width / 2;
            ball.center = CGPointMake(ball.center.x > maxX / 2 ? maxX : ball.bounds.size.width / 2, ball.center.y);
        }];
    }
}

- (void)onTap {
    TwinPanel *p = [TwinPanel new];
    p.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *root = [self rootVC];
    [root presentViewController:p animated:YES completion:nil];
}

- (UIViewController *)rootVC {
    UIWindow *win = [self host];
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@end

__attribute__((constructor))
static void twin_ui_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[TwinHost shared] install];
    });
}
