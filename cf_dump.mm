// cf_dump.mm — CounterFlame 字段偏移探测
//
// 编译：
//   clang++ -arch arm64 -dynamiclib -fobjc-arc -std=c++17 \
//     -framework Foundation -framework UIKit \
//     -install_name @executable_path/cf_dump.dylib \
//     cf_dump.mm -o cf_dump.dylib
//
// 输出：/var/mobile/Documents/cf_dump.txt

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

typedef void*  (*p_domain_get)(void);
typedef void** (*p_domain_get_assemblies)(void*, size_t*);
typedef void*  (*p_assembly_get_image)(void*);
typedef size_t (*p_image_get_class_count)(void*);
typedef void*  (*p_image_get_class)(void*, size_t);
typedef const char* (*p_class_get_name)(void*);
typedef const char* (*p_class_get_namespace)(void*);
typedef void*  (*p_class_get_fields)(void*, void**);
typedef const char* (*p_field_get_name)(void*);
typedef size_t (*p_field_get_offset)(void*);
typedef void*  (*p_thread_attach)(void*);

static p_domain_get            f_domain = NULL;
static p_domain_get_assemblies f_asm    = NULL;
static p_assembly_get_image    f_img    = NULL;
static p_image_get_class_count f_cnt    = NULL;
static p_image_get_class       f_cls    = NULL;
static p_class_get_name        f_cname  = NULL;
static p_class_get_namespace   f_ns     = NULL;
static p_class_get_fields      f_fields = NULL;
static p_field_get_name        f_fname  = NULL;
static p_field_get_offset      f_foff   = NULL;
static p_thread_attach         f_attach = NULL;

static FILE *g_fp = NULL;

static void w(const char *fmt, ...) {
    if (!g_fp) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(g_fp, fmt, ap);
    va_end(ap);
    fflush(g_fp);
}

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (!p) p = dlsym(RTLD_NEXT, n);
    return p;
}

static BOOL resolve(void) {
    f_domain = (p_domain_get)sym("il2cpp_domain_get");
    f_asm    = (p_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    f_img    = (p_assembly_get_image)sym("il2cpp_assembly_get_image");
    f_cnt    = (p_image_get_class_count)sym("il2cpp_image_get_class_count");
    f_cls    = (p_image_get_class)sym("il2cpp_image_get_class");
    f_cname  = (p_class_get_name)sym("il2cpp_class_get_name");
    f_ns     = (p_class_get_namespace)sym("il2cpp_class_get_namespace");
    f_fields = (p_class_get_fields)sym("il2cpp_class_get_fields");
    f_fname  = (p_field_get_name)sym("il2cpp_field_get_name");
    f_foff   = (p_field_get_offset)sym("il2cpp_field_get_offset");
    f_attach = (p_thread_attach)sym("il2cpp_thread_attach");
    return f_domain && f_asm && f_img && f_cnt && f_cls &&
           f_cname && f_ns && f_fields && f_fname && f_foff && f_attach;
}

static const char *kWant[] = {
    "PlayerController", "PlayerMovement", "PlayerSkeleton",
    "PlayerFPSCamera", "PlayerLife", "PlayerCulling", "ArmsController",
    NULL
};

static void dump(void) {
    void *dom = f_domain();
    if (!dom) { w("domain 为空\n"); return; }
    f_attach(dom);

    size_t asmCount = 0;
    void **asms = f_asm(dom, &asmCount);
    if (!asms || !asmCount) { w("拿不到 assembly 列表\n"); return; }
    w("assemblies: %zu\n", asmCount);

    int found = 0;

    for (size_t a = 0; a < asmCount; a++) {
        if (!asms[a]) continue;
        void *img = f_img(asms[a]);
        if (!img) continue;

        size_t cc = f_cnt(img);
        for (size_t c = 0; c < cc; c++) {
            void *klass = f_cls(img, c);
            if (!klass) continue;

            const char *nm = f_cname(klass);
            if (!nm) continue;

            BOOL hit = NO;
            for (int k = 0; kWant[k]; k++)
                if (strcmp(nm, kWant[k]) == 0) { hit = YES; break; }
            if (!hit) continue;

            const char *ns = f_ns(klass);
            w("\n=== %s%s%s ===\n", (ns && *ns) ? ns : "",
              (ns && *ns) ? "." : "", nm);
            found++;

            void *iter = NULL;
            void *fld = NULL;
            while ((fld = f_fields(klass, &iter)) != NULL) {
                const char *fn = f_fname(fld);
                size_t off = f_foff(fld);
                if (!fn) continue;
                w("  %-40s 0x%zx\n", fn, off);
            }
        }
    }

    if (!found) {
        w("\n没找到目标类，说明 il2cpp 符号拿到了但类名不对。\n");
        w("把下面这段也发回去，用于核对：\n");
        for (size_t a = 0; a < asmCount && a < 5; a++) {
            if (!asms[a]) continue;
            void *img = f_img(asms[a]);
            if (!img) continue;
            size_t cc = f_cnt(img);
            for (size_t c = 0; c < cc && c < 40; c++) {
                void *klass = f_cls(img, c);
                if (!klass) continue;
                const char *nm = f_cname(klass);
                if (nm) w("  dump: %s\n", nm);
            }
        }
    }

    w("\n--- done, found=%d ---\n", found);
}

__attribute__((constructor))
static void init(void) {
    NSString *path = @"/var/mobile/Documents/cf_dump.txt";

    g_fp = fopen(path.UTF8String, "w");
    if (!g_fp) {
        NSString *alt = @"/tmp/cf_dump.txt";
        g_fp = fopen(alt.UTF8String, "w");
        if (!g_fp) {
            NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *p2 = [d stringByAppendingPathComponent:@"cf_dump.txt"];
            g_fp = fopen(p2.UTF8String, "w");
        }
    }
    if (!g_fp) return;

    w("dylib loaded\n");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        @autoreleasepool {
            if (!resolve()) {
                w("il2cpp 符号没找到，dlsym 结果：\n");
                const char *probe[] = {
                    "il2cpp_domain_get", "il2cpp_domain_get_assemblies",
                    "il2cpp_class_get_fields", "il2cpp_field_get_offset",
                    "il2cpp_thread_attach", NULL
                };
                for (int i = 0; probe[i]; i++)
                    w("  %-34s %p\n", probe[i], sym(probe[i]));
                return;
            }
            w("il2cpp 符号全部解析成功\n");
            dump();
        }
    });
}
