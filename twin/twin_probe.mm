// language: Objective-C++, file: twin/twin_probe.mm, target: iOS 15+, arm64
// Runtime map builder. Walks every assembly, every class, and reports which
// types actually carry a Vector3 position/transform — that is where players live.
// Output goes to /var/mobile/Documents/twin_probe.txt and the panel footer.
#import "il2cpp_kit.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NSString *g_twin_probe_text = nil;

static NSString *probe_path(void) {
    NSArray<NSString *> *cands = @[
        @"/var/mobile/Documents/twin_probe.txt",
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"twin_probe.txt"],
    ];
    for (NSString *p in cands) {
        if ([[NSFileManager defaultManager] isWritableFileAtPath:[p stringByDeletingLastPathComponent]]) return p;
    }
    return nil;
}

// names that strongly suggest "this object has a world position"
static BOOL looks_like_position(const char *fn) {
    static const char *keys[] = {
        "position", "Position", "pos", "Pos", "location", "Location",
        "transform", "Transform", "_tr", "_xform", "origin", "Origin",
        "worldPos", "localPos", "spawnPoint", "SpawnPoint", "center", "Center",
    };
    if (!fn) return NO;
    for (int i = 0; i < (int)(sizeof(keys) / sizeof(keys[0])); i++)
        if (strstr(fn, keys[i])) return YES;
    return NO;
}

static NSString *scan_all_classes(void) {
    NSMutableString *out = [NSMutableString string];
    if (!g_domain) { [out appendString:@"NO DOMAIN\n"]; return out; }

    size_t n_asm = 0;
    const Il2CppAssembly **asms = g_kit.domain_get_assemblies(g_domain, &n_asm);
    [out appendFormat:@"assemblies: %zu\n", n_asm];

    NSUInteger totalClasses = 0, hits = 0;
    for (size_t a = 0; a < n_asm; a++) {
        Il2CppImage *img = g_kit.assembly_get_image(asms[a]);
        if (!img) continue;
        size_t cc = g_kit.image_get_class_count(img);
        for (size_t c = 0; c < cc && totalClasses < 40000; c++) {
            Il2CppClass *k = g_kit.image_get_class(img, c);
            if (!k) continue;
            const char *cn = g_kit.class_get_name(k);
            if (!cn || !*cn) continue;
            totalClasses++;

            // collect fields whose names read like a world position
            void *iter = NULL, *f = NULL;
            NSMutableString *fields = [NSMutableString string];
            int nf = 0;
            while ((f = g_kit.class_get_fields(k, &iter)) != NULL && nf < 300) {
                const char *fn = g_kit.field_get_name(f);
                if (looks_like_position(fn)) {
                    size_t off = g_kit.field_get_offset(f);
                    [fields appendFormat:@"%@+0x%zx ", [NSString stringWithUTF8String:fn], off];
                }
                nf++;
            }
            if (fields.length) {
                const char *ns = g_kit.class_get_namespace(k);
                [out appendFormat:@"CLASS %s%s%s  fields=%d  [%@]\n",
                                    (ns && *ns) ? ns : "", (ns && *ns) ? "." : "",
                                    cn, nf, fields];
                hits++;
            }
        }
    }
    [out appendFormat:@"\nscanned %lu classes, %lu carry position-like fields\n",
                      (unsigned long)totalClasses, (unsigned long)hits];
    return out;
}

static NSString *summary(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"il2cpp: %s\n", g_domain ? "OK" : "NO DOMAIN"];
    if (!g_domain) return s;

    Il2CppClass *oc = kit_find_class("Object");
    Il2CppMethod *find = NULL;
    if (oc) for (int a = 1; a <= 2 && !find; a++)
        find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);
    [s appendFormat:@"FindObjectsOfType: %s\n", find ? "OK" : "MISSING"];

    const char *cands[] = {"PlayerMovement", "PlayerNetwork", "RemoteBody", "BotController",
                           "PlayerController", "PlayerHull", "ArmsController", "PlayerAiming"};
    for (int i = 0; i < 8; i++) {
        Il2CppClass *k = kit_find_class(cands[i]);
        if (!k) { [s appendFormat:@"%s: no class\n", cands[i]]; continue; }
        if (!find) { [s appendFormat:@"%s: ?\n", cands[i]]; continue; }
        Il2CppType *ty = g_kit.class_get_type(k);
        Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
        if (!typeObj) { [s appendFormat:@"%s: no type\n", cands[i]]; continue; }
        int32_t inc = 0;
        void *args[2] = { typeObj, &inc };
        Il2CppArray *arr = (Il2CppArray *)kit_invoke(find, NULL, args);
        [s appendFormat:@"%s: %zu live\n", cands[i], arr ? arr->bounds.length : 0];
    }
    return s;
}

void twin_probe_run(void);

void twin_probe_run(void) {
    @autoreleasepool {
        if (!g_domain) kit_resolve();
        NSMutableString *all = [NSMutableString string];
        [all appendFormat:@"twin probe @ %@\n\n", [NSDate date]];
        [all appendString:summary()];
        [all appendString:@"\n=== classes with position-like fields ===\n"];
        [all appendString:scan_all_classes()];
        g_twin_probe_text = all;

        NSString *p = probe_path();
        if (p) [all writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[twin] probe done, %lu chars, written to %@", (unsigned long)all.length, p ?: @"(no writable path)");
    }
}

__attribute__((constructor))
static void twin_probe_boot(void) {
    // first pass early, second pass once the match is running
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
}
