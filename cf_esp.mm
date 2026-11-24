// cf_esp.mm — CounterFlame (CS2手游) 透视探测 + 悬浮窗
//
// 这个版本只做探测，不画框。
// 目的：一次跑完，拿到坐标/相机/玩家列表的实际数据，确认能用再画框。
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit -framework QuartzCore \
//     -install_name @executable_path/cf_esp.dylib \
//     cf_esp.mm -o cf_esp.dylib
//
// 输出：App沙盒 Documents/cf_esp.txt

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
typedef size_t (*p_field_get_offset)(void*);
typedef void*  (*p_class_get_fields)(void*, void**);
typedef const char* (*p_field_get_name)(void*);
typedef void*  (*p_object_unbox)(void*);
typedef void*  (*p_gchandle_get_target)(uint32_t);
typedef uint32_t (*p_gchandle_new)(void*, int);

static p_domain_get            f_domain;
static p_domain_get_assemblies f_asm;
static p_assembly_get_image    f_img;
static p_image_get_class_count f_cnt;
static p_image_get_class       f_cls;
static p_class_get_name        f_cname;
static p_class_get_namespace   f_ns;
static p_class_get_method_from_name f_method;
static p_runtime_invoke        f_invoke;
static p_thread_attach         f_attach;
static p_field_get_offset      f_foff;
static p_class_get_fields      f_fields;
static p_field_get_name        f_fname;
static p_object_unbox          f_unbox;
static p_gchandle_get_target   f_gch_target;
static p_gchandle_new          f_gch_new;

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    return p ? p : dlsym(RTLD_NEXT, n);
}

static BOOL resolve(void) {
    f_domain  = (p_domain_get)sym("il2cpp_domain_get");
    f_asm     = (p_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    f_img     = (p_assembly_get_image)sym("il2cpp_assembly_get_image");
    f_cnt     = (p_image_get_class_count)sym("il2cpp_image_get_class_count");
    f_cls     = (p_image_get_class)sym("il2cpp_image_get_class");
    f_cname   = (p_class_get_name)sym("il2cpp_class_get_name");
    f_ns      = (p_class_get_namespace)sym("il2cpp_class_get_namespace");
    f_method  = (p_class_get_method_from_name)sym("il2cpp_class_get_method_from_name");
    f_invoke  = (p_runtime_invoke)sym("il2cpp_runtime_invoke");
    f_attach  = (p_thread_attach)sym("il2cpp_thread_attach");
    f_foff    = (p_field_get_offset)sym("il2cpp_field_get_offset");
    f_fields  = (p_class_get_fields)sym("il2cpp_class_get_fields");
    f_fname   = (p_field_get_name)sym("il2cpp_field_get_name");
    f_unbox   = (p_object_unbox)sym("il2cpp_object_unbox");
    f_gch_target = (p_gchandle_get_target)sym("il2cpp_gchandle_get_target");
    f_gch_new    = (p_gchandle_new)sym("il2cpp_gchandle_new");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_foff;
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

static void open_log(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject;
    NSString *p = [dir stringByAppendingPathComponent:@"cf_esp.txt"];
    g_fp = fopen(p.UTF8String, "w");
}

// ============================================================
// 已知偏移（实测）
// ============================================================
static const uint32_t OFF_PC_MAIN_CAMERA  = 0x30;
static const uint32_t OFF_PC_MOVEMENT     = 0x40;
static const uint32_t OFF_PC_VIEW         = 0x80;
static const uint32_t OFF_PC_PLAYER       = 0x90;
static const uint32_t OFF_PC_IS_DEATH     = 0xa8;

static const uint32_t OFF_PM_CAM_TRANSFORM = 0x30;
static const uint32_t OFF_PM_SELF_ROOT     = 0x188;
static const uint32_t OFF_PM_CURR_SIM_POS  = 0x268;

static const uint32_t OFF_SK_HEAD_BONE     = 0xc0;
static const uint32_t OFF_SK_CHEST_BONE    = 0xc8;

// ============================================================
// 类
// ============================================================
static void *cls_pc = NULL;
static void *cls_pm = NULL;
static void *cls_sk = NULL;
static void *cls_cam = NULL;
static void *cls_tf = NULL;

static void *find_class(const char *ns, const char *name) {
    void *dom = f_domain();
    size_t n = 0;
    void **asms = f_asm(dom, &n);
    for (size_t i = 0; i < n; i++) {
        if (!asms[i]) continue;
        void *img = f_img(asms[i]);
        if (!img) continue;
        size_t cc = f_cnt(img);
        for (size_t c = 0; c < cc; c++) {
            void *k = f_cls(img, c);
            if (!k) continue;
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

// ============================================================
// 读内存
// ============================================================
typedef struct { float x, y, z; } V3;

static void *read_ptr(void *obj, uint32_t off) {
    if (!obj) return NULL;
    uint8_t *p = (uint8_t *)obj + off;
    return *(void **)p;
}

static V3 read_v3(void *obj, uint32_t off) {
    V3 v = {0, 0, 0};
    if (!obj) return v;
    uint8_t *p = (uint8_t *)obj + off;
    memcpy(&v, p, sizeof(V3));
    return v;
}

static BOOL read_bool(void *obj, uint32_t off) {
    if (!obj) return NO;
    return *(uint8_t *)((uint8_t *)obj + off) != 0;
}

// ============================================================
// 拿玩家列表：FindObjectsOfType
// ============================================================
// FindObjectsOfType(Type) returns an Il2CppArray of instances
typedef struct { void *klass; void *monitor; struct { size_t length; } bounds; void *vector; } Il2CppArray;
typedef struct { void *m_p0; void *m_p1; } Method;

static void *get_objects_of_type(void *target_klass, int *outCount) {
    *outCount = 0;
    if (!target_klass || !f_method || !f_invoke) return NULL;

    void *obj_klass = find_class("UnityEngine", "Object");
    if (!obj_klass) return NULL;

    void *m = NULL;
    for (int argc = 1; argc <= 2 && !m; argc++)
        m = f_method(obj_klass, "FindObjectsOfType", argc);
    if (!m) return NULL;

    // build the System.Type token for the target class
    void *type_klass = find_class("System", "Type");
    (void)type_klass;

    // il2cpp_class_get_type + il2cpp_type_get_object
    typedef void *(*p_class_get_type)(void *);
    typedef void *(*p_type_get_object)(void *);
    p_class_get_type cgt = (p_class_get_type)sym("il2cpp_class_get_type");
    p_type_get_object tgo = (p_type_get_object)sym("il2cpp_type_get_object");
    if (!cgt || !tgo) return NULL;
    void *t = cgt(target_klass);
    void *typeObj = t ? tgo(t) : NULL;
    if (!typeObj) return NULL;

    void *exc = NULL;
    if (m) {
        int32_t inc = 0;
        void *args2[2] = { typeObj, &inc };
        Il2CppArray *arr = (Il2CppArray *)f_invoke(m, NULL, args2, &exc);
        if (arr && arr->bounds.length) { *outCount = (int)arr->bounds.length; return arr; }
    }
    return NULL;
}

static void *arr_at(Il2CppArray *a, size_t i) {
    if (!a || i >= a->bounds.length) return NULL;
    return ((void **)a->vector)[i];
}

// ============================================================
// 探测
// ============================================================
static void probe(void) {
    w("\n===== PROBE START =====\n");
    w("cls_pc=%p cls_pm=%p cls_sk=%p cls_cam=%p cls_tf=%p\n",
      cls_pc, cls_pm, cls_sk, cls_cam, cls_tf);
    if (!cls_pc) { w("PlayerController 没找到\n"); return; }

    int n = 0;
    void *arr = get_objects_of_type(cls_pc, &n);
    w("PlayerController 实例数: %d\n", n);
    if (!arr) { w("拿不到实例列表\n"); return; }

    for (int i = 0; i < n && i < 20; i++) {
        void *pc = arr_at((Il2CppArray *)arr, i);
        if (!pc) continue;
        void *cam    = read_ptr(pc, OFF_PC_MAIN_CAMERA);
        void *move   = read_ptr(pc, OFF_PC_MOVEMENT);
        void *player = read_ptr(pc, OFF_PC_PLAYER);
        BOOL dead    = read_bool(pc, OFF_PC_IS_DEATH);
        V3 pos = move ? read_v3(move, OFF_PM_CURR_SIM_POS) : (V3){0,0,0};
        void *tf = move ? read_ptr(move, OFF_PM_CAM_TRANSFORM) : NULL;
        w("  [%d] pc=%p cam=%p move=%p player=%p dead=%d\n", i, pc, cam, move, player, dead);
        w("      pos=(%.2f %.2f %.2f)  camTf=%p\n", pos.x, pos.y, pos.z, tf);
    }

    w("\n--- PlayerController 字段 ---\n");
    if (f_fields) {
        void *iter = NULL, *fld = NULL;
        while ((fld = f_fields(cls_pc, &iter)) != NULL) {
            const char *fn = f_fname(fld);
            size_t off = f_foff(fld);
            if (fn) w("  %-36s 0x%zx\n", fn, off);
        }
    }
    w("\n===== PROBE END =====\n");
}

// ============================================================
// 启动
// ============================================================
__attribute__((constructor))
static void init(void) {
    open_log();
    w("dylib loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (g_fp) w("resolve: %s\n", resolve() ? "OK" : "FAIL");

            if (!f_domain) return;
            f_attach(f_domain());

            cls_pc  = find_class(NULL, "PlayerController");
            cls_pm  = find_class(NULL, "PlayerMovement");
            cls_sk  = find_class("ScarletWork.Game", "PlayerSkeleton");
            cls_cam = find_class("UnityEngine", "Camera");
            cls_tf  = find_class("UnityEngine", "Transform");

            probe();
        }
    });
}
