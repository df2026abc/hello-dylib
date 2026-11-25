// cf_all.mm — CounterFlame 透视 + 上色 合并版 v12
//
// 关键修正：
//   1. 所有 IL2CPP 调用都在主线程（后台线程调 runtime_invoke 会拿到空）
//   2. CADisplayLink 同时挂 Default 和 Common 两种 runloop 模式
//   3. 每帧做三件事：扫相机矩阵 -> 画框 -> 上色
//
// 已知偏移（实测）：
//   PlayerController._mainCamera         0x30
//   PlayerController._movementController 0x40
//   PlayerController.skeleton            0x78
//   PlayerController._isDeath            0xa8
//   PlayerMovement._currSimPosition      0x268
//   PlayerSkeleton.GhostAlpha            0x00
//   PlayerSkeleton.SrcBlendId            0x04
//   PlayerSkeleton.DstBlendId            0x08
//   PlayerSkeleton._ghost                0x182
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit -framework QuartzCore \
//     -install_name @executable_path/cf_all.dylib \
//     cf_all.mm -o cf_all.dylib

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
typedef void*  (*p_class_get_type)(void*);
typedef void*  (*p_type_get_object)(void*);

static p_domain_get f_domain; static p_domain_get_assemblies f_asm;
static p_assembly_get_image f_img; static p_image_get_class_count f_cnt;
static p_image_get_class f_cls; static p_class_get_name f_cname;
static p_class_get_method_from_name f_method; static p_runtime_invoke f_invoke;
static p_thread_attach f_attach;
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
    f_get_type=(p_class_get_type)sym("il2cpp_class_get_type");
    f_type_obj=(p_type_get_object)sym("il2cpp_type_get_object");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_get_type && f_type_obj;
}

static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap); va_end(ap); fflush(g_fp);
}

// 屏幕尺寸
static CGFloat g_sw = 0, g_sh = 0;

static void *cls_pc = NULL, *cls_obj = NULL;
static void *g_find_method = NULL;   // 找到的 FindObjectsOfType 方法

// 全库扫描：找到持有 FindObjectsOfType(1 参) 的类和方法
static void find_object_finder(void) {
    void *dom = f_domain(); size_t n = 0;
    void **asms = f_asm(dom, &n);
    if (!asms) return;

    for (size_t i = 0; i < n && !g_find_method; i++) {
        if (!asms[i]) continue;
        void *img = f_img(asms[i]); if (!img) continue;
        size_t cc = f_cnt(img);
        for (size_t c = 0; c < cc && !g_find_method; c++) {
            void *k = f_cls(img, c); if (!k) continue;
            // 先看类名，只在名字像 Object 的类上试，减少开销
            const char *nm = f_cname(k);
            if (!nm) continue;
            if (strcmp(nm, "Object") && strcmp(nm, "GameObject") && strcmp(nm, "Component"))
                continue;

            void *m = f_method(k, "FindObjectsOfType", 1);
            if (m) {
                g_find_method = m;
                cls_obj = k;
                w("找到 FindObjectsOfType: class=%s method=%p\n", nm, m);
                return;
            }
        }
    }
    w("全库扫描：没有找到 FindObjectsOfType\n");
}

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
typedef struct { float x, y; BOOL valid; } SCREEN;

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
// 偏移
// ============================================================
#define OFF_PC_CAM     0x30
#define OFF_PC_MV      0x40
#define OFF_PC_ARMS    0x60
#define OFF_PC_SK      0x78
#define OFF_PC_DEAD    0xa8
#define OFF_MV_POS     0x268
#define OFF_SK_ALPHA   0x00
#define OFF_SK_SRCBLEND 0x04
#define OFF_SK_DSTBLEND 0x08
#define OFF_SK_GHOST   0x182

// ArmsController 后坐力
#define OFF_ARMS_RECOIL_V  0x1cc
#define OFF_ARMS_RECOIL_H  0x1d0
#define OFF_ARMS_VEL_V     0x1d4
#define OFF_ARMS_VEL_H     0x1d8
#define OFF_ARMS_KICK_V    0x1e8
#define OFF_ARMS_KICK_H    0x1ec

// ============================================================
// 矩阵投影
// ============================================================
static SCREEN matrix_project(const float *m, V3 o, CGFloat sw, CGFloat sh) {
    SCREEN s = {0,0,NO};
    float wv = m[3]*o.x + m[7]*o.y + m[11]*o.z + m[15];
    if (wv < 0.5f) wv = 0.5f;
    float x = (sw*0.5f) + (m[0]*o.x + m[4]*o.y + m[8]*o.z + m[12]) / wv * (sw*0.5f);
    float y = (sh*0.5f) - (m[1]*o.x + m[5]*o.y + m[9]*o.z + m[13]) / wv * (sh*0.5f);
    if (!isfinite(x) || !isfinite(y)) return s;
    s.x = x; s.y = y; s.valid = YES;
    return s;
}

// 在相机对象里找 4x4 矩阵
static BOOL scan_matrix(void *cam, size_t *outOff, float *outMat) {
    if (!cam) return NO;
    for (size_t off = 0x20; off < 0x800; off += 4) {
        float m[16];
        BOOL ok = YES; int zeros = 0, big = 0;
        for (int k = 0; k < 16; k++) {
            m[k] = *(float*)((uint8_t*)cam + off + k*4);
            if (!isfinite(m[k])) { ok = NO; break; }
            if (m[k] == 0.0f) zeros++;
            if (fabsf(m[k]) > 1e4f) big++;
        }
        if (!ok || zeros < 3 || big > 0) continue;

        float m11 = m[11], m14 = m[14], m15 = m[15];
        BOOL looks = (fabsf(fabsf(m11) - 1.0f) < 0.2f) ||
                     (fabsf(fabsf(m14) - 1.0f) < 0.2f) ||
                     (fabsf(fabsf(m15) - 1.0f) < 0.2f && fabsf(m[3]) < 1e-3f);
        if (!looks) continue;

        *outOff = off;
        memcpy(outMat, m, 64);
        return YES;
    }
    return NO;
}

// ============================================================
// 视图：CALayer 画框
// ============================================================
@interface CfView : UIView
@property (nonatomic, strong) NSMutableArray<CALayer *> *layers;
@end

@implementation CfView
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
        l.borderColor = [UIColor colorWithRed:0.1 green:1 blue:0.3 alpha:0.95].CGColor;
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

@interface CfWindow : UIWindow
@end
@implementation CfWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@interface CfDriver : NSObject
- (void)onTick:(CADisplayLink *)link;
@end

static CfView   *g_view = nil;
static UIWindow *g_win  = nil;
static CADisplayLink *g_link = nil;
static CfDriver *g_driver = nil;
static int g_frame = 0;
static BOOL g_matOK = NO;
static size_t g_matOff = 0;
static float g_mat[16];

static void tick(void);

@implementation CfDriver
- (void)onTick:(CADisplayLink *)link {
    @autoreleasepool { tick(); }
}
@end

// ============================================================
// 主循环（全部在主线程执行）
// ============================================================
static void tick(void) {
    g_frame++;
    if (g_frame == 1) w("tick 进入 view=%p pc=%p obj=%p\n", g_view, cls_pc, cls_obj);
    if (!g_view || !cls_pc) return;

    // 第一次进来时找 FindObjectsOfType
    if (!g_find_method) {
        find_object_finder();
        if (!g_find_method) {
            if (g_frame == 10) w("frame=%d 仍未找到 FindObjectsOfType\n", g_frame);
            return;
        }
    }

    void *t = f_get_type(cls_pc);
    void *type = t ? f_type_obj(t) : NULL;
    if (!type) { if (g_frame == 1) w("type 为空\n"); return; }

    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(g_find_method, NULL, params, &exc);
    if (exc || !ret) { if (g_frame == 1) w("invoke 失败\n"); return; }

    Il2CppArray *arr = (Il2CppArray*)ret;
    size_t len = arr->max_length;

    // 找相机（用有坐标的玩家）
    void *cam = NULL;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + OFF_PC_DEAD)) continue;
        void *mv = rdp(pc, OFF_PC_MV);
        if (!mv) continue;
        V3 p = rd3(mv, OFF_MV_POS);
        if (p.x == 0 && p.y == 0 && p.z == 0) continue;
        cam = rdp(pc, OFF_PC_CAM);
        if (cam) break;
    }

    // 首次扫矩阵
    if (cam && !g_matOK) {
        if (scan_matrix(cam, &g_matOff, g_mat)) {
            g_matOK = YES;
            w("\n矩阵 @cam+0x%zx\n", g_matOff);
            w("  [%.3f %.3f %.3f %.3f]\n", g_mat[0],g_mat[1],g_mat[2],g_mat[3]);
            w("  [%.3f %.3f %.3f %.3f]\n", g_mat[4],g_mat[5],g_mat[6],g_mat[7]);
            w("  [%.3f %.3f %.3f %.3f]\n", g_mat[8],g_mat[9],g_mat[10],g_mat[11]);
            w("  [%.3f %.3f %.3f %.3f]\n", g_mat[12],g_mat[13],g_mat[14],g_mat[15]);
        }
    }

    NSMutableArray *boxes = [NSMutableArray array];
    int boxCount = 0, colorCount = 0, recoilCount = 0;

    // ============ 无后座：每帧清零 ============
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        void *arms = rdp(pc, OFF_PC_ARMS);
        if (!arms) continue;
        uint8_t *a = (uint8_t*)arms;
        float zero = 0.0f;
        memcpy(a + OFF_ARMS_RECOIL_V, &zero, 4);
        memcpy(a + OFF_ARMS_RECOIL_H, &zero, 4);
        memcpy(a + OFF_ARMS_VEL_V,    &zero, 4);
        memcpy(a + OFF_ARMS_VEL_H,    &zero, 4);
        memcpy(a + OFF_ARMS_KICK_V,   &zero, 4);
        memcpy(a + OFF_ARMS_KICK_H,   &zero, 4);
        recoilCount++;
    }

    if (cam && g_matOK) {
        // 每帧重新读矩阵（相机在动）
        memcpy(g_mat, (uint8_t*)cam + g_matOff, 64);

        for (size_t i = 0; i < len; i++) {
            void *pc = arr->vector[i];
            if (!pc) continue;
            if (*(uint8_t*)((uint8_t*)pc + OFF_PC_DEAD)) continue;

            void *mv = rdp(pc, OFF_PC_MV);
            if (!mv) continue;
            V3 pos = rd3(mv, OFF_MV_POS);
            if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

            // --- 上色 ---
            void *sk = rdp(pc, OFF_PC_SK);
            if (sk) {
                float ga = 0.45f;
                memcpy((uint8_t*)sk + OFF_SK_ALPHA, &ga, 4);
                int src = 2, dst = 10;
                memcpy((uint8_t*)sk + OFF_SK_SRCBLEND, &src, 4);
                memcpy((uint8_t*)sk + OFF_SK_DSTBLEND, &dst, 4);
                *(uint8_t*)((uint8_t*)sk + OFF_SK_GHOST) = 1;
                colorCount++;
            }

            // --- 画框 ---
            V3 head = { pos.x, pos.y + 0.75f, pos.z };
            SCREEN sh = matrix_project(g_mat, head, g_sw, g_sh);
            SCREEN sf = matrix_project(g_mat, pos, g_sw, g_sh);
            if (!sh.valid || !sf.valid) continue;

            CGFloat bh = fabs(sf.y - sh.y);
            if (bh < 4 || bh > g_sh * 2) continue;
            CGFloat bw = bh * 0.45f;
            CGRect r = CGRectMake(sh.x - bw*0.5f, sh.y, bw, bh);
            [boxes addObject:[NSValue valueWithBytes:&r objCType:@encode(CGRect)]];
            boxCount++;
        }
    }

    if (g_frame == 1 || g_frame == 120 || g_frame == 600) {
        w("frame=%d 玩家=%zu 矩阵=%s 框=%d 上色=%d 无后座=%d\n",
          g_frame, len, g_matOK ? "OK" : "无", boxCount, colorCount, recoilCount);
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

    cls_pc = find_class("PlayerController");
    w("cls pc=%p\n", cls_pc);
    if (!cls_pc) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = find_window();
        if (!host) { w("没窗口\n"); return; }
        g_sw = host.bounds.size.width;
        g_sh = host.bounds.size.height;
        w("屏幕 %.0fx%.0f\n", g_sw, g_sh);

        UIWindowScene *ws = host.windowScene;
        g_win = ws ? [[CfWindow alloc] initWithWindowScene:ws]
                   : [[CfWindow alloc] initWithFrame:host.bounds];
        g_win.frame = host.bounds;
        g_win.windowLevel = UIWindowLevelAlert + 900;
        g_win.backgroundColor = [UIColor clearColor];
        g_win.rootViewController = [[UIViewController alloc] init];
        g_win.rootViewController.view.backgroundColor = [UIColor clearColor];
        g_win.rootViewController.view.userInteractionEnabled = NO;

        g_view = [[CfView alloc] initWithFrame:g_win.bounds];
        g_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_win.rootViewController.view addSubview:g_view];
        g_win.hidden = NO;

        g_driver = [[CfDriver alloc] init];
        g_link = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(onTick:)];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        w("启动 link=%p\n", g_link);
    });
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_all.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("v12 loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool { boot(); }
    });
}
