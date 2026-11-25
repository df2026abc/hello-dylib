// cf_probe2.mm — 扫描相机对象，定位矩阵和关键字段
//
// 目的：不靠 metadata，直接在内存里找 Camera 的矩阵
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit \
//     -install_name @executable_path/cf_probe2.dylib \
//     cf_probe2.mm -o cf_probe2.dylib
//
// 输出：App沙盒 Documents/cf_probe2.txt

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
static p_thread_attach f_attach; static p_class_get_type f_get_type;
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

// 判断 64 字节窗口是不是一个像样的矩阵
static BOOL looks_like_matrix(const float *f, int *kind) {
    float mn = 1e9f, mx = -1e9f;
    int zeroCount = 0;
    for (int i = 0; i < 16; i++) {
        if (!isfinite(f[i])) return NO;
        if (f[i] == 0.0f) zeroCount++;
        if (f[i] < mn) mn = f[i];
        if (f[i] > mx) mx = f[i];
    }
    // 太大太小都不像
    if (mx > 1e5f || mn < -1e5f) return NO;
    if (zeroCount < 2) return NO;          // 矩阵一般有若干 0
    if (zeroCount > 13) return NO;         // 全 0 也不行

    // 投影矩阵特征：m[11] (第 3 行第 4 列) == -1，m[15] == 0
    if (fabsf(f[11] + 1.0f) < 0.001f && fabsf(f[15]) < 0.001f) { *kind = 1; return YES; }
    // 相机矩阵特征：右下角 m[15] == 1
    if (fabsf(f[15] - 1.0f) < 0.001f) { *kind = 2; return YES; }
    return NO;
}

static void probe_camera(void *cam) {
    if (!cam) { w("没有相机\n"); return; }

    w("\n===== 扫描相机对象 %p =====\n", cam);

    // 先看看前 0x40 字节，识别是不是真的有 klass 指针
    w("前 16 个指针:\n");
    for (int i = 0; i < 16; i++) {
        void *p = *(void**)((uint8_t*)cam + i*8);
        w("  +0x%02x = %p\n", i*8, p);
    }

    w("\n扫描矩阵 (0x20 ~ 0x800):\n");
    int found = 0;
    for (size_t off = 0x20; off < 0x800; off += 4) {
        const float *f = (const float *)((uint8_t*)cam + off);
        int kind = 0;
        if (!looks_like_matrix(f, &kind)) continue;
        w("  候选 @0x%zx kind=%s\n", off, kind==1 ? "投影矩阵" : "相机矩阵");
        for (int r = 0; r < 4; r++) {
            w("    [%.3f %.3f %.3f %.3f]\n",
              f[r*4], f[r*4+1], f[r*4+2], f[r*4+3]);
        }
        found++;
        if (found > 6) break;
    }
    if (!found) w("  没找到候选矩阵\n");
}

// ============================================================
__attribute__((constructor))
static void init(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *p = [paths.firstObject stringByAppendingPathComponent:@"cf_probe2.txt"];
    g_fp = fopen(p.UTF8String, "w");
    w("probe2 loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!resolve()) { w("resolve fail\n"); return; }
            f_attach(f_domain());

            void *cls_pc  = find_class("PlayerController");
            void *cls_obj = find_class("Object");
            void *cls_cam = find_class("Camera");
            w("cls_pc=%p cls_obj=%p cls_cam=%p\n", cls_pc, cls_obj, cls_cam);
            if (!cls_pc || !cls_obj) return;

            // 拿所有 PlayerController
            void *m = f_method(cls_obj, "FindObjectsOfType", 1);
            void *t = f_get_type(cls_pc);
            void *type = t ? f_type_obj(t) : NULL;
            if (!m || !type) { w("无法调用 FindObjectsOfType\n"); return; }

            void *params[1] = { type };
            void *exc = NULL;
            void *ret = f_invoke(m, NULL, params, &exc);
            if (exc || !ret) { w("invoke 失败\n"); return; }

            Il2CppArray *arr = (Il2CppArray*)ret;
            size_t len = arr->max_length;
            w("PlayerController 实例数: %zu\n", len);

            // 扫第一个有相机的对象
            for (size_t i = 0; i < len; i++) {
                void *pc = arr->vector[i];
                if (!pc) continue;
                void *cam = *(void**)((uint8_t*)pc + 0x30);
                if (!cam) continue;
                w("\n使用 [%zu] 的相机\n", i);
                probe_camera(cam);
                break;
            }
            w("\n===== END =====\n");
        }
    });
}
