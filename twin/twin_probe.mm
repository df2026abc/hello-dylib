// language: Objective-C++, file: twin/twin_probe.mm, target: iOS 15+, arm64
// On-device diagnostic: dumps the runtime layout of every class twin depends on
// into Documents/twin_probe.txt so the offsets can be read off real memory
// instead of guessed from metadata.
#import "il2cpp_kit.h"
#import <Foundation/Foundation.h>

static void append(NSString *path, NSString *text) {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *dump_class(const char *name) {
    NSMutableString *out = [NSMutableString string];
    if (!g_domain) { [out appendString:@"no domain\n"]; return out; }
    Il2CppClass *k = kit_find_class(name);
    if (!k) { [out appendFormat:@"### %s  NOT FOUND\n\n", name]; return out; }

    [out appendFormat:@"### %s  FOUND\n", name];

    // fields with real offsets
    void *iter = NULL, *f = NULL;
    int nf = 0;
    while ((f = g_kit.class_get_fields(k, &iter)) != NULL && nf < 400) {
        const char *fn = g_kit.field_get_name(f);
        size_t off = g_kit.field_get_offset(f);
        if (fn) [out appendFormat:@"  FIELD %-34s +0x%zx\n", fn, off];
        nf++;
    }
    if (nf == 0) [out appendString:@"  (no fields)\n"];

    // a handful of instance count probes
    [out appendFormat:@"  field_count=%d\n\n", nf];
    return out;
}

// count how many live instances of a MonoBehaviour class exist right now
static NSString *count_instances(const char *name) {
    NSMutableString *out = [NSMutableString string];
    Il2CppClass *k = kit_find_class(name);
    if (!k) { [out appendFormat:@"COUNT %s: class missing\n", name]; return out; }
    Il2CppClass *oc = kit_find_class("Object");
    if (!oc) { [out appendString:@"COUNT: Object class missing\n"]; return out; }
    Il2CppMethod *find = NULL;
    for (int argc = 1; argc <= 2 && !find; argc++)
        find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", argc);
    if (!find) { [out appendString:@"COUNT: FindObjectsOfType missing\n"]; return out; }
    Il2CppType *ty = g_kit.class_get_type(k);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) { [out appendFormat:@"COUNT %s: no type object\n", name]; return out; }
    int32_t inc = 0;
    void *args[2] = { typeObj, &inc };
    Il2CppObject *res = kit_invoke(find, NULL, args);
    Il2CppArray *arr = (Il2CppArray *)res;
    [out appendFormat:@"COUNT %s: %zu live\n", name, arr ? arr->bounds.length : 0];
    return out;
}

__attribute__((constructor))
static void twin_probe_boot(void) {
    // wait for the game to finish loading, then write one report
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!kit_resolve()) {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            append([docs stringByAppendingPathComponent:@"twin_probe.txt"], @"kit_resolve FAILED: il2cpp symbols not exported\n");
            return;
        }
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [docs stringByAppendingPathComponent:@"twin_probe.txt"];

        NSMutableString *report = [NSMutableString string];
        [report appendFormat:@"twin probe @ %@\n\n", [NSDate date]];
        [report appendString:dump_class("PlayerMovement")];
        [report appendString:dump_class("PlayerNetwork")];
        [report appendString:dump_class("Camera")];
        [report appendString:dump_class("Transform")];
        [report appendString:count_instances("PlayerMovement")];
        [report appendString:count_instances("PlayerNetwork")];
        [report appendString:count_instances("RemoteBody")];
        [report appendString:count_instances("BotController")];
        append(path, report);

        // also mirror to the log so it is visible in Console
        NSLog(@"[twin] probe written to %@", path);
    });
}
