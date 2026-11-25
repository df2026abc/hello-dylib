// cf_color.mm — 人物上色（读+写）
//
// 流程：读当前值 -> 写入新值 -> 再读确认
//
// 关键偏移（实测）：
//   PlayerController.skeleton       0x78   (字段名 skeleton)
//   PlayerController._isDeath       0xa8
//   PlayerSkeleton.GhostAlpha       0x0    (float)
//   PlayerSkeleton.TintId           0x0    (int, 与 GhostAlpha 重叠，二选一)
//   PlayerSkeleton.SrcBlendId       0x4
//   PlayerSkeleton.DstBlendId       0x8
//   PlayerSkeleton._ghost           0x182  (bool)
//   PlayerSkeleton._ghostBody       0x88
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit \
//     -install_name @executable_path/cf_color.dylib \
//     cf_color.mm -o cf_color.dylib
//
// 日志：App沙盒 Documents/cf_color.txt

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

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

static void *rdp(void *o, size_t off) {
    if (!o) return NULL;
    return *(void**)((uint8_t*)o + off);
}

// ============================================================
// 偏移
// ============================================================
#define OFF_PC_SKELETON   0x78
#define OFF_PC_IS_DEATH   0xa8
#define OFF_SK_GHOSTALPHA 0x00
#define OFF_SK_SRCBLEND   0x04
#define OFF_SK_DSTBLEND   0x08
#define OFF_SK_GHOSTBODY  0x88
#define OFF_SK_GHOST      0x182

static Il2CppArray *g_arr = NULL;
static void *g_cls_obj = NULL;

static Il2CppArray *get_players(void *cls_pc) {
    if (!g_cls_obj || !cls_pc) return NULL;
    void *m = f_method(g_cls_obj, "FindObjectsOfType", 1);
    if (!m) return NULL;
    void *t = f_get_type(cls_pc);
    void *type = t ? f_type_obj(t) : NULL;
    if (!type) return NULL;
    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(m, NULL, params, &exc);
    if (exc || !ret) return NULL;
    return (Il2CppArray*)ret;
}

// 读一遍并打印
static int dump_all(const char *tag, void *cls_pc) {
    Il2CppArray *arr = get_players(cls_pc);
    if (!arr) { w("[%s] 拿不到玩家\n", tag); return 0; }
    size_t len = arr->max_length;
    w("\n[%s] 玩家数 %zu\n", tag, len);

    int skCount = 0;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        void *sk = rdp(pc, OFF_PC_SKELETON);
        if (!sk) { w("  [%zu] skeleton=NULL\n", i); continue; }
        skCount++;

        float ghostAlpha;
        memcpy(&ghostAlpha, (uint8_t*)sk + OFF_SK_GHOSTALPHA, 4);
        int srcBlend, dstBlend;
        memcpy(&srcBlend, (uint8_t*)sk + OFF_SK_SRCBLEND, 4);
        memcpy(&dstBlend, (uint8_t*)sk + OFF_SK_DSTBLEND, 4);
        uint8_t ghost = *(uint8_t*)((uint8_t*)sk + OFF_SK_GHOST);
        uint8_t dead  = *(uint8_t*)((uint8_t*)pc + OFF_PC_IS_DEATH);
        void *gb = rdp(sk, OFF_SK_GHOSTBODY);

        w("  [%zu] sk=%p dead=%d ghost=%d ghostAlpha=%.4f srcBlend=%d dstBlend=%d ghostBody=%p\n",
          i, sk, dead, ghost, ghostAlpha, srcBlend, dstBlend, gb);
    }
    return skCount;
}

// 写一遍
static void apply_all(void *cls_pc) {
    Il2CppArray *arr = get_players(cls_pc);
    if (!arr) { w("[apply] 拿不到玩家\n"); return; }

    int n = 0;
    for (size_t i = 0; i < arr->max_length; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        void *sk = rdp(pc, OFF_PC_SKELETON);
        if (!sk) continue;

        // 开 ghost
        *(uint8_t*)((uint8_t*)sk + OFF_SK_GHOST) = 1;
        // 半透明
        float ga = 0.45f;
        memcpy((uint8_t*)sk + OFF_SK_GHOSTALPHA, &ga, 4);
        // 混合模式（标准 alpha blend）
        int src = 2;  // SrcAlpha 之类，先试
        int dst = 10; // OneMinusSrcAlpha
        memcpy((uint8_t*)sk + OFF_SK_SRCBLEND, &src, 4);
        memcpy((uint8_t*)sk + OFF_SK_DSTBLEND, &dst, 4);
        n++;
    }
    w("\n[apply] 写了 %d 个 skeleton\n", n);
}

// ============================================================
__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_color.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("cf_color loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!resolve()) { w("resolve fail\n"); return; }
            f_attach(f_domain());

            void *cls_pc = find_class("PlayerController");
            g_cls_obj = find_class("Object");
            w("cls_pc=%p cls_obj=%p\n", cls_pc, g_cls_obj);
            if (!cls_pc || !g_cls_obj) return;

            // 1. 改之前读
            dump_all("BEFORE", cls_pc);

            // 2. 写入
            apply_all(cls_pc);

            // 3. 等 2 秒再读，确认
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                dump_all("AFTER", cls_pc);
                w("\n===== done =====\n");
            });
        }
    });
}
