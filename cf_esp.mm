// cf_esp.mm — CounterFlame (CS2手游) 透视方框 + 悬浮窗
//
// 坐标实测确认：
//   PlayerController._movementController = 0x40
//   PlayerController._mainCamera         = 0x30
//   PlayerController._isDeath            = 0xa8
//   PlayerController._view               = 0x80
//   PlayerMovement._currSimPosition      = 0x268  (与 _selfRoot.position 一致)
//   PlayerSkeleton._headBone             = 0xc0
//   PlayerSkeleton._chestBone            = 0xc8
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

// ============================================================
// il2cpp
// ============================================================
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

// ============================================================
// 日志
// ============================================================
static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap); va_end(ap); fflush(g_fp);
}

// ============================================================
// 类
// ============================================================
static void *cls_pc = NULL, *cls_cam = NULL, *cls_obj = NULL, *cls_tf = NULL;

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

static void *make_type(void *klass) {
    if (!klass) return NULL;
    void *t = f_get_type(klass); if (!t) return NULL;
    void *exc = NULL;
    return f_type_obj(t);
}

static Il2CppArray *find_objects(void *klass) {
    if (!klass || !cls_obj) return NULL;
    void *m = f_method(cls_obj, "FindObjectsOfType", 1);
    if (!m) return NULL;
    void *type = make_type(klass); if (!type) return NULL;
    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(m, NULL, params, &exc);
    if (exc || !ret) return NULL;
    return (Il2CppArray *)ret;
}

// ============================================================
// 内存读取（全带判空）
// ============================================================
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

// Transform.position
static BOOL transform_pos(void *transform, V3 *out) {
    if (!transform || !cls_tf) return NO;
    void *m = f_method(cls_tf, "get_position", 0);
    if (!m) return NO;
    void *exc = NULL;
    void *ret = f_invoke(m, transform, NULL, &exc);
    if (exc || !ret) return NO;
    V3 *p = (V3*)f_unbox(ret);
    if (!p) return NO;
    *out = *p;
    return YES;
}

// Camera.WorldToScreenPoint(Vector3) -> Vector3
static BOOL world_to_screen(void *camera, V3 world, V3 *out) {
    if (!camera || !cls_cam) return NO;
    void *m = f_method(cls_cam, "WorldToScreenPoint", 1);
    if (!m) return NO;

    // Vector3 按值传：用一块对齐的临时内存 + runtime_invoke
    union { V3 v; uint8_t raw[32]; } arg;
    memset(&arg, 0, sizeof(arg));
    arg.v = world;

    void *params[1] = { &arg };
    void *exc = NULL;
    void *ret = f_invoke(m, camera, params, &exc);
    if (exc || !ret) return NO;

    V3 *p = (V3*)f_unbox(ret);
    if (!p) return NO;
    *out = *p;
    return YES;
}

// ============================================================
// 配置
// ============================================================
static BOOL  g_on = YES;
static float g_boxW = 0.45f;   // 框宽 = 框高 * 这个比例
static float g_headOff = 0.75f; // 头顶偏移（抬多高）

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
        self.opaque = NO;
        _rects = [NSMutableArray array];
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetStrokeColorWithColor(ctx,
        [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:0.9].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    for (NSValue *v in self.rects) {
        CGRect r = [v CGRectValue];
        CGContextStrokeRect(ctx, r);
    }
}
@end

static CfEspView *g_view = nil;

// ============================================================
// 每帧：收集方框
// ============================================================
static void tick(void) {
    if (!g_view) return;
    if (!g_on) {
        g_view.rects = [NSMutableArray array];
        [g_view setNeedsDisplay];
        return;
    }

    Il2CppArray *arr = find_objects(cls_pc);
    static int tickCount = 0;
    if (tickCount < 3) { w("[tick] arr=%p\n", arr); }
    if (!arr) return;

    size_t len = arr->max_length;
    if (tickCount < 3) { w("[tick] 实例数=%zu\n", len); }
    NSMutableArray *rects = [NSMutableArray array];

    // 屏幕尺寸
    CGFloat sw = g_view.bounds.size.width;
    CGFloat sh = g_view.bounds.size.height;
    if (sw <= 0 || sh <= 0) return;

    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;

        uint8_t dead = *(uint8_t*)((uint8_t*)pc + 0xa8);
        void *mv = rdp(pc, 0x40);
        void *cam = rdp(pc, 0x30);
        V3 pos = mv ? rd3(mv, 0x268) : (V3){0,0,0};
        if (tickCount < 3) {
            w("  [%zu] pc=%p dead=%d mv=%p cam=%p pos=(%.2f %.2f %.2f)\n",
              i, pc, dead, mv, cam, pos.x, pos.y, pos.z);
        }
        if (dead) continue;
        if (!mv || !cam) continue;
        if (pos.x == 0 && pos.y == 0 && pos.z == 0) continue;

        // 头顶抬高一点
        V3 head = { pos.x, pos.y + g_headOff, pos.z };
        V3 foot = pos;

        V3 sHead = {0,0,0}, sFoot = {0,0,0};
        BOOL okh = world_to_screen(cam, head, &sHead);
        BOOL okf = world_to_screen(cam, foot, &sFoot);
        if (tickCount < 3) {
            w("      world%s head=(%.1f %.1f %.1f) foot=(%.1f %.1f %.1f)\n",
              (okh && okf) ? " OK" : " FAIL", sHead.x, sHead.y, sHead.z, sFoot.x, sFoot.y, sFoot.z);
        }
        if (!okh || !okf) continue;

        // 屏幕外的跳过
        if (sHead.z < 0 || sFoot.z < 0) continue;

        // Unity 屏幕坐标原点在左下，UIKit 在左上，y 要翻
        CGFloat yHead = sh - sHead.y;
        CGFloat yFoot = sh - sFoot.y;

        CGFloat h = fabs(yFoot - yHead);
        if (h < 4 || h > sh) continue;
        CGFloat wpx = h * g_boxW;

        CGFloat cx = (sh - sHead.x);   // 这里 x 也用屏幕宽换算
        cx = sHead.x;
        CGRect r = CGRectMake(cx - wpx * 0.5f, yHead, wpx, h);
        [rects addObject:[NSValue valueWithCGRect:r]];
    }

    if (tickCount < 3) { w("[tick] 出框数=%lu\n", (unsigned long)rects.count); tickCount++; }
    g_view.rects = rects;
    [g_view setNeedsDisplay];
}

// ============================================================
// 悬浮窗
// ============================================================
static UIWindow *g_panel = nil;

static void attach_panel(void) {
    if (g_panel) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(40, 100, 200, 90)];
    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    w.layer.cornerRadius = 10;
    w.layer.masksToBounds = YES;
    w.hidden = NO;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 120, 22)];
    title.text = @"CF ESP";
    title.textColor = [UIColor colorWithRed:0.2 green:1 blue:0.4 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:15];
    [w addSubview:title];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(130, 6, 51, 31)];
    sw.on = YES;
    [sw addTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
    [w addSubview:sw];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12, 40, 170, 18)];
    hint.text = @"开/关方框";
    hint.textColor = [UIColor lightGrayColor];
    hint.font = [UIFont systemFontOfSize:11];
    [w addSubview:hint];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [w addGestureRecognizer:pan];

    g_panel = w;
    [w makeKeyAndVisible];
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
    cls_tf  = find_class("UnityEngine", "Transform");

    w("classes: pc=%p cam=%p obj=%p tf=%p\n", cls_pc, cls_cam, cls_obj, cls_tf);
    if (!cls_pc || !cls_cam || !cls_obj || !cls_tf) { w("类缺失\n"); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindow *x in [UIApplication sharedApplication].windows) {
            if (x.isKeyWindow) { win = x; break; }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        if (!win) { w("没有 window\n"); return; }

        g_view = [[CfEspView alloc] initWithFrame:win.bounds];
        g_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [win addSubview:g_view];
        [win bringSubviewToFront:g_view];
        w("视图已挂载 %.0fx%.0f\n", win.bounds.size.width, win.bounds.size.height);
    });

    // 每帧刷新
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC, 4 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool { tick(); }
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
