// cf_scan.mm — 只读探测：把相机对象和 PlayerController 的原始数据全打出来
//
// 不改任何内存。只打印，看清楚再动手。
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit \
//     -install_name @executable_path/cf_scan.dylib \
//     cf_scan.mm -o cf_scan.dylib
//
// 日志：App沙盒 Documents/cf_scan.txt

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

static void *g_find = NULL;
static void *g_cls_pc = NULL;

static Il2CppArray *players(void) {
    if (!g_find || !g_cls_pc) return NULL;
    void *t = f_get_type(g_cls_pc);
    void *type = t ? f_type_obj(t) : NULL;
    if (!type) return NULL;
    void *params[1] = { type };
    void *exc = NULL;
    void *ret = f_invoke(g_find, NULL, params, &exc);
    if (exc || !ret) return NULL;
    return (Il2CppArray*)ret;
}

// 判断 64 字节是否像矩阵
static BOOL is_mat(const float *f) {
    int zeros = 0;
    for (int i = 0; i < 16; i++) {
        if (!isfinite(f[i])) return NO;
        if (fabsf(f[i]) > 1e5f) return NO;
        if (f[i] == 0.0f) zeros++;
    }
    return (zeros >= 2 && zeros <= 13);
}

static void scan_all(void) {
    Il2CppArray *arr = players();
    if (!arr) { w("拿不到玩家\n"); return; }
    size_t len = arr->max_length;
    w("玩家数 %zu\n\n", len);

    // 找第一个活着的玩家
    void *target = NULL;
    for (size_t i = 0; i < len; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        if (*(uint8_t*)((uint8_t*)pc + 0xa8)) continue;
        void *mv = rdp(pc, 0x40);
        if (!mv) continue;
        float px, py, pz;
        memcpy(&px, (uint8_t*)mv + 0x268, 4);
        memcpy(&py, (uint8_t*)mv + 0x26c, 4);
        memcpy(&pz, (uint8_t*)mv + 0x270, 4);
        if (px == 0 && py == 0 && pz == 0) continue;
        target = pc;
        w("选中对象 [%zu] pos=(%.1f, %.1f, %.1f)\n\n", i, px, py, pz);
        break;
    }
    if (!target) { w("没有有效玩家\n"); return; }

    // ---- A. PlayerController 全字段指针 ----
    w("=== A. PlayerController 对象 0x00-0x100 ===\n");
    for (size_t off = 0; off < 0x100; off += 8) {
        void *p = rdp(target, off);
        w("  +0x%02zx = %p\n", off, p);
    }

    // ---- B. 哪个偏移指向 PlayerSkeleton ----
    w("\n=== B. PlayerController 里哪个是 PlayerSkeleton ===\n");
    w("  (看哪个指针后面的对象，偏移 0x182 有个 bool，0x88 有个指针)\n");
    for (size_t off = 0x20; off <= 0xf0; off += 8) {
        void *p = rdp(target, off);
        if (!p) continue;
        uint8_t b182 = *(uint8_t*)((uint8_t*)p + 0x182);
        void *p88 = rdp(p, 0x88);
        float f0;
        memcpy(&f0, (uint8_t*)p + 0x00, 4);
        // skeleton 的特征：0x182 是 0 或 1 的小 bool
        if (b182 <= 1) {
            w("  +0x%02zx -> %p  [0x182]=%d [0x88]=%p [0x0]=%.3f\n",
              off, p, b182, p88, f0);
        }
    }

    // ---- C. 相机对象全扫描，打印所有像矩阵的片段 ----
    void *cam = rdp(target, 0x30);
    w("\n=== C. 相机对象 %p ===\n", cam);
    if (!cam) { w("  相机为空\n"); return; }

    w("  指针区 0x00-0x100:\n");
    for (size_t off = 0; off < 0x100; off += 8) {
        void *p = rdp(cam, off);
        if (p) w("    +0x%02zx = %p\n", off, p);
    }

    w("\n  矩阵候选片段:\n");
    int found = 0;
    for (size_t off = 0x20; off < 0x1000; off += 4) {
        const float *f = (const float*)((uint8_t*)cam + off);
        if (!is_mat(f)) continue;
        w("    @0x%zx\n", off);
        w("      [%8.3f %8.3f %8.3f %8.3f]\n", f[0],  f[1],  f[2],  f[3]);
        w("      [%8.3f %8.3f %8.3f %8.3f]\n", f[4],  f[5],  f[6],  f[7]);
        w("      [%8.3f %8.3f %8.3f %8.3f]\n", f[8],  f[9],  f[10], f[11]);
        w("      [%8.3f %8.3f %8.3f %8.3f]\n", f[12], f[13], f[14], f[15]);
        found++;
        if (found >= 12) break;
    }
    if (!found) w("    没有候选\n");

    // ---- D. 所有玩家的相机指针是否相同 ----
    w("\n=== D. 各玩家的相机/移动组件 ===\n");
    for (size_t i = 0; i < len && i < 10; i++) {
        void *pc = arr->vector[i];
        if (!pc) continue;
        void *c = rdp(pc, 0x30);
        void *mv = rdp(pc, 0x40);
        uint8_t dead = *(uint8_t*)((uint8_t*)pc + 0xa8);
        float px=0,py=0,pz=0;
        if (mv) {
            memcpy(&px, (uint8_t*)mv + 0x268, 4);
            memcpy(&py, (uint8_t*)mv + 0x26c, 4);
            memcpy(&pz, (uint8_t*)mv + 0x270, 4);
        }
        w("  [%zu] pc=%p dead=%d cam=%p mv=%p pos=(%.1f,%.1f,%.1f)\n",
          i, pc, dead, c, mv, px, py, pz);
    }
}

__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_scan.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("cf_scan loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!resolve()) { w("resolve fail\n"); return; }
            f_attach(f_domain());

            g_cls_pc = find_class("PlayerController");
            w("cls_pc=%p\n", g_cls_pc);
            if (!g_cls_pc) return;

            // 找 FindObjectsOfType
            void *dom = f_domain(); size_t n = 0;
            void **asms = f_asm(dom, &n);
            for (size_t i = 0; i < n && !g_find; i++) {
                if (!asms[i]) continue;
                void *img = f_img(asms[i]); if (!img) continue;
                size_t cc = f_cnt(img);
                for (size_t c = 0; c < cc && !g_find; c++) {
                    void *k = f_cls(img, c); if (!k) continue;
                    const char *nm = f_cname(k);
                    if (!nm) continue;
                    if (strcmp(nm, "Component")) continue;
                    g_find = f_method(k, "FindObjectsOfType", 1);
                    if (g_find) w("FindObjectsOfType @%p (Component)\n", g_find);
                }
            }
            if (!g_find) { w("找不到 FindObjectsOfType\n"); return; }

            scan_all();
            w("\n===== done =====\n");
        }
    });
}
