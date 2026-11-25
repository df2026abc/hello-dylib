// cf_esp.mm — CounterFlame 透视 v10：Transform 自算投影
//
// 思路：不再用 WorldToScreenPoint，用相机 Transform 自己算
//   1. 读 _cameraTransform（PlayerMovement 0x30）的位置和朝向
//   2. 相机空间 = 世界坐标 - 相机位置，再按相机旋转反向转
//   3. 用 FOV 和宽高比投影到屏幕
//
// 偏移（实测）：
//   PlayerController._mainCamera         0x30
//   PlayerController._movementController 0x40
//   PlayerController._isDeath            0xa8
//   PlayerMovement._cameraTransform      0x30
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
typedef void*  (*p_class_get_method_from_name)(void*, const char*, int);
typedef void*  (*p_runtime_invoke)(void*, void*, void**, void**);
typedef void*  (*p_thread_attach)(void*);
typedef void*  (*p_object_unbox)(void*);
typedef void*  (*p_class_get_type)(void*);
typedef void*  (*p_type_get_object)(void*);

static p_domain_get f_domain; static p_domain_get_assemblies f_asm;
static p_assembly_get_image f_img; static p_image_get_class_count f_cnt;
static p_image_get_class f_cls; static p_class_get_name f_cname;
static p_class_get_method_from_name f_method; static p_runtime_invoke f_invoke;
static p_thread_attach f_attach; static p_object_unbox f_unbox;
static p_class_get_type f_get_type; static p_type_get_object f_type_obj;

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
    f_method=(p_class_get_method_from_name)sym("il2cpp_class_get_method_from_name");
    f_invoke=(p_runtime_invoke)sym("il2cpp_runtime_invoke");
    f_attach=(p_thread_attach)sym("il2cpp_thread_attach");
    f_unbox=(p_object_unbox)sym("il2cpp_object_unbox");
    f_get_type=(p_class_get_type)sym("il2cpp_class_get_type");
    f_type_obj=(p_type_get_object)sym("il2cpp_type_get_object");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_unbox && f_get_type && f_type_obj;
}

static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap); va_end(ap); fflush(g_fp);
}

static void *cls_pc = NULL, *cls_obj = NULL, *cls_cam = NULL, *cls_tf = NULL;

static void *find_class(const char *name) {
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
            if (nm && !strcmp(nm, name)) return k;
        }
    }
    return NULL;
}

typedef struct { float x, y, z; } V3;
typedef struct { float x, y, z, w; } Q4;

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

// 调 Transform.get_position / get_rotation
static BOOL tf_get_position(void *tf, V3 *out) {
    if (!tf || !cls_tf) return NO;
    void *m = f_method(cls_tf, "get_position", 0);
    if (!m) return NO;
    void *exc = NULL;
    void *ret = f_invoke(m, tf, NULL, &exc);
    if (exc || !ret) return NO;
    V3 *p = (V3*)f_unbox(ret);
    if (!p) return NO;
    *out = *p;
    return YES;
}

static BOOL tf_get_forward(void *tf, V3 *out) {
    if (!tf || !cls_tf) return NO;
    void *m = f_method(cls_tf, "get_forward", 0);
    if (!m) return NO;
    void *exc = NULL;
    void *ret = f_invoke(m, tf, NULL, &exc);
    if (exc || !ret) return NO;
    V3 *p = (V3*)f_unbox(ret);
    if (!p) return NO;
    *out = *p;
    return YES;
}

// ============================================================
// 自己算投影
// 相机位置 C，朝向 F（forward），目标 P
// 相机空间坐标：right/up/forward 基向量投影
// ============================================================
static BOOL world_to_screen_manual(void *tf_cam, V3 target, V3 *out) {
    V3 camPos, fwd;
    V3 up, right;

    if (!tf_get_position(tf_cam, &camPos)) return NO;
    if (!tf_get_forward(tf_cam, &fwd)) {
        // forward 拿不到就用 up 也拿不到，直接失败
        return NO;
    }

    // 归一化 forward
    float fl = sqrtf(fwd.x*fwd.x + fwd.y*fwd.y + fwd.z*fwd.z);
    if (fl < 1e-6f) return NO;
    fwd.x /= fl; fwd.y /= fl; fwd.z /= fl;

    // 世界 UP
    V3 worldUp = {0, 1, 0};

    // right = forward × up
    right.x = fwd.y*worldUp.z - fwd.z*worldUp.y;
    right.y = fwd.z*worldUp.x - fwd.x*worldUp.z;
    right.z = fwd.x*worldUp.y - fwd.y*worldUp.x;
    float rl = sqrtf(right.x*right.x + right.y*right.y + right.z*right.z);
    if (rl < 1e-6f) return NO;
    right.x /= rl; right.y /= rl; right.z /= rl;

    // up = right × forward
    up.x = right.y*fwd.z - right.z*fwd.y;
    up.y = right.z*fwd.x - right.x*fwd.z;
    up.z = right.x*fwd.y - right.y*fwd.x;

    // 目标相对相机
    V3 d = { target.x - camPos.x, target.y - camPos.y, target.z - camPos.z };

    // 相机空间
    float cx = d.x*right.x + d.y*right.y + d.z*right.z;
    float cy = d.x*up.x    + d.y*up.y    + d.z*up.z;
    float cz = d.x*fwd.x   + d.y*fwd.y   + d.z*fwd.z;

    if (cz <= 0.01f) return NO;   // 在背后

    // 用固定 FOV 做透视
    const float fovDeg = 60.0f;
    float tanHalf = tanf(fovDeg * 0.5f * (float)M_PI / 180.0f);

    float ndcX = (cx / cz) / (tanHalf * g_aspect);
    float ndcY = (cy / cz) / tanHalf;

    out->x = (ndcX * 0.5f + 0.5f) * g_sw;
    out->y = (ndcY * 0.5f + 0.5f) * g_sh;
    out->z = cz;
    return YES;
}

// ============================================================
// 视图
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
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
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

@interface CfOverlayWindow : UIWindow
@end
@implementation CfOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

static CfEspView *g_view = nil;
static UIWindow *g_win = nil;
static CADisplayLink *g_link = nil;
static id g_driver = nil;
static CGFloat g_sw = 0, g_sh = 0;
static float g_aspect = 1.0f;
static int g_frameCount = 0;

static void draw_once(void);

@interface CfDriver : NSObject
- (void)onTick:(CADisplayLink *)link;
@end
@implementation CfDriver
- (void)onTick:(CADisplayLink *)link {
    @autoreleasepool { draw_once(); }
}
@end

// ============================================================
// 每帧
// ============================================================
static void draw_once(void) {
    if (!g_view) return;
    g_frameCount++;

    void *m = f_method(cls_obj, "FindObjectsOfType", 1);
    if (!m) return;
    void *t = f_get_type(cls_pc);
    void *type = t ? f_type_obj(t) : NULL;
    if (!type) return;

    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(m, NULL, params, &exc);
    if (exc || !ret) return;

    Il2CppArray *arr = (Il2CppArray*)ret;
    size_t len = arr->max_length;

    // 先找本地玩家的相机（有坐标的那个）
    void *localCamTf = NULL;
    int validCount = 0;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;
        void *mv = rdp(pc, 0x40);
        if (!mv) continue;
        V3 pos = rd3(mv, 0x268);
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;
        validCount++;
        if (!localCamTf) localCamTf = rdp(mv, 0x30);
    }

    NSMutableArray *rects = [NSMutableArray array];
    int okCount = 0;

    if (localCamTf && validCount > 0) {
        for (size_t i = 0; i < len; i++) {
            void *pc = arr->vector[i];
            if (!pc) continue;
            if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;
            void *mv = rdp(pc, 0x40);
            if (!mv) continue;
            V3 pos = rd3(mv, 0x268);
            if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

            V3 head = { pos.x, pos.y + 0.75f, pos.z };
            V3 sH, sF;
            if (!world_to_screen_manual(localCamTf, head, &sH)) continue;
            if (!world_to_screen_manual(localCamTf, pos, &sF)) continue;

            CGFloat yHead = g_sh - sH.y;
            CGFloat yFoot = g_sh - sF.y;
            CGFloat h = fabs(yFoot - yHead);
            if (h < 4 || h > g_sh * 1.5f) continue;
            CGFloat wpx = h * 0.45f;

            [rects addObject:[NSValue valueWithCGRect:
                CGRectMake(sH.x - wpx*0.5f, yHead, wpx, h)]];
            okCount++;
        }
    }

    if (g_frameCount == 60 || g_frameCount == 300) {
        V3 cp = {0,0,0};
        if (localCamTf) tf_get_position(localCamTf, &cp);
        w("frame=%d 实例=%zu 有效=%d 框=%d camTf=%p camPos=(%.1f,%.1f,%.1f)\n",
          g_frameCount, len, validCount, okCount, localCamTf, cp.x, cp.y, cp.z);
    }

    g_view.rects = rects;
    [g_view setNeedsDisplay];
}

// ============================================================
// 启动
// ============================================================
static UIWindow *find_active_window(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *x in ws.windows) if (x.isKeyWindow) return x;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
    return nil;
}

static void boot(void) {
    if (!resolve()) { w("resolve fail\n"); return; }
    f_attach(f_domain());

    cls_pc  = find_class("PlayerController");
    cls_obj = find_class("Object");
    cls_cam = find_class("Camera");
    cls_tf  = find_class("Transform");
    w("classes pc=%p obj=%p cam=%p tf=%p\n", cls_pc, cls_obj, cls_cam, cls_tf);
    if (!cls_pc || !cls_obj || !cls_tf) { w("类缺失\n"); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = find_active_window();
        if (!host) { w("没窗口\n"); return; }

        g_sw = host.bounds.size.width;
        g_sh = host.bounds.size.height;
        g_aspect = g_sw / g_sh;
        w("host %.0fx%.0f aspect=%.3f\n", g_sw, g_sh, g_aspect);

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
        g_win.hidden = NO;

        g_driver = [[CfDriver alloc] init];
        g_link = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(onTick:)];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        w("启动完成\n");
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
