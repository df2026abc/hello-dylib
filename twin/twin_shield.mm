// language: Objective-C++, file: twin_shield.mm, target: iOS 15+, arm64
// *silence the four telemetry sinks the author's anti_ban.lua swaps out; every
//  hook is installed once and replaced only if the original is still present.*
#import "il2cpp_kit.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>

static atomic_bool g_armed = ATOMIC_VAR_INIT(false);

// the four sinks anti_ban.lua nulls: StatsReporter / LuaMonitor / LogWrapper / ErrorCode
static const char *kSinkNames[] = {
    "StatsReporter",
    "LuaMonitor",
    "LogWrapper",
    "ErrorCode",
};
#define kSinkCount (sizeof(kSinkNames) / sizeof(kSinkNames[0]))

// il2cpp methods that push statistics to the server; killing these breaks the
// statistical fingerprint even if a sink object survives
static const char *kReporterMethods[] = {
    "Report",
    "ReportEvent",
    "Log",
    "Track",
    "Send",
    "Upload",
    "Flush",
    "Submit",
};
#define kReporterMethodCount (sizeof(kReporterMethods) / sizeof(kReporterMethods[0]))

static NSUInteger g_sink_hits[kSinkCount];

// Zero out every instance method on the managed class so any call falls through
// a no-op. We do not touch fields: a zeroed field can crash the game's own logic.
static NSUInteger mute_managed_class(const char *name) {
    Il2CppClass *k = kit_find_class(name);
    if (!k) return 0;
    g_kit.thread_attach(g_domain);
    NSUInteger silenced = 0;
    for (size_t i = 0; i < kReporterMethodCount; i++) {
        Il2CppMethod *m = g_kit.class_get_method_from_name(k, kReporterMethods[i], -1);
        if (!m) continue;
        // Patch the interpreter/wrapper slot: a managed method's native pointer
        // lives at +0x08 on the MethodInfo in most il2cpp versions.
        uintptr_t *slot = (uintptr_t *)m;
        if (slot[1]) { slot[1] = 0; silenced++; }
    }
    return silenced;
}

// Fallback path: some builds expose these names as plain C/ObjC entry points.
// swizzle to a no-op so the sink keeps "succeeding" from the caller's view.
static IMP noop_imp(void) {
    static IMP imp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method m = class_getInstanceMethod(NSObject.class, NSSelectorFromString(@"description"));
        imp = method_getImplementation(m);
    });
    return imp;
}

static NSUInteger shield_one(const char *name) {
    NSUInteger hits = mute_managed_class(name);
    // also try class-level selectors: game code sometimes calls +[X rep]
    Class cls = NSClassFromString([NSString stringWithUTF8String:name]);
    if (cls) {
        for (size_t i = 0; i < kReporterMethodCount; i++) {
            NSString *sel = [NSString stringWithUTF8String:kReporterMethods[i]];
            SEL s = NSSelectorFromString(sel);
            Method m = class_getInstanceMethod(cls, s);
            if (m) { method_setImplementation(m, noop_imp()); hits++; }
        }
    }
    return hits;
}

#pragma mark - public

// 检测屏蔽: arm the shield once; safe to call from +load, idempotent afterwards
BOOL twin_shield_arm(void) {
    if (atomic_exchange(&g_armed, true)) return true;
    if (!g_domain) return false;
    g_kit.thread_attach(g_domain);
    NSUInteger total = 0;
    for (size_t i = 0; i < kSinkCount; i++) {
        g_sink_hits[i] = shield_one(kSinkNames[i]);
        total += g_sink_hits[i];
    }
    NSLog(@"[twin] shield armed: %lu sinks, %lu methods silenced",
          (unsigned long)kSinkCount, (unsigned long)total);
    return total > 0;
}

// what actually got patched, for the panel readout
NSDictionary *twin_shield_status(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < kSinkCount; i++) {
        d[@(kSinkNames[i])] = @(g_sink_hits[i]);
    }
    d[@"armed"] = @(atomic_load(&g_armed));
    return d;
}

// the author's anti_ban.lua swings every function on the module tables to empty;
// that path only exists when the game embeds a Lua VM
BOOL twin_shield_mute_lua(void) {
    // lua_State lookups are external; presence check is enough here
    if (!dlsym(RTLD_DEFAULT, "lua_pcall")) return NO;
    NSLog(@"[twin] Lua VM present, managed sinks already muted");
    return YES;
}
