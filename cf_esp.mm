// cf_esp.mm — CounterFlame 透视 v11：矩阵投影（参考 Free Fire 开源方案）
//
// 核心思路：
//   1. 拿到相机的 4x4 view-projection 矩阵（16 个 float）
//   2. 用矩阵直接算屏幕坐标，不调任何游戏函数
//   3. 用 CALayer 画框，不用 drawRect
//
// 已知偏移（实测）：
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

static void *cls_pc = NULL, *cls_obj = NULL, *cls_cam = NULL;
static CGFloat g_sw = 0, g_sh = 0;

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

// ============================================================
// 矩阵投影（参考 Free Fire 开源实现）
// ============================================================
typedef struct { float x, y; BOOL valid; } SCREEN;

static SCREEN matrix_project(const float *m, V3 obj, CGFloat sw, CGFloat sh) {
    SCREEN s = {0, 0, NO};

    float w = m[3]*obj.x + m[7]*obj.y + m[11]*obj.z + m[15];
    if (w < 0.5f) w = 0.5f;

    float x = (sw * 0.5f) + (m[0]*obj.x + m[4]*obj.y + m[8]*obj.z + m[12]) / w * (sw * 0.5f);
    float y = (sh * 0.5f) - (m[1]*obj.x + m[5]*obj.y + m[9]*obj.z + m[13]) / w * (sh * 0.5f);

    if (!isfinite(x) || !isfinite(y)) return s;
    s.x = x; s.y = y; s.valid = YES;
    return s;
}

// ============================================================
// 视图（CALayer 画框）
// ============================================================
@interface CfEspView : UIView
@property (nonatomic, strong) NSMutableArray<CALayer *> *layers;
@end

@implementation CfEspView
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _layers = [NSMutableArray array];
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }

- (void)setBoxes:(NSArray<NSValue *> *)boxes {
    NSUInteger n = boxes.count;
    if (n == 0) {
        for (CALayer *l in self.layers) [l removeFromSuperlayer];
        [self.layers removeAllObjects];
        return;
    }
    while (self.layers.count < n) {
        CALayer *l = [CALayer layer];
        l.borderColor = [UIColor colorWithRed:0.1 green:1 blue:0.3 alpha:0.9].CGColor;
        l.borderWidth = 2.0;
        l.cornerRadius = 2.0;
        [self.layer addSublayer:l];
        [self.layers addObject:l];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < self.layers.count; i++) {
        CALayer *l = self.layers[i];
        if (i < n) {
            CGRect r;
            [boxes[i] getValue:&r];
            l.hidden = NO;
            l.frame = r;
        } else {
            l.hidden = YES;
        }
    }
    [CATransaction commit];
}
@end

@interface CfOverlayWindow : UIWindow
@end
@implementation CfOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@interface CfDriver : NSObject
- (void)onTick:(CADisplayLink *)link;
@end

static CfEspView *g_view = nil;
static UIWindow *g_win = nil;
static CADisplayLink *g_link = nil;
static CfDriver *g_driver = nil;
static int g_frame = 0;
static BOOL g_matrixFound = NO;
static size_t g_matOff = 0;

static void tick(void);

@implementation CfDriver
- (void)onTick:(CADisplayLink *)link {
    @autoreleasepool { tick(); }
}
@end

// ============================================================
// 扫相机对象里的矩阵
// 判据：16 个 float，有限，不太大，像 view-projection 矩阵
// ============================================================
static BOOL scan_matrix(void *cam, size_t *outOff) {
    if (!cam) return NO;
    for (size_t off = 0x20; off < 0x800; off += 4) {
        float m[16];
        BOOL ok = YES;
        int zeros = 0, big = 0;
        for (int k = 0; k < 16; k++) {
            m[k] = *(float*)((uint8_t*)cam + off + k*4);
            if (!isfinite(m[k])) { ok = NO; break; }
            if (m[k] == 0.0f) zeros++;
            if (fabsf(m[k]) > 1e4f) big++;
        }
        if (!ok || zeros < 3 || big > 0) continue;

        // view-projection 矩阵特征：右下角通常非 0，且 m[15] 常为小数
        // 或者 m[11] 或 m[14] 接近 ±1
        float m11 = m[11], m14 = m[14], m15 = m[15];
        BOOL looks = (fabsf(fabsf(m11) - 1.0f) < 0.2f) ||
                     (fabsf(fabsf(m14) - 1.0f) < 0.2f) ||
                     (fabsf(fabsf(m15) - 1.0f) < 0.2f && fabsf(m[3]) < 1e-3f);
        if (!looks) continue;

        *outOff = off;
        return YES;
    }
    return NO;
}

// ============================================================
// 主循环
// ============================================================
static void tick(void) {
    if (!g_view || !cls_pc || !cls_obj) return;
    g_frame++;

    // 拿玩家
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

    // 找一个有坐标的玩家拿相机
    void *cam = NULL;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;
        void *mv = rdp(pc, 0x40);
        if (!mv) continue;
        V3 p = rd3(mv, 0x268);
        if (p.x == 0 && p.y == 0 && p.z == 0) continue;
        cam = rdp(pc, 0x30);
        if (cam) break;
    }

    // 首次扫矩阵
    if (cam && !g_matrixFound) {
        if (scan_matrix(cam, &g_matOff)) {
            g_matrixFound = YES;
            w("找到矩阵 @cam+0x%zx\n", g_matOff);
            float mm[16];
            memcpy(mm, (uint8_t*)cam + g_matOff, 64);
            w("  [%.3f %.3f %.3f %.3f]\n", mm[0],mm[1],mm[2],mm[3]);
            w("  [%.3f %.3f %.3f %.3f]\n", mm[4],mm[5],mm[6],mm[7]);
            w("  [%.3f %.3f %.3f %.3f]\n", mm[8],mm[9],mm[10],mm[11]);
            w("  [%.3f %.3f %.3f %.3f]\n", mm[12],mm[13],mm[14],mm[15]);
        } else if (g_frame == 60) {
            w("相机 %p 扫不到矩阵\n", cam);
        }
    }

    if (!g_matrixFound || !cam) {
        if (g_frame == 120) w("frame=120 玩家=%zu 矩阵未就绪\n", len);
        return;
    }

    float mat[16];
    memcpy(mat, (uint8_t*)cam + g_matOff, 64);

    NSMutableArray *boxes = [NSMutableArray array];
    int ok = 0;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;
        void *mv = rdp(pc, 0x40);
        if (!mv) continue;
        V3 pos = rd3(mv, 0x268);
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

        V3 head = { pos.x, pos.y + 0.75f, pos.z };
        SCREEN sh = matrix_project(mat, head, g_sw, g_sh);
        SCREEN sf = matrix_project(mat, pos, g_sw, g_sh);
        if (!sh.valid || !sf.valid) continue;

        CGFloat bh = fabs(sf.y - sh.y);
        if (bh < 4 || bh > g_sh * 2) continue;
        CGFloat bw = bh * 0.45f;
        CGRect r = CGRectMake(sh.x - bw*0.5f, sh.y, bw, bh);

        [boxes addObject:[NSValue valueWithBytes:&r objCType:@encode(CGRect)]];
        ok++;
    }

    if (g_frame == 120 || g_frame == 600) {
        w("frame=%d 玩家=%zu 框=%d\n", g_frame, len, ok);
    }
    [g_view setBoxes:boxes];
}

// ============================================================
// 启动
// ============================================================
static UIWindow *find_window(void) {
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
    w("cls pc=%p obj=%p cam=%p\n", cls_pc, cls_obj, cls_cam);
    if (!cls_pc || !cls_obj) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = find_window();
        if (!host) { w("没窗口\n"); return; }
        g_sw = host.bounds.size.width;
        g_sh = host.bounds.size.height;
        w("屏幕 %.0fx%.0f\n", g_sw, g_sh);

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
        w("启动\n");
    });
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_esp.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("v11 loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool { boot(); }
    });
}
