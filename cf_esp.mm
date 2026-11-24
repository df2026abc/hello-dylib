// cf_esp.mm — CounterFlame 探测版 v3
//
// 目的：搞清 5 个 PlayerController 分别是谁、坐标从哪读才准
// 重点：_selfRoot → Transform.position，以及 _currSimPosition 对比
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

static p_domain_get f_domain; static p_domain_get_assemblies f_asm;
static p_assembly_get_image f_img; static p_image_get_class_count f_cnt;
static p_image_get_class f_cls; static p_class_get_name f_cname;
static p_class_get_namespace f_ns; static p_class_get_method_from_name f_method;
static p_runtime_invoke f_invoke; static p_thread_attach f_attach;
static p_field_get_offset f_foff; static p_class_get_fields f_fields;
static p_field_get_name f_fname; static p_object_unbox f_unbox;
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
    f_ns=(p_class_get_namespace)sym("il2cpp_class_get_namespace");
    f_method=(p_class_get_method_from_name)sym("il2cpp_class_get_method_from_name");
    f_invoke=(p_runtime_invoke)sym("il2cpp_runtime_invoke");
    f_attach=(p_thread_attach)sym("il2cpp_thread_attach");
    f_foff=(p_field_get_offset)sym("il2cpp_field_get_offset");
    f_fields=(p_class_get_fields)sym("il2cpp_class_get_fields");
    f_fname=(p_field_get_name)sym("il2cpp_field_get_name");
    f_unbox=(p_object_unbox)sym("il2cpp_object_unbox");
    f_get_type=(p_class_get_type)sym("il2cpp_class_get_type");
    f_type_obj=(p_type_get_object)sym("il2cpp_type_get_object");
    return f_domain && f_asm && f_img && f_cnt && f_cls && f_cname &&
           f_method && f_invoke && f_attach && f_foff && f_fields &&
           f_fname && f_unbox && f_get_type && f_type_obj;
}

static FILE *g_fp = NULL;
static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap); va_end(ap); fflush(g_fp);
}

static void *find_class(const char *ns, const char *name) {
    void *dom = f_domain(); size_t n = 0;
    void **asms = f_asm(dom, &n);
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

static Il2CppArray *find_objects(void *klass, void *cls_obj) {
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

typedef struct { float x, y, z; } V3;
static V3 rd3(void *o, size_t off) {
    V3 v = {0,0,0};
    if (!o) return v;
    memcpy(&v, (uint8_t*)o + off, 12);
    return v;
}
static void *rdp(void *o, size_t off) {
    if (!o) return NULL;
    return *(void**)((uint8_t*)o + off);
}

// Transform.position：先拿 Transform 组件，再调 get_position
static V3 get_transform_pos(void *cls_tf, void *transform) {
    V3 v = {0,0,0};
    if (!transform || !cls_tf) return v;
    void *m = f_method(cls_tf, "get_position", 0);
    if (!m) return v;
    void *exc = NULL;
    void *ret = f_invoke(m, transform, NULL, &exc);
    if (exc || !ret) return v;
    V3 *p = (V3*)f_unbox(ret);
    if (p) v = *p;
    return v;
}

// 从 GameObject 拿 Transform：get_transform
static void *get_transform(void *cls_go, void *go) {
    if (!go || !cls_go) return NULL;
    void *m = f_method(cls_go, "get_transform", 0);
    if (!m) return NULL;
    void *exc = NULL;
    void *ret = f_invoke(m, go, NULL, &exc);
    if (exc) return NULL;
    return ret;
}

static void probe(void) {
    w("\n===== PROBE v3 =====\n");

    void *cls_pc  = find_class(NULL, "PlayerController");
    void *cls_sk  = find_class("ScarletWork.Game", "PlayerSkeleton");
    void *cls_obj = find_class("UnityEngine", "Object");
    void *cls_go  = find_class("UnityEngine", "GameObject");
    void *cls_tf  = find_class("UnityEngine", "Transform");

    w("cls_pc=%p cls_sk=%p cls_obj=%p cls_go=%p cls_tf=%p\n",
      cls_pc, cls_sk, cls_obj, cls_go, cls_tf);

    if (!cls_pc || !cls_obj) return;

    Il2CppArray *arr = find_objects(cls_pc, cls_obj);
    if (!arr) { w("拿不到实例\n"); return; }

    size_t len = arr->max_length;
    w("实例数: %zu\n", len);

    for (size_t i = 0; i < len; i++) {
        void *o = arr->vector[i];
        if (!o) continue;
        w("\n--- [%zu] obj=%p ---\n", i, o);

        uint8_t *b = (uint8_t*)o;
        void *mv   = rdp(o, 0x40);
        void *view = rdp(o, 0x80);
        void *pl   = rdp(o, 0x90);
        uint8_t dead = b[0xa8];
        w("  mv=%p view=%p player=%p dead=%d\n", mv, view, pl, dead);

        if (mv) {
            V3 cur = rd3(mv, 0x268);
            V3 root = rd3(mv, 0x188);
            void *rootObj = rdp(mv, 0x188);
            w("  _currSimPosition(0x268) = (%.2f, %.2f, %.2f)\n", cur.x, cur.y, cur.z);
            w("  _selfRoot raw ptr(0x188) = %p\n", rootObj);

            // _selfRoot 是 Transform，直接调 get_position
            V3 tp = get_transform_pos(cls_tf, rootObj);
            w("  _selfRoot.position     = (%.2f, %.2f, %.2f)\n", tp.x, tp.y, tp.z);

            // 从 view 拿 GameObject，再拿 Transform
            if (view && cls_go) {
                void *tf2 = get_transform(cls_go, view);
                w("  view->transform = %p\n", tf2);
                V3 vp = get_transform_pos(cls_tf, tf2);
                w("  view.position   = (%.2f, %.2f, %.2f)\n", vp.x, vp.y, vp.z);
            }
        }

        // skeleton 检查
        if (cls_sk) {
            void *sk = rdp(o, 0x78); // 不一定对，先看看
            w("  offset0x78=%p\n", sk);
        }
    }
    w("\n===== END =====\n");
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_esp.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("dylib loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!resolve()) { w("resolve FAIL\n"); return; }
            f_attach(f_domain());
            probe();
        }
    });
}
