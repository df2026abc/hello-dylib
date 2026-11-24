// language: Objective-C++, file: twin/twin_ui.mm, target: iOS 15+, arm64
// Compact floating panel. Five controls only:
//   自瞄 / 透视 / 透明度 / 检测屏蔽 / 清除设备封禁
// The author line at the bottom is left editable at build time.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// switches + slider, read by twin_esp / twin_aim / shield
bool  twin_cfg_aim    = true;
bool  twin_cfg_esp    = true;
bool  twin_cfg_shield = true;
float twin_cfg_opacity = 0.38f;

// author line — replace the text, keep the label
static NSString *const kAuthorLine = @"cs2手游Pos绘制自瞄版-1.0";

BOOL twin_backup_save(void);
BOOL twin_backup_restore(void);
BOOL twin_backup_clear(void);
NSDictionary *twin_unban_clear(void);
BOOL twin_shield_arm(void);

static const CGFloat kBall = 46.f;
static const CGFloat kPanelW = 260.f;

#pragma mark - floating ball

@interface TwinBall : UIView
@end
@implementation TwinBall
- (instancetype)initWithFrame:(CGRect)f {
    if (self = [super initWithFrame:f]) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = YES;
        self.layer.cornerRadius = kBall / 2;
        self.layer.masksToBounds = YES;
        self.opaque = NO;
        [self setNeedsDisplay];
    }
    return self;
}

// dark green disc, gold ring, four reticle ticks, POS wordmark
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    const CGFloat w = rect.size.width, h = rect.size.height;
    const CGFloat cx = w / 2, cy = h / 2;
    const CGFloat r = MIN(w, h) / 2 - 1.0;

    UIColor *deepGreen = [UIColor colorWithRed:0.055 green:0.275 blue:0.184 alpha:1.0];
    UIColor *gold = [UIColor colorWithRed:0.937 green:0.796 blue:0.561 alpha:1.0];
    UIColor *cream = [UIColor colorWithRed:0.976 green:0.906 blue:0.737 alpha:1.0];

    // body
    CGContextSetFillColorWithColor(ctx, deepGreen.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(1, 1, w - 2, h - 2));

    // outer ring
    CGContextSetStrokeColorWithColor(ctx, gold.CGColor);
    CGContextSetLineWidth(ctx, MAX(1.5, r * 0.08));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r * 0.97, cy - r * 0.97, r * 1.94, r * 1.94));

    // inner hairline circle
    CGContextSetLineWidth(ctx, MAX(0.75, r * 0.03));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r * 0.66, cy - r * 0.66, r * 1.32, r * 1.32));

    // four reticle ticks at the compass points
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineWidth(ctx, MAX(1.5, r * 0.09));
    const CGFloat tickOut = r * 0.96, tickIn = r * 0.72;
    for (int i = 0; i < 4; i++) {
        // ticks sit on the vertical/horizontal axes; draw as short thick strokes
        CGContextSetStrokeColorWithColor(ctx, ticks[i].CGColor);
        if (i == 0) { CGContextMoveToPoint(ctx, cx, cy - tickIn); CGContextAddLineToPoint(ctx, cx, cy - tickOut); }
        if (i == 1) { CGContextMoveToPoint(ctx, cx + tickIn, cy); CGContextAddLineToPoint(ctx, cx + tickOut, cy); }
        if (i == 2) { CGContextMoveToPoint(ctx, cx, cy + tickIn); CGContextAddLineToPoint(ctx, cx, cy + tickOut); }
        if (i == 3) { CGContextMoveToPoint(ctx, cx - tickIn, cy); CGContextAddLineToPoint(ctx, cx - tickOut, cy); }
        CGContextStrokePath(ctx);
    }

    // POS wordmark in cream, slightly left of centre like the artwork
    UIFont *f = [UIFont boldSystemFontOfSize:r * 0.82];
    NSDictionary *attrs = @{ NSFontAttributeName: f, NSForegroundColorAttributeName: cream };
    NSString *word = @"POS";
    CGSize sz = [word sizeWithAttributes:attrs];
    [word drawAtPoint:CGPointMake(cx - sz.width / 2 + r * 0.02, cy - sz.height / 2) withAttributes:attrs];
}
@end

#pragma mark - panel

@interface TwinPanel : UIViewController
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *opacityValue;
@end

@implementation TwinPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, 0)];
    card.backgroundColor = [[UIColor colorWithWhite:0.10 alpha:1.0] colorWithAlphaComponent:1.0];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 10;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:kPanelW],
        [self.stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [self.stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];

    // header: title left, author line right
    UIStackView *head = [[UIStackView alloc] init];
    head.axis = UILayoutConstraintAxisHorizontal;
    UILabel *title = [UILabel new];
    title.text = @"twin";
    title.textColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:19];
    UILabel *author = [UILabel new];
    author.text = kAuthorLine;
    author.textColor = UIColor.lightGrayColor;
    author.font = [UIFont systemFontOfSize:9];
    author.adjustsFontSizeToFitWidth = YES;
    author.minimumScaleFactor = 0.7;
    [author setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    author.textAlignment = NSTextAlignmentRight;
    [head addArrangedSubview:title];
    [head addArrangedSubview:author];
    [self.stack addArrangedSubview:head];

    [self addSwitch:@"自瞄" tag:1 on:twin_cfg_aim];
    [self addSwitch:@"透视" tag:2 on:twin_cfg_esp];

    // opacity slider, green track when low alpha keeps boxes faint
    self.opacityValue = [UILabel new];
    self.opacityValue.textColor = UIColor.whiteColor;
    self.opacityValue.font = [UIFont systemFontOfSize:12];
    self.opacityValue.text = [NSString stringWithFormat:@"透明度 %.0f%%", twin_cfg_opacity * 100];
    [self.stack addArrangedSubview:self.opacityValue];

    UISlider *sl = [[UISlider alloc] init];
    sl.minimumValue = 0.05f;
    sl.maximumValue = 1.0f;
    sl.value = twin_cfg_opacity;
    sl.tintColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:1];
    [sl addTarget:self action:@selector(opacityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:sl];

    [self addSwitch:@"检测屏蔽" tag:3 on:twin_cfg_shield];
    [self addButton:@"清除设备封禁" color:[UIColor systemOrangeColor] action:@selector(doUnban)];
    [self addButton:@"关闭" color:UIColor.darkGrayColor action:@selector(doClose)];

    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.status.textColor = UIColor.lightGrayColor;
    self.status.text = @"";
    [self.stack addArrangedSubview:self.status];
}

- (void)addSwitch:(NSString *)label tag:(NSInteger)tag on:(bool)on {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *l = [UILabel new];
    l.text = label;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:14];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:l];
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.tag = tag;
    sw.onTintColor = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:1];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:32],
    ]];
    [self.stack addArrangedSubview:row];
}

- (void)addButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.backgroundColor = [color colorWithAlphaComponent:0.7];
    b.layer.cornerRadius = 8;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:38].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:b];
}

- (void)switchChanged:(UISwitch *)sw {
    bool v = sw.isOn;
    if (sw.tag == 1) twin_cfg_aim = v;
    if (sw.tag == 2) twin_cfg_esp = v;
    if (sw.tag == 3) { twin_cfg_shield = v; if (v) twin_shield_arm(); }
}

- (void)opacityChanged:(UISlider *)sl {
    twin_cfg_opacity = sl.value;
    self.opacityValue.text = [NSString stringWithFormat:@"透明度 %.0f%%", sl.value * 100];
}

- (void)doUnban {
    NSDictionary *r = twin_unban_clear();
    self.status.text = r[@"needsColdStart"] ? @"设备指纹已重置，冷启动生效" : @"重置完成";
}

- (void)doClose { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - host

@interface TwinHost : NSObject
+ (instancetype)shared;
- (void)install;
@end

@implementation TwinHost
+ (instancetype)shared { static TwinHost *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [TwinHost new]; }); return s; }

- (UIWindow *)keyWindow {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)install {
    UIWindow *win = [self keyWindow];
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self install]; });
        return;
    }
    CGSize s = win.bounds.size;
    TwinBall *ball = [[TwinBall alloc] initWithFrame:CGRectMake(s.width - kBall - 12, s.height * 0.35, kBall, kBall)];
    ball.userInteractionEnabled = YES;
    [win addSubview:ball];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [ball addGestureRecognizer:pan];
    [ball addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)]];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *ball = g.view, *sv = ball.superview;
    if (g.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(ball, "start", [NSValue valueWithCGPoint:ball.center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint st = [(NSValue *)objc_getAssociatedObject(ball, "start") CGPointValue];
        CGPoint t = [g translationInView:sv];
        ball.center = CGPointMake(st.x + t.x, st.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded) {
        [UIView animateWithDuration:0.22 animations:^{
            CGFloat maxX = sv.bounds.size.width - ball.bounds.size.width / 2;
            ball.center = CGPointMake(ball.center.x > maxX / 2 ? maxX : ball.bounds.size.width / 2, ball.center.y);
        }];
    }
}

- (void)onTap {
    TwinPanel *p = [TwinPanel new];
    p.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *root = self.keyWindow.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:p animated:YES completion:nil];
}
@end

__attribute__((constructor))
static void twin_ui_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[TwinHost shared] install];
    });
}
