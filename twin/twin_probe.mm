// language: Objective-C++, file: twin/twin_probe.mm, target: iOS 15+, arm64
// Focused dump: only the classes KAlert actually touches, with every field and
// its real runtime offset, plus how many live instances exist right now.
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
    for (NSString *p in cands)
        if ([[NSFileManager defaultManager] isWritableFileAtPath:[p stringByDeletingLastPathComponent]]) return p;
    return nil;
}

static NSString *count_line(Il2CppClass *k, const char *name, Il2CppMethod *find) {
    if (!k) return [NSString stringWithFormat:@"%s: no class\n", name];
    if (!find) return [NSString stringWithFormat:@"%s: no finder\n", name];
    Il2CppType *ty = g_kit.class_get_type(k);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) return [NSString stringWithFormat:@"%s: no type\n", name];
    int32_t inc = 0;
    void *args[2] = { typeObj, &inc };
    Il2CppArray *arr = (Il2CppArray *)kit_invoke(find, NULL, args);
    return [NSString stringWithFormat:@"%s: %zu live\n", name, arr ? arr->bounds.length : (size_t)0];
}

static NSString *dump_one(const char *name, Il2CppMethod *find) {
    NSMutableString *s = [NSMutableString string];
    Il2CppClass *k = kit_find_class(name);
    if (!k) { [s appendFormat:@"### %s NOT FOUND\n", name]; return s; }
    [s appendFormat:@"### %s\n", name];
    [s appendString:count_line(k, name, find)];
    void *iter = NULL, *f = NULL;
    int n = 0;
    while ((f = g_kit.class_get_fields(k, &iter)) != NULL && n < 400) {
        const char *fn = g_kit.field_get_name(f);
        size_t off = g_kit.field_get_offset(f);
        if (fn && *fn) [s appendFormat:@"  %s +0x%zx\n", fn, off];
        n++;
    }
    [s appendString:@"\n"];
    return s;
}

void twin_probe_run(void);

void twin_probe_run(void) {
    @autoreleasepool {
        if (!g_domain) kit_resolve();
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"twin probe @ %@\n\n", [NSDate date]];

        if (!g_domain) {
            [out appendString:@"il2cpp: NO DOMAIN\n"];
            g_twin_probe_text = out;
            NSString *p = probe_path();
            if (p) [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }

        Il2CppClass *oc = kit_find_class("Object");
        Il2CppMethod *find = NULL;
        if (oc) for (int a = 1; a <= 2 && !find; a++)
            find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);
        [out appendFormat:@"il2cpp: OK\nFindObjectsOfType: %s\n\n", find ? "OK" : "MISSING"];

        // the classes KAlert actually walks
        const char *chain[] = {
            "PlayerController", "PlayerNetwork", "Player", "PlayerLife",
            "PlayerMovement", "PlayerAnimatorController", "PlayerFPSCamera",
            "PlayerAiming", "Camera", "Transform", "ArmsController", "PhotonView",
        };
        for (int i = 0; i < (int)(sizeof(chain) / sizeof(chain[0])); i++)
            [out appendString:dump_one(chain[i], find)];

        g_twin_probe_text = out;
        NSString *p = probe_path();
        if (p) [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[twin] focused probe written, %lu chars", (unsigned long)out.length);
    }
}

__attribute__((constructor))
static void twin_probe_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
}
