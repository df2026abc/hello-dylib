// cf_probe3.mm — CounterFlame 诊断版 v13
//
// 目标：一次跑完，把下面三个未知量全部测掉，不再靠猜。
//   1) PlayerController 的 +0x30/0x40/0x60/0x78/0x90 到底指向什么类（偏移表真伪）
//   2) PlayerMovement 的 0x268 是不是世界坐标（位置偏移真伪）
//   3) 相机矩阵能不能从 Camera.get_worldToCameraMatrix / get_projectionMatrix 拿到
//
// 只读不写：本文件不写游戏内存，只读 + 打日志。
//
// 编译：
//   clang++ -target arm64-apple-ios15.0 -isysroot $SDK \
//     -dynamiclib -fobjc-arc -std=c++17 -O2 -fuse-ld=lld \
//     -Wl,-undefined,dynamic_lookup \
//     -Wl,-install_name,@executable_path/cf_probe3.dylib \
//     -framework Foundation -framework UIKit \
//     cf_probe3.mm -o cf_probe3.dylib
//
// 日志：App 沙盒 Documents/cf_probe3.txt（第 60 帧集中输出一次，之后停）
//
// 输出怎么读：
//   [类名校验] 每行 "+0xNN -> ClassName"。ClassName 为空或不对，说明该偏移无效。
//   [位置窗口] 每行 16 个 float。正常人形坐标是 3 个连续且量级相近的数（如 12.3 -0.8 45.6），
//              且不同玩家的值不同。若全是 0 或全是 0.000，0x268 就是错的。
//   [相机]     get_main 返回的指针与类名；两个矩阵各 64 字节原始内容。
//   [投影命中] 四种组合各自的命中百分比。>=50% 的那个就是可用矩阵。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>

// ============================================================
// il2cpp 绑定
// ============================================================
typedef void        *(*p_domain)(void);
typedef void       **(*p_asms)(void *, size_t *);
typedef void        *(*p_img)(void *);
typedef size_t       (*p_ccnt)(void *);
typedef void        *(*p_cls)(void *, size_t);
typedef const char  *(*p_cname)(void *);
typedef const char  *(*p_cns)(void *);
typedef void        *(*p_meth)(void *, const char *, int);
typedef void        *(*p_attach)(void *);
typedef void        *(*p_invoke)(void *, void *, void **, void **);
typedef void        *(*p_ctype)(void *);
typedef void        *(*p_tobj)(void *);
typedef void        *(*p_ocls)(void *);
typedef void        *(*p_cmeths)(void *, void **);
typedef const char  *(*p_mname)(void *);

static p_domain   i_domain;
static p_asms     i_asms;
static p_img      i_img;
static p_ccnt     i_ccnt;
static p_cls      i_cls;
static p_cname    i_cname;
static p_cns      i_cns;
static p_meth     i_meth;
static p_attach   i_attach;
static p_invoke   i_invoke;
static p_ctype    i_ctype;
static p_tobj     i_tobj;
static p_ocls     i_ocls;
static p_cmeths   i_cmeths;
static p_mname    i_mname;

static void *sym(const char *n) { return dlsym(RTLD_DEFAULT, n); }

static BOOL resolve(void) {
    i_domain = (p_domain)sym("il2cpp_domain_get");
    i_asms   = (p_asms)sym("il2cpp_domain_get_assemblies");
    i_img    = (p_img)sym("il2cpp_assembly_get_image");
    i_ccnt   = (p_ccnt)sym("il2cpp_image_get_class_count");
    i_cls    = (p_cls)sym("il2cpp_image_get_class");
    i_cname  = (p_cname)sym("il2cpp_class_get_name");
    i_cns    = (p_cns)sym("il2cpp_class_get_namespace");
    i_meth   = (p_meth)sym("il2cpp_class_get_method_from_name");
    i_attach = (p_attach)sym("il2cpp_thread_attach");
    i_invoke = (p_invoke)sym("il2cpp_runtime_invoke");
    i_ctype  = (p_ctype)sym("il2cpp_class_get_type");
    i_tobj   = (p_tobj)sym("il2cpp_type_get_object");
    i_ocls   = (p_ocls)sym("il2cpp_object_get_class");   // 可能没有，缺了就用退化路径
    i_cmeths = (p_cmeths)sym("il2cpp_class_get_methods");
    i_mname  = (p_mname)sym("il2cpp_method_get_name");
    return i_domain && i_asms && i_img && i_ccnt && i_cls && i_cname &&
           i_meth && i_attach && i_invoke && i_ctype && i_tobj;
}

// ============================================================
// 日志
// ============================================================
static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap);
    va_end(ap);
    fflush(g_fp);
}

// ============================================================
// 工具
// ============================================================
typedef struct { void *klass; void *monitor; void *bounds; size_t max_length; void *vector[1]; } Il2CppArray;

static void *rdp(void *o, size_t off) {
    if (!o) return NULL;
    return *(void **)((uint8_t *)o + off);
}

// 取对象类名；拿不到 il2cpp_object_get_class 时返回 "?"
static const char *clsname(void *obj) {
    if (!obj) return "null";
    if (!i_ocls || !i_cname) return "?";
    void *k = i_ocls(obj);
    if (!k) return "?";
    const char *n = i_cname(k);
    return n ? n : "?";
}

// 全镜像按名字找类
static void *find_class(const char *name) {
    if (!i_domain || !i_asms) return NULL;
    size_t n = 0;
    void **asms = i_asms(i_domain(), &n);
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        void *img = i_img(asms[i]);
        if (!img) continue;
        size_t cc = i_ccnt(img);
        for (size_t c = 0; c < cc; c++) {
            void *k = i_cls(img, c);
            if (!k) continue;
            const char *nm = i_cname(k);
            if (nm && !strcmp(nm, name)) return k;
        }
    }
    return NULL;
}

// 调一个无参实例/静态方法，返回原始指针
static void *call0(void *obj, void *klass, const char *name, void **outExc) {
    if (!klass || !i_meth || !i_invoke) return NULL;
    void *m = i_meth(klass, name, 0);
    if (!m) { if (outExc) *outExc = (void *)1; return NULL; }
    void *exc = NULL;
    void *ret = i_invoke(m, obj, NULL, &exc);
    if (outExc) *outExc = exc;
    return ret;
}

// ============================================================
// 矩阵
// ============================================================
static BOOL plausible16(const float *f) {
    int zeros = 0;
    for (int i = 0; i < 16; i++) {
        if (!isfinite(f[i])) return NO;
        if (fabsf(f[i]) > 1e6f) return NO;
        if (fabsf(f[i]) < 1e-12f) zeros++;
    }
    return zeros <= 12;
}

// 列主序 4x4 相乘：out = a * b（a、b 都是 col*4+row 布局）
static void mul44(const float *a, const float *b, float *out) {
    for (int c = 0; c < 4; c++)
        for (int r = 0; r < 4; r++) {
            float s = 0;
            for (int k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = s;
        }
}

// VP 投影到屏幕像素
static BOOL proj(const float *vp, float x, float y, float z, float sw, float sh, float *sx, float *sy) {
    float cx = vp[0]*x + vp[4]*y + vp[8]*z  + vp[12];
    float cy = vp[1]*x + vp[5]*y + vp[9]*z  + vp[13];
    float cw = vp[3]*x + vp[7]*y + vp[11]*z + vp[15];
    if (cw < 0.0001f) return NO;
    float nx = cx / cw, ny = cy / cw;
    if (!isfinite(nx) || !isfinite(ny)) return NO;
    if (fabsf(nx) > 50 || fabsf(ny) > 50) return NO;
    *sx = (nx * 0.5f + 0.5f) * sw;
    *sy = (1.0f - (ny * 0.5f + 0.5f)) * sh;
    return YES;
}

static void dump16(const char *tag, const float *f) {
    w("%s [%9.4f %9.4f %9.4f %9.4f]\n", tag, f[0], f[1], f[2], f[3]);
    w("%s [%9.4f %9.4f %9.4f %9.4f]\n", "   ", f[4], f[5], f[6], f[7]);
    w("%s [%9.4f %9.4f %9.4f %9.4f]\n", "   ", f[8], f[9], f[10], f[11]);
    w("%s [%9.4f %9.4f %9.4f %9.4f]\n", "   ", f[12], f[13], f[14], f[15]);
}

// ============================================================
// 状态
// ============================================================
static void *g_cls_pc = NULL;
static void *g_cls_cam = NULL;
static void *g_find = NULL;
static CGFloat g_sw = 0, g_sh = 0;
static int g_frame = 0;
static BOOL g_done = NO;

static void *get_players(void) {
    if (!g_find || !g_cls_pc) return NULL;
    void *t = i_ctype(g_cls_pc);
    void *type = t ? i_tobj(t) : NULL;
    if (!type) return NULL;
    void *params[1] = { type };
    void *exc = NULL;
    void *ret = i_invoke(g_find, NULL, params, &exc);
    if (exc || !ret) return NULL;
    return ret;
}

// ============================================================
// 诊断主体
// ============================================================
static void probe(void) {
    w("\n================ PROBE v13 ================\n");

    // ---------- 1. 偏移表校验 ----------
    void *arr = get_players();
    if (!arr) { w("[致命] FindObjectsOfType 返回空\n"); return; }
    Il2CppArray *a = (Il2CppArray *)arr;
    size_t len = a->max_length;
    w("[玩家数组] len=%zu\n", len);
    if (len == 0) { w("[致命] 场景里没有 PlayerController（是不是还在菜单）\n"); return; }

    static const size_t offs[] = { 0x30, 0x40, 0x60, 0x78, 0x80, 0x90, 0xa0, 0xa8 };
    w("\n[类名校验]\n");
    for (size_t i = 0; i < len && i < 4; i++) {
        void *pc = a->vector[i];
        w(" pc[%zu]=%p\n", i, pc);
        for (unsigned k = 0; k < sizeof(offs)/sizeof(offs[0]); k++) {
            void *p = rdp(pc, offs[k]);
            w("   +0x%02zx = %-14p -> %s\n", offs[k], p, clsname(p));
        }
    }

    // ---------- 2. 位置窗口 ----------
    w("\n[位置窗口] PlayerMovement 附近原始 float\n");
    for (size_t i = 0; i < len && i < 3; i++) {
        void *pc = a->vector[i];
        void *mv = rdp(pc, 0x40);
        if (!mv) { w(" pc[%zu] mv=NULL\n", i); continue; }
        w(" pc[%zu] mv=%p\n", i, mv);
        for (size_t off = 0x250; off <= 0x290; off += 16) {
            float v[4];
            memcpy(v, (uint8_t *)mv + off, 16);
            w("   0x%03zx: %12.4f %12.4f %12.4f %12.4f\n", off, v[0], v[1], v[2], v[3]);
        }
        float p3[3];
        memcpy(p3, (uint8_t *)mv + 0x268, 12);
        w("   >> 0x268 三连 = (%.4f, %.4f, %.4f)\n", p3[0], p3[1], p3[2]);
    }

    // ---------- 3. 相机 ----------
    w("\n[相机]\n");
    void *camObj = NULL;
    if (g_cls_cam) {
        void *exc = NULL;
        camObj = call0(NULL, g_cls_cam, "get_main", &exc);
        w(" Camera.get_main -> %p (exc=%p) class=%s\n", camObj, exc, clsname(camObj));

        // 枚举 Camera 上跟矩阵/投影有关的方法，确认名字存在
        if (i_cmeths && i_mname) {
            void *it = NULL;
            int shown = 0;
            void *m;
            while ((m = i_cmeths(g_cls_cam, &it)) != NULL && shown < 40) {
                const char *nm = i_mname(m);
                if (nm && (strstr(nm, "world") || strstr(nm, "World") ||
                           strstr(nm, "projection") || strstr(nm, "Projection") ||
                           strstr(nm, "pixel") || strstr(nm, "Pixel"))) {
                    w("   method %s\n", nm);
                    shown++;
                }
            }
        }
    } else {
        w(" 找不到 UnityEngine.Camera 类\n");
    }
    if (!camObj) camObj = rdp(a->vector[0], 0x30);   // 退回到 PC+0x30
    w(" 使用相机对象 = %p class=%s\n", camObj, clsname(camObj));

    float rawV[16] = {0}, rawP[16] = {0};
    BOOL gotV = NO, gotP = NO;

    if (camObj && i_ocls) {
        void *camKlass = i_ocls(camObj);
        w(" camKlass=%p name=%s\n", camKlass, clsname(camObj));

        // 值类型返回值：il2cpp 可能返回装箱指针（头 16 字节），也可能返回裸数据。
        // 两种解释都打出来，由下一版决定。
        void *exc = NULL;
        void *rv = call0(camObj, camKlass, "get_worldToCameraMatrix", &exc);
        if (rv) {
            float hdr[4]; memcpy(hdr, rv, 16);
            w(" get_worldToCameraMatrix -> %p (exc=%p)\n", rv, exc);
            w("   头4个float: %.4f %.4f %.4f %.4f %s\n", hdr[0], hdr[1], hdr[2], hdr[3],
              plausible16((float *)rv) ? "(裸数据像矩阵)" : "");
            if (plausible16((float *)rv)) { memcpy(rawV, rv, 64); gotV = YES; dump16("   V@ret ", rawV); }
            if (plausible16((float *)((uint8_t *)rv + 16))) {
                memcpy(rawV, (uint8_t *)rv + 16, 64); gotV = YES;
                dump16("   V@ret+16", rawV);
            }
        } else w(" get_worldToCameraMatrix 调用失败\n");

        exc = NULL;
        void *rp = call0(camObj, camKlass, "get_projectionMatrix", &exc);
        if (rp) {
            w(" get_projectionMatrix -> %p (exc=%p)\n", rp, exc);
            if (plausible16((float *)rp)) { memcpy(rawP, rp, 64); gotP = YES; dump16("   P@ret ", rawP); }
            if (plausible16((float *)((uint8_t *)rp + 16))) {
                memcpy(rawP, (uint8_t *)rp + 16, 64); gotP = YES;
                dump16("   P@ret+16", rawP);
            }
        } else w(" get_projectionMatrix 调用失败\n");
    }

    // ---------- 4. 投影命中 ----------
    w("\n[投影命中] 用 VP 把玩家坐标投到屏幕，落在屏幕附近的比例\n");
    if (gotV && gotP) {
        float vp[16];
        mul44(rawP, rawV, vp);       // 列主序：clip = P * V * p
        dump16("   VP     ", vp);
        int hit = 0, tot = 0;
        for (size_t i = 0; i < len; i++) {
            void *pc = a->vector[i];
            void *mv = rdp(pc, 0x40);
            if (!mv) continue;
            float p3[3]; memcpy(p3, (uint8_t *)mv + 0x268, 12);
            if (p3[0] == 0 && p3[1] == 0 && p3[2] == 0) continue;
            tot++;
            float sx, sy;
            if (!proj(vp, p3[0], p3[1], p3[2], (float)g_sw, (float)g_sh, &sx, &sy)) continue;
            BOOL in = (sx > -g_sw*0.5f && sx < g_sw*1.5f && sy > -g_sh*0.5f && sy < g_sh*1.5f);
            w("   pc[%zu] (%.2f,%.2f,%.2f) -> (%.1f, %.1f) %s\n",
              i, p3[0], p3[1], p3[2], sx, sy, in ? "IN" : "out");
            if (in) hit++;
        }
        w("   >> 命中 %d/%d\n", hit, tot);
    } else {
        w("   矩阵没拿到，无法投影（这是下一步要修的）\n");
    }

    w("================ PROBE END ================\n");
    g_done = YES;
}

// ============================================================
// 循环 / 窗口
// ============================================================
@interface ProbeView : UIView @end
@implementation ProbeView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@interface ProbeWin : UIWindow @end
@implementation ProbeWin
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { return nil; }
@end

@interface ProbeDrv : NSObject
- (void)onTick:(CADisplayLink *)link;
@end

static ProbeWin *g_win = nil;
static ProbeView *g_view = nil;
static CADisplayLink *g_link = nil;
static ProbeDrv *g_drv = nil;

@implementation ProbeDrv
- (void)onTick:(CADisplayLink *)l {
    @autoreleasepool {
        g_frame++;
        if (g_done) return;
        // 60 帧左右跑一次，给场景加载留时间
        if (g_frame < 60 || (g_frame % 60) != 0) return;
        if (g_frame > 600) { [g_link invalidate]; return; }   // 最多等 10 秒，还没玩家就放弃
        probe();
        if (g_done) [g_link invalidate];
    }
}
@end

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
    if (!resolve()) { w("resolve 失败\n"); return; }
    if (i_attach) i_attach(i_domain());

    g_cls_pc = find_class("PlayerController");
    w("cls PlayerController = %p\n", g_cls_pc);
    g_cls_cam = find_class("Camera");
    w("cls Camera = %p\n", g_cls_cam);
    if (!g_cls_pc) return;

    // 找 Component.FindObjectsOfType
    size_t n = 0;
    void **asms = i_asms(i_domain(), &n);
    for (size_t i = 0; i < n && !g_find; i++) {
        if (!asms[i]) continue;
        void *img = i_img(asms[i]);
        if (!img) continue;
        size_t cc = i_ccnt(img);
        for (size_t c = 0; c < cc && !g_find; c++) {
            void *k = i_cls(img, c);
            if (!k) continue;
            const char *nm = i_cname(k);
            if (nm && !strcmp(nm, "Component")) g_find = i_meth(k, "FindObjectsOfType", 1);
        }
    }
    w("FindObjectsOfType = %p\n", g_find);
    if (!g_find) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = find_window();
        if (!host) { w("没有窗口\n"); return; }
        g_sw = host.bounds.size.width;
        g_sh = host.bounds.size.height;
        w("屏幕 %.0fx%.0f\n", g_sw, g_sh);

        UIWindowScene *ws = host.windowScene;
        g_win = ws ? [[ProbeWin alloc] initWithWindowScene:ws]
                   : [[ProbeWin alloc] initWithFrame:host.bounds];
        g_win.frame = host.bounds;
        g_win.windowLevel = UIWindowLevelAlert + 900;
        g_win.backgroundColor = [UIColor clearColor];
        g_win.rootViewController = [[UIViewController alloc] init];
        g_win.rootViewController.view.backgroundColor = [UIColor clearColor];
        g_win.rootViewController.view.userInteractionEnabled = NO;
        g_view = [[ProbeView alloc] initWithFrame:g_win.bounds];
        g_view.userInteractionEnabled = NO;
        [g_win.rootViewController.view addSubview:g_view];
        g_win.hidden = NO;

        g_drv = [[ProbeDrv alloc] init];
        g_link = [CADisplayLink displayLinkWithTarget:g_drv selector:@selector(onTick:)];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [g_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        w("启动\n");
    });
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_probe3.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("v13 probe loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool { boot(); }
    });
}
