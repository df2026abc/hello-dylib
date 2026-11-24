// cf_esp.mm — CounterFlame 透视方框 v5
//
// 修正：
//   - tick 只在主线程跑，不跨线程碰 UIKit
//   - WorldToScreenPoint 参数按 IL2CPP 要求传（指向 Vector3 的指针）
//   - 每帧不重设 needsDisplay 以外的 UI 操作
//   - 对象扫描降频，避免每帧 FindObjectsOfType
//
// 偏移（实测）：
//   PlayerController._mainCamera        0x30
//   PlayerController._movementController 0x40
//   PlayerController._isDeath           0xa8
//   PlayerMovement._currSimPosition     0x268
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
typedef void*  (*p_class_get_fields)(void*, void**);
typedef const char* (*p_field_get_name)(void*);
typedef size_t (*p_field_get_offset)(void*);

static p_domain_get f_domain; static p_domain_get_assemblies f_asm;
static p_assembly_get_image f_img; static p_image_get_class_count f_cnt;
static p_image_get_class f_cls; static p_class_get_name f_cname;
static p_class_get_namespace f_ns; static p_class_get_method_from_name f_method;
static p_runtime_invoke f_invoke; static p_thread_attach f_attach;
static p_object_unbox f_unbox; static p_class_get_type f_get_type;
static p_type_get_object f_type_obj;
static p_class_get_fields f_fields; static p_field_get_name f_fname;
static p_field_get_offset f_foff;

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
    f_fields=(p_class_get_fields)sym("il2cpp_class_get_fields");
    f_fname=(p_field_get_name)sym("il2cpp_field_get_name");
    f_foff=(p_field_get_offset)sym("il2cpp_field_get_offset");
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

// WorldToScreenPoint：Vector3 按值传，IL2CPP 需要指向结构体的指针
static BOOL world_to_screen(void *camera, V3 world, V3 *out) {
    if (!camera || !cls_cam) return NO;
    void *m = f_method(cls_cam, "WorldToScreenPoint", 1);
    if (!m) return NO;

    // 对齐的 16 字节缓冲，避免未对齐访问
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

static CfEspView *g_view = nil;
static CGFloat g_sw = 0, g_sh = 0;

// 只在主线程调用
static void draw_once(void) {
    if (!g_view) return;

    Il2CppArray *arr = NULL;
    void *m = f_method(cls_obj, "FindObjectsOfType", 1);
    if (m && cls_pc) {
        void *t = f_get_type(cls_pc);
        if (t) {
            void *type = f_type_obj(t);
            if (type) {
                void *params[1] = { type };
                void *exc = NULL;
                void *ret = f_invoke(m, NULL, params, &exc);
                if (!exc) arr = (Il2CppArray*)ret;
            }
        }
    }
    if (!arr) return;

    NSMutableArray *rects = [NSMutableArray array];
    size_t len = arr->max_length;

    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;  // 死亡跳过

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

        // Unity 屏幕原点左下 -> UIKit 左上
        CGFloat yHead = g_sh - sH.y;
        CGFloat yFoot = g_sh - sF.y;
        CGFloat h = fabs(yFoot - yHead);
        if (h < 4 || h > g_sh) continue;
        CGFloat wpx = h * 0.45f;

        CGRect r = CGRectMake(sH.x - wpx * 0.5f, yHead, wpx, h);
        [rects addObject:[NSValue valueWithCGRect:r]];
    }

    g_view.rects = rects;
    [g_view setNeedsDisplay];
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
        UIWindow *win = nil;
        for (UIWindow *x in [UIApplication sharedApplication].windows) {
            if (x.isKeyWindow) { win = x; break; }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        if (!win) { w("没有 window\n"); return; }

        g_sw = win.bounds.size.width;
        g_sh = win.bounds.size.height;

        g_view = [[CfEspView alloc] initWithFrame:win.bounds];
        g_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [win addSubview:g_view];
        [win bringSubviewToFront:g_view];
        w("视图挂载 %.0fx%.0f\n", g_sw, g_sh);
    });

    // 定时器建在主线程，回调也在主线程
    __block dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC, 8 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool { draw_once(); }
    });
    dispatch_resume(timer);
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
