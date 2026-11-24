// language: Objective-C++, file: twin/twin_probe.mm, target: iOS 15+, arm64
// Diagnostic that reports on screen as well as to disk. If the il2cpp symbols
// are missing or the class layout differs, the text shows up directly in the
// panel instead of needing a file pull.
#import "il2cpp_kit.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// latest report text, read by the panel when it opens
NSString *g_twin_probe_text = nil;

static NSString *probe_dir(void) {
    // try the shared container first, fall back to the app's own Documents
    NSArray<NSString *> *cands = @[
        @"/var/mobile/Documents/twin_probe.txt",
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"twin_probe.txt"],
    ];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:dir]) return p;
    }
    return nil;
}

static void write_report(NSString *text) {
    NSString *path = probe_dir();
    if (!path) return;
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// short on-screen summary: symbol status plus the instance counts we rely on
static NSString *build_summary(void) {
    NSMutableString *s = [NSMutableString string];
    if (!g_domain) {
        [s appendString:@"il2cpp: NO DOMAIN\n"];
        return s;
    }
    [s appendString:@"il2cpp: OK\n"];

    // count instances of each candidate player component
    Il2CppClass *oc = kit_find_class("Object");
    Il2CppMethod *find = NULL;
    if (oc) {
        for (int argc = 1; argc <= 2 && !find; argc++)
            find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", argc);
    }
    [s appendString:find ? @"FindObjectsOfType: OK\n" : @"FindObjectsOfType: MISSING\n"];

    const char *cands[] = {"PlayerMovement", "PlayerNetwork", "RemoteBody", "BotController", "PlayerController"};
    for (int i = 0; i < 5; i++) {
        Il2CppClass *k = kit_find_class(cands[i]);
        if (!k) { [s appendFormat:@"%s: no class\n", cands[i]]; continue; }
        if (!find) { [s appendFormat:@"%s: no finder\n", cands[i]]; continue; }
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

// full dump including field offsets for the classes we care about
static NSString *build_full(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"twin probe @ %@\n\n", [NSDate date]];
    if (!g_domain) { [out appendString:@"kit_resolve FAILED\n"]; return out; }

    const char *names[] = {"PlayerMovement", "PlayerNetwork", "Camera", "Transform", "ArmsController"};
    for (int i = 0; i < 5; i++) {
        Il2CppClass *k = kit_find_class(names[i]);
        if (!k) { [out appendFormat:@"### %s NOT FOUND\n\n", names[i]]; continue; }
        [out appendFormat:@"### %s\n", names[i]];
        void *iter = NULL, *f = NULL;
        int n = 0;
        while ((f = g_kit.class_get_fields(k, &iter)) != NULL && n < 200) {
            const char *fn = g_kit.field_get_name(f);
            size_t off = g_kit.field_get_offset(f);
            if (fn) [out appendFormat:@"  FIELD %-32s +0x%zx\n", fn, off];
            n++;
        }
        [out appendFormat:@"  (%d fields)\n\n", n];
    }
    [out appendString:build_summary()];
    return out;
}

void twin_probe_run(void);

void twin_probe_run(void) {
    if (!g_domain) kit_resolve();
    g_twin_probe_text = build_full();
    write_report(g_twin_probe_text);
    NSLog(@"[twin] probe: %@", [build_summary() stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
}

__attribute__((constructor))
static void twin_probe_boot(void) {
    // run late enough that Managed code is alive, then refresh once at 20s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        twin_probe_run();
    });
}
