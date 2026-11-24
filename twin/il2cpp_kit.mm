// language: Objective-C++, file: twin/il2cpp_kit.mm, target: iOS 15+, arm64
// *the whole symbol table hangs off dlsym; if the game froze the runtime, every
//  pointer here is NULL and the caller bails instead of jumping into garbage.*
#import "il2cpp_kit.h"
#import <objc/runtime.h>
#import <os/lock.h>

Il2Kit g_kit = {0};
Il2CppDomain *g_domain = NULL;

static struct { const char *name; void **slot; } kSymbols[] = {
    {"il2cpp_domain_get",                        (void **)&g_kit.domain_get},
    {"il2cpp_domain_get_assemblies",             (void **)&g_kit.domain_get_assemblies},
    {"il2cpp_assembly_get_image",                (void **)&g_kit.assembly_get_image},
    {"il2cpp_image_get_class_count",             (void **)&g_kit.image_get_class_count},
    {"il2cpp_image_get_class",                   (void **)&g_kit.image_get_class},
    {"il2cpp_class_get_name",                    (void **)&g_kit.class_get_name},
    {"il2cpp_class_get_namespace",               (void **)&g_kit.class_get_namespace},
    {"il2cpp_class_get_method_from_name",        (void **)&g_kit.class_get_method_from_name},
    {"il2cpp_thread_attach",                     (void **)&g_kit.thread_attach},
    {"il2cpp_runtime_invoke",                    (void **)&g_kit.runtime_invoke},
    {"il2cpp_class_get_type",                    (void **)&g_kit.class_get_type},
    {"il2cpp_type_get_object",                   (void **)&g_kit.type_get_object},
    {"il2cpp_class_get_fields",                  (void **)&g_kit.class_get_fields},
    {"il2cpp_field_get_offset",                  (void **)&g_kit.field_get_offset},
    {"il2cpp_field_get_name",                    (void **)&g_kit.field_get_name},
    {"il2cpp_object_new",                        (void **)&g_kit.object_new},
    {"il2cpp_method_get_name",                   (void **)&g_kit.method_get_name},
};

int kit_resolve(void) {
    int found = 0;
    for (size_t i = 0; i < sizeof(kSymbols) / sizeof(kSymbols[0]); i++) {
        void *sym = dlsym(RTLD_DEFAULT, kSymbols[i].name);
        *kSymbols[i].slot = sym;
        if (sym) found++;
    }
    if (g_kit.domain_get) {
        g_domain = g_kit.domain_get();
        if (g_domain && g_kit.thread_attach) g_kit.thread_attach(g_domain);
    }
    return found;
}

Il2CppClass *kit_find_class(const char *simple_name) {
    if (!g_domain) return NULL;
    size_t n = 0;
    const Il2CppAssembly **asms = g_kit.domain_get_assemblies(g_domain, &n);
    if (!asms) return NULL;
    // linear walk over every image; engines ship a few hundred assemblies, this is cheap once per frame
    for (size_t a = 0; a < n; a++) {
        Il2CppImage *img = g_kit.assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = g_kit.image_get_class_count(img);
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = g_kit.image_get_class(img, c);
            if (!k) continue;
            const char *cn = g_kit.class_get_name(k);
            if (cn && strcmp(cn, simple_name) == 0) return k;
        }
    }
    return NULL;
}

Il2CppMethod *kit_method(Il2CppClass *klass, const char *name, int argc) {
    if (!klass) return NULL;
    // -1 means "first overload with this name whatever the arity"
    if (argc >= 0) return g_kit.class_get_method_from_name(klass, name, argc);
    for (int i = 0; i < 8; i++) {
        Il2CppMethod *m = g_kit.class_get_method_from_name(klass, name, i);
        if (m) return m;
    }
    return NULL;
}

Il2CppObject *kit_invoke(Il2CppMethod *m, void *self, void **args) {
    if (!m || !g_kit.runtime_invoke) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *r = g_kit.runtime_invoke(m, self, args, &exc);
    return r; // exceptions swallowed: a throwing getter still returns NULL, caller guards
}

void *kit_arr_at(Il2CppArray *arr, size_t i) {
    if (!arr || i >= arr->bounds.length) return NULL;
    void **v = (void **)arr->vector;
    return v[i];
}

NSString *kit_dump_classes(const char *filter, BOOL with_fields) {
    NSMutableString *out = [NSMutableString string];
    if (!g_domain) return out;
    size_t n = 0;
    const Il2CppAssembly **asms = g_kit.domain_get_assemblies(g_domain, &n);
    for (size_t a = 0; a < n; a++) {
        Il2CppImage *img = g_kit.assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = g_kit.image_get_class_count(img);
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass *k = g_kit.image_get_class(img, c);
            const char *cn = g_kit.class_get_name(k);
            if (!cn) continue;
            if (filter && strstr(cn, filter) == NULL) continue;
            const char *ns = g_kit.class_get_namespace(k);
            [out appendFormat:@"%s.%s\n", ns ? ns : "", cn];
            if (!with_fields) continue;
            void *iter = NULL, *f = NULL;
            while ((f = g_kit.class_get_fields(k, &iter)) != NULL) {
                const char *fn = g_kit.field_get_name(f);
                size_t off = g_kit.field_get_offset(f);
                if (fn) [out appendFormat:@"  FIELD %-30s +0x%zx\n", fn, off];
            }
        }
    }
    return out;
}
