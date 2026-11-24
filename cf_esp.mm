// cf_esp.mm — CounterFlame (CS2手游) 探测版 v2
//
// 只探测，不画框。目的：一次跑完确认玩家里程碑。
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
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

// ============================================================
// il2cpp
// ============================================================
typedef struct Il2CppArray {
    void *klass;
    void *monitor;
    void *bounds;
    size_t max_length;
    void *vector[1];
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
typedef size_t (*p_field_get_offset)(void*);
typedef void*  (*p_class_get_fields)(void*, void**);
typedef const char* (*p_field_get_name)(void*);
typedef void*  (*p_object_unbox)(void*);
typedef void*  (*p_class_get_type)(void*);
typedef void*  (*p_type_get_object)(void*);
typedef void*  (*p_array_new)(void*, size_t);
typedef void*  (*p_object_new)(void*);

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
static p_class_get_type        f_get_type;
static p_type_get_object       f_type_obj;
static p_array_new             f_array_new;
static p_object_new            f_obj_new;

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
    f_get_type= (p_class_get_type)sym("il2cpp_class_get_type");
    f_type_obj= (p_type_get_object)sym("il2cpp_type_get_object");
    f_array_new = (p_array_new)sym("il2cpp_array_new");
    f_obj_new   = (p_object_new)sym("il2cpp_object_new");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_foff && f_fields &&
           f_fname && f_unbox && f_get_type && f_type_obj && f_array_new;
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
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_esp.txt"];
    g_fp = fopen(p.UTF8String, "w");
}

// ============================================================
// 类
// ============================================================
static void *cls_pc = NULL;
static void *cls_pm = NULL;
static void *cls_sk = NULL;
static void *cls_cam = NULL;
static void *cls_obj = NULL;
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
// 用 il2cpp_class_get_type + type_get_object 造 typeof(T)
// ============================================================
static void *make_system_type(void *klass) {
    if (!klass || !f_get_type || !f_type_obj) return NULL;
    void *t = f_get_type(klass);
    if (!t) return NULL;
    void *exc = NULL;
    return f_type_obj(t);   // 返回 UnityEngine.Object 的 System.Type 对象
}

// ============================================================
// FindObjectsOfType(Type)
// ============================================================
static Il2CppArray *find_objects_of_type(void *klass) {
    if (!klass || !cls_obj) return NULL;

    void *m = f_method(cls_obj, "FindObjectsOfType", 1);
    if (!m) m = f_method(cls_obj, "FindObjectsOfTypeAll", 1);
    if (!m) { w("  没有 FindObjectsOfType 方法\n"); return NULL; }

    void *type = make_system_type(klass);
    if (!type) { w("  make_system_type 失败\n"); return NULL; }

    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(m, NULL, params, &exc);   // 静态方法，obj 传 NULL
    if (exc) { w("  invoke 抛异常\n"); return NULL; }
    if (!ret) { w("  invoke 返回空\n"); return NULL; }

    return (Il2CppArray *)ret;
}

// ============================================================
// 探测
// ============================================================
static void probe(void) {
    w("\n===== PROBE v2 =====\n");
    w("cls_pc=%p cls_pm=%p cls_sk=%p cls_cam=%p cls_obj=%p cls_tf=%p\n",
      cls_pc, cls_pm, cls_sk, cls_cam, cls_obj, cls_tf);

    if (!cls_pc) { w("PlayerController 没找到\n"); return; }

    // 1) 打印 PlayerController 全部字段
    w("\n--- PlayerController 字段 ---\n");
    void *iter = NULL, *fld = NULL;
    while ((fld = f_fields(cls_pc, &iter)) != NULL) {
        const char *fn = f_fname(fld);
        size_t off = f_foff(fld);
        if (fn) w("  %-36s 0x%zx\n", fn, off);
    }

    // 2) 找实例
    w("\n--- FindObjectsOfType(PlayerController) ---\n");
    Il2CppArray *arr = find_objects_of_type(cls_pc);
    if (!arr) { w("  拿到空\n"); return; }

    size_t len = arr->max_length;
    w("  实例数量: %zu\n", len);
    if (len == 0) { w("  场上没有玩家（可能不在对局里）\n"); return; }

    // 3) 打印前几个对象的字段值
    int show = (int)(len > 8 ? 8 : len);
    for (int i = 0; i < show; i++) {
        void *obj = arr->vector[i];
        if (!obj) continue;
        w("\n  [%d] obj=%p\n", i, obj);

        uint8_t *base = (uint8_t *)obj;
        void *view    = *(void **)(base + 0x80);
        void *player  = *(void **)(base + 0x90);
        void *cam     = *(void **)(base + 0x30);
        uint8_t dead  = *(uint8_t *)(base + 0xa8);

        w("    _view=%p  _player=%p  _mainCamera=%p  _isDeath=%d\n",
          view, player, cam, dead);

        // 通过 _movementController 拿坐标
        void *mv = *(void **)(base + 0x40);
        if (mv) {
            float pos[3];
            memcpy(pos, (uint8_t *)mv + 0x268, 12);
            w("    movement=%p  坐标=(%.2f, %.2f, %.2f)\n", mv, pos[0], pos[1], pos[2]);
        }

        // 找 Skeleton
        void *sk = NULL;
        if (cls_sk && mv) {
            // 通过 PlayerCulling / 名字找
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            BOOL ok = resolve();
            w("resolve: %s\n", ok ? "OK" : "FAIL");
            if (!ok) return;

            f_attach(f_domain());

            cls_pc  = find_class(NULL, "PlayerController");
            cls_pm  = find_class(NULL, "PlayerMovement");
            cls_sk  = find_class("ScarletWork.Game", "PlayerSkeleton");
            cls_cam = find_class("UnityEngine", "Camera");
            cls_obj = find_class("UnityEngine", "Object");
            cls_tf  = find_class("UnityEngine", "Transform");

            probe();
        }
    });
}
