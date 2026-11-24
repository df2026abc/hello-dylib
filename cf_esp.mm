// cf_esp.mm — CounterFlame 透视方框 v6
//
// 关键修正：iOS 15+ 用 connectedScenes + UIWindowScene 取窗口
//          独立 UIWindow 抬高 windowLevel，确保盖在 Unity 之上
//          带悬浮窗，方便确认视图是否真的挂上
//
// 偏移（实测）：
//   PlayerController._mainCamera         0x30
//   PlayerController._movementController 0x40
//   PlayerController._isDeath            0xa8
//   PlayerMovement._currSimPosition      0x268
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit -framework QuartzCore \
//     -install_name @executable_path/cf_esp.dylib \
//     cf_esp.mm -o cf_esp.dylib

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

typedef struct Il2CppArray {
    void *klass; void *monitor; void *bounds;
    size_t max_length; void *vector[1];
} Il2CppArray;

typedef void*  (*p_domain_get)(void);
typedef void** (*p_domain_get_assemblies)(void*, size_t*);
typedef void*  (*p_assembly_get_image)(void*);
typedef size_t (*p_image_get_class_count)(void*);
typedef void*  (*p_image_get_class)(void*, size_t);
typedef const char* (*p_class_get_name)(void*);
typedef const char* (*p_class_get_namespace)(void*);
typedef void*  (*p_class_get_method_from_name)(void*, const char*, int);
typedef void*  (*p_runtime_invoke)(void*, void*, void**, void**);
typedef void*  (*p_thread_attach)(void*);
typedef void*  (*p_object_unbox)(void*);
typedef void*  (*p_class_get_type)(void*);
typedef void*  (*p_type_get_object)(void*);

static p_domain_get f_domain; static p_domain_get_assemblies f_asm;
static p_assembly_get_image f_img; static p_image_get_class_count f_cnt;
static p_image_get_class f_cls; static p_class_get_name f_cname;
static p_class_get_namespace f_ns; static p_class_get_method_from_name f_method;
static p_runtime_invoke f_invoke; static p_thread_attach f_attach;
static p_object_unbox f_unbox; static p_class_get_type f_get_type;
static p_type_get_object f_type_obj;

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    return p ? p : dlsym(RTLD_NEXT, n);
}

static BOOL resolve(void) {
    f_domain=(p_domain_get)sym("il2cpp_domain_get");
    f_asm=(p_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    f_img=(p_assembly_get_image)sym("il2cpp_assembly_get_image");
    f_cnt=(p_image_get_class_count)sym("il2cpp_image_get_class_count");
    f_cls=(p_image_get_class)sym("il2cpp_image_get_class");
    f_cname=(p_class_get_name)sym("il2cpp_class_get_name");
    f_ns=(p_class_get_namespace)sym("il2cpp_class_get_namespace");
    f_method=(p_class_get_method_from_name)sym("il2cpp_class_get_method_from_name");
    f_invoke=(p_runtime_invoke)sym("il2cpp_runtime_invoke");
    f_attach=(p_thread_attach)sym("il2cpp_thread_attach");
    f_unbox=(p_object_unbox)sym("il2cpp_object_unbox");
    f_get_type=(p_class_get_type)sym("il2cpp_class_get_type");
    f_type_obj=(p_type_get_object)sym("il2cpp_type_get_object");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_unbox &&
           f_get_type && f_type_obj;
}

static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap); va_end(ap); fflush(g_fp);
}

static void *cls_pc = NULL, *cls_cam = NULL, *cls_obj = NULL;

static void *find_class(const char *ns, const char *name) {
    void *dom = f_domain(); size_t n = 0;
    void **asms = f_asm(dom, &n);
    if (!asms) return NULL;
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        void *img = f_img(asms[i]); if (!img) continue;
        size_t cc = f_cnt(img);
        for (size_t c = 0; c < cc; c++) {
            void *k = f_cls(img, c); if (!k) continue;
            const char *nm = f_cname(k);
            if (!nm || strcmp(nm, name)) continue;
            if (ns) {
                const char *kns = f_ns(k);
                if (!kns || strcmp(kns, ns)) continue;
            }
            return k;
        }
    }
    return NULL;
}

typedef struct { float x, y, z; } V3;

static void *rdp(void *o, size_t off) {
    if (!o) return NULL;
    return *(void**)((uint8_t*)o + off);
}
static V3 rd3(void *o, size_t off) {
    V3 v = {0,0,0};
    if (!o) return v;
    memcpy(&v, (uint8_t*)o + off, 12);
    return v;
}

static BOOL world_to_screen(void *camera, V3 world, V3 *out) {
    if (!camera || !cls_cam) return NO;
    void *m = f_method(cls_cam, "WorldToScreenPoint", 1);
    if (!m) return NO;

    struct { V3 v; float pad; } __attribute__((aligned(16))) arg;
    arg.v = world;
    arg.pad = 0;

    void *params[1] = { &arg.v };
    void *exc = NULL;
    void *ret = f_invoke(m, camera, params, &exc);
    if (exc || !ret) return NO;

    V3 *p = (V3*)f_unbox(ret);
    if (!p) return NO;
    *out = *p;
    return YES;
}

// ============================================================
// 绘制视图
// ============================================================
@interface CfEspView : UIView
@property (nonatomic, strong) NSMutableArray<NSValue *> *rects;
@end

@implementation CfEspView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _rects = [NSMutableArray array];
    }
    return self;
}
// 命中测试返回 nil：触摸事件全部穿透给下层（游戏）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetStrokeColorWithColor(ctx,
        [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:0.95].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    for (NSValue *v in self.rects) {
        CGContextStrokeRect(ctx, [v CGRectValue]);
    }
}
@end

// 承载绘制层的窗口：不抢 key window，触摸全透传
@interface CfOverlayWindow : UIWindow
@end
@implementation CfOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
@end

// CADisplayLink 驱动
@interface CfDriver : NSObject
- (void)onTick:(CADisplayLink *)link;
@end

static CfEspView  *g_view = nil;
static UIWindow   *g_win  = nil;
static CADisplayLink *g_link = nil;
static CfDriver    *g_driver = nil;
static CGFloat g_sw = 0, g_sh = 0;
static int g_frameCount = 0;

static void draw_once(void);

@implementation CfDriver
- (void)onTick:(CADisplayLink *)link {
    @autoreleasepool { draw_once(); }
}
@end

// 取当前活动的 UIWindowScene -> keyWindow
static UIWindow *find_active_window(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *x in ws.windows) {
                if (x.isKeyWindow) return x;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
        // 退一步：任意 windowScene 的任意窗口
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
    return nil;
}

// ============================================================
// 每帧
// ============================================================
static void draw_once(void) {
    if (!g_view) return;
    g_frameCount++;
    if (g_frameCount == 1) w("draw_once 第一次进入\n");

    void *m = f_method(cls_obj, "FindObjectsOfType", 1);
    if (!m) { if (g_frameCount==1) w("no FindObjectsOfType\n"); return; }

    void *t = f_get_type(cls_pc);
    if (!t) { if (g_frameCount==1) w("no type\n"); return; }
    void *type = f_type_obj(t);
    if (!type) { if (g_frameCount==1) w("no typeObj\n"); return; }

    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(m, NULL, params, &exc);
    if (exc || !ret) { if (g_frameCount==1) w("invoke fail\n"); return; }

    Il2CppArray *arr = (Il2CppArray*)ret;
    size_t len = arr->max_length;

    NSMutableArray *rects = [NSMutableArray array];
    int okCount = 0;

    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;

        void *mv  = rdp(pc, 0x40);
        void *cam = rdp(pc, 0x30);
        if (!mv || !cam) continue;

        V3 pos = rd3(mv, 0x268);
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

        V3 head = { pos.x, pos.y + 0.75f, pos.z };
        V3 sH, sF;
        if (!world_to_screen(cam, head, &sH)) continue;
        if (!world_to_screen(cam, pos, &sF)) continue;
        if (sH.z < 0 || sF.z < 0) continue;

        CGFloat yHead = g_sh - sH.y;
        CGFloat yFoot = g_sh - sF.y;
        CGFloat h = fabs(yFoot - yHead);
        if (h < 4 || h > g_sh) continue;
        CGFloat wpx = h * 0.45f;

        [rects addObject:[NSValue valueWithCGRect:
            CGRectMake(sH.x - wpx*0.5f, yHead, wpx, h)]];
        okCount++;
    }

    if (g_frameCount == 1 || g_frameCount == 60 || g_frameCount == 300) {
        w("frame=%d 实例=%zu 框=%d\n", g_frameCount, len, okCount);
    }

    g_view.rects = rects;
    [g_view setNeedsDisplay];
}

// ============================================================
// 悬浮窗
// ============================================================
static UIWindow *g_panel = nil;

static void attach_panel(void) {
    if (g_panel) return;

    UIWindowScene *ws = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { ws = (UIWindowScene*)sc; break; }
        }
    }

    CGRect f = CGRectMake(40, 120, 210, 96);
    UIWindow *win = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                       : [[UIWindow alloc] initWithFrame:f];
    win.frame = f;
    win.windowLevel = UIWindowLevelAlert + 1000;
    win.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
    win.layer.cornerRadius = 10;
    win.layer.masksToBounds = YES;
    win.hidden = NO;
    win.rootViewController = [[UIViewController alloc] init];
    win.rootViewController.view.backgroundColor = [UIColor clearColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 150, 22)];
    title.text = @"CF ESP";
    title.textColor = [UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:15];
    [win.rootViewController.view addSubview:title];

    UILabel *stat = [[UILabel alloc] initWithFrame:CGRectMake(12, 34, 190, 18)];
    stat.text = [NSString stringWithFormat:@"%.0fx%.0f", g_sw, g_sh];
    stat.textColor = [UIColor whiteColor];
    stat.font = [UIFont systemFontOfSize:11];
    [win.rootViewController.view addSubview:stat];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, 58, 190, 18)];
    hint.text = @"ESP active";
    hint.textColor = [UIColor lightGrayColor];
    hint.font = [UIFont systemFontOfSize:10];
    [win.rootViewController.view addSubview:hint];

    // 悬浮窗也要能接收触摸，所以只对这块区域开命中，其余穿透
    win.hidden = NO;
    g_panel = win;
    w("悬浮窗已挂载\n");
}
// ============================================================
// 启动
// ============================================================
static void boot(void) {
    if (!resolve()) { w("resolve fail\n"); return; }
    f_attach(f_domain());

    cls_pc  = find_class(NULL, "PlayerController");
    cls_cam = find_class("UnityEngine", "Camera");
    cls_obj = find_class("UnityEngine", "Object");
    w("classes pc=%p cam=%p obj=%p\n", cls_pc, cls_cam, cls_obj);
    if (!cls_pc || !cls_cam || !cls_obj) { w("类缺失\n"); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = find_active_window();
        if (!host) { w("没找到活动窗口\n"); return; }

        g_sw = host.bounds.size.width;
        g_sh = host.bounds.size.height;
        w("host window %.0fx%.0f\n", g_sw, g_sh);

        // 独立窗口承载绘制层，盖在 Unity 之上，但不抢 key window
        UIWindowScene *ws = host.windowScene;
        g_win = ws ? [[CfOverlayWindow alloc] initWithWindowScene:ws]
                   : [[CfOverlayWindow alloc] initWithFrame:host.bounds];
        g_win.frame = host.bounds;
        g_win.windowLevel = UIWindowLevelAlert + 900;
        g_win.backgroundColor = [UIColor clearColor];
        g_win.rootViewController = [[UIViewController alloc] init];
        g_win.rootViewController.view.backgroundColor = [UIColor clearColor];
        g_win.rootViewController.view.userInteractionEnabled = NO;

        g_view = [[CfEspView alloc] initWithFrame:g_win.bounds];
        g_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_win.rootViewController.view addSubview:g_view];

        // 关键：hidden = NO 就够，不调 makeKeyAndVisible，否则会抢走游戏触摸
        g_win.hidden = NO;
        w("绘制窗口已挂载\n");

        attach_panel();

        // CADisplayLink 驱动，跟游戏帧循环同一个 runloop
        g_driver = [[CfDriver alloc] init];
        g_link = [CADisplayLink displayLinkWithTarget:g_driver
                                             selector:@selector(onTick:)];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        w("显示链接已启动 %p\n", g_link);
    });
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_esp.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("dylib loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool { boot(); }
    });
}
