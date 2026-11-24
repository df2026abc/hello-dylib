// language: Objective-C++, file: twin/twin_esp.mm, target: iOS 15+, arm64
// ESP box renderer. Real class/field names come from the game's global-metadata:
//   PlayerMovement._tr / PlayerMovement._skeleton  -> per-player world anchor
//   UnityEngine.Camera.WorldToScreenPoint          -> projection
// Green 1px outline only; nothing else drawn.
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

typedef struct { float x, y, z; } Vec3;

// switches driven by the panel
extern bool twin_cfg_esp;
extern float twin_cfg_opacity;

@interface TwinEspLayer : UIView
@property (nonatomic, strong) NSMutableArray<UIView *> *pool;
- (void)setRects:(NSArray<NSValue *> *)rects;
@end

@implementation TwinEspLayer
- (instancetype)initWithFrame:(CGRect)f {
    if (self = [super initWithFrame:f]) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.pool = [NSMutableArray array];
    }
    return self;
}
- (void)setRects:(NSArray<NSValue *> *)rects {
    NSUInteger need = rects.count;
    while (self.pool.count < need) {
        UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
        box.userInteractionEnabled = NO;
        box.backgroundColor = UIColor.clearColor;
        box.layer.borderWidth = 1.5;
        box.hidden = YES;
        [self addSubview:box];
        [self.pool addObject:box];
    }
    // green outline, alpha follows the panel slider
    UIColor *green = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:twin_cfg_opacity];
    for (NSUInteger i = 0; i < self.pool.count; i++) {
        UIView *box = self.pool[i];
        if (i < need) {
            box.layer.borderColor = green.CGColor;
            box.frame = [rects[i] CGRectValue];
            box.hidden = NO;
        } else {
            box.hidden = YES;
        }
    }
}
@end

// ---- managed handles ----
static Il2CppClass *c_camera, *c_player_movement;
static Il2CppMethod *m_cam_main, *m_w2s;
static Il2CppMethod *m_pm_get_tr, *m_tr_get_pos;
static Il2CppMethod *m_find_all;
static Il2CppArray *g_cache;
static int32_t g_self_side;   // _side of the local player
static BOOL g_have_self_side;
static TwinEspLayer *g_layer;
static BOOL g_ready;
static CFAbsoluteTime g_lastScan;

// _side offset is resolved at runtime; the metadata only gives us the name
static int g_side_off = -2;
static int side_offset(void) {
    if (g_side_off != -2) return g_side_off;
    g_side_off = -1;
    if (!c_player_movement) return -1;
    void *iter = NULL, *f = NULL;
    while ((f = g_kit.class_get_fields(c_player_movement, &iter)) != NULL) {
        const char *nm = g_kit.field_get_name(f);
        if (nm && strcmp(nm, "_side") == 0) {
            g_side_off = (int)g_kit.field_get_offset(f);
            break;
        }
    }
    return g_side_off;
}

static int32_t read_side(Il2CppObject *pm) {
    int off = side_offset();
    if (off < 0 || !pm) return INT32_MIN;
    return *(int32_t *)((char *)pm + off);
}

static Il2CppArray *find_players(void) {
    if (!c_player_movement) return NULL;
    if (!m_find_all) {
        Il2CppClass *oc = kit_find_class("Object");
        if (!oc) return NULL;
        for (int argc = 1; argc <= 2 && !m_find_all; argc++)
            m_find_all = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", argc);
    }
    if (!m_find_all) return NULL;
    Il2CppType *ty = g_kit.class_get_type(c_player_movement);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) return NULL;
    int32_t includeInactive = 0;
    void *args[2] = { typeObj, &includeInactive };
    return (Il2CppArray *)kit_invoke(m_find_all, NULL, args);
}

// both component types are scanned; a player visible as either one gets a box
static Il2CppArray *find_players2(void) {
    static Il2CppClass *c_net;
    if (!c_net) c_net = kit_find_class("PlayerNetwork");
    if (!c_net || !m_find_all) return NULL;
    Il2CppType *ty = g_kit.class_get_type(c_net);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) return NULL;
    int32_t inc = 0;
    void *args[2] = { typeObj, &inc };
    return (Il2CppArray *)kit_invoke(m_find_all, NULL, args);
}

static BOOL esp_bind(void) {
    if (!g_domain) return NO;
    c_camera = kit_find_class("Camera");
    // the class name in metadata is "PlayerMovement", no namespace
    c_player_movement = kit_find_class("PlayerMovement");
    if (!c_camera || !c_player_movement) return NO;

    m_cam_main = kit_method(c_camera, "get_main", 0);
    m_w2s = kit_method(c_camera, "WorldToScreenPoint", 1);
    m_pm_get_tr = kit_method(c_player_movement, "get_transform", 0);
    Il2CppClass *tf = kit_find_class("Transform");
    m_tr_get_pos = tf ? kit_method(tf, "get_position", 0) : NULL;

    g_ready = (m_cam_main && m_w2s && m_pm_get_tr && m_tr_get_pos);
    return g_ready;
}

static BOOL project(Il2CppObject *cam, Vec3 world, CGPoint *out) {
    if (!cam || !m_w2s) return NO;
    void *args[1] = { &world };
    Il2CppObject *res = kit_invoke(m_w2s, cam, args);
    if (!res) return NO;
    Vec3 *v = (Vec3 *)((char *)res + 0x10); // Vector3 payload after object header
    if (v->z <= 0.01f) return NO;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat h = UIScreen.mainScreen.bounds.size.height * scale;
    out->x = v->x / scale;
    out->y = (h - v->y) / scale;
    return YES;
}

@interface TwinEspDriver : NSObject
+ (instancetype)shared;
+ (void)start;
- (void)step:(CADisplayLink *)link;
@end

@implementation TwinEspDriver
+ (instancetype)shared {
    static TwinEspDriver *s;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [TwinEspDriver new]; });
    return s;
}
+ (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows)
                if (w.isKeyWindow) { win = w; break; }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self start]; }); return; }
        g_layer = [[TwinEspLayer alloc] initWithFrame:win.bounds];
        [win addSubview:g_layer];
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:[TwinEspDriver shared] selector:@selector(step:)];
        [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
}
- (void)step:(CADisplayLink *)link {
    @autoreleasepool {
        if (!twin_cfg_esp) { if (g_layer.hidden == NO) { [g_layer setRects:@[]]; } return; }
        if (!g_domain) { if (!kit_resolve()) return; }
        if (!g_ready && !esp_bind()) return;

        Il2CppObject *cam = kit_invoke(m_cam_main, NULL, NULL);
        if (!cam) return;

        // re-latch the local side on every scene swap (round end, side switch);
        // a stale value would paint teammates as enemies for the whole match
        static uint64_t last_latch;
        uint64_t latchNow = (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
        if (g_cache && (!g_have_self_side || latchNow - last_latch > 2000)) {
            last_latch = latchNow;
            for (size_t i = 0; i < g_cache->bounds.length; i++) {
                Il2CppObject *pm = (Il2CppObject *)kit_arr_at(g_cache, i);
                if (!pm) continue;
                int32_t sv = read_side(pm);
                if (sv != INT32_MIN) { g_self_side = sv; g_have_self_side = YES; break; }
            }
        }

        // rescan the scene every 500 ms; per-frame enumeration is wasteful
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!g_cache || now - g_lastScan > 0.5) {
            g_cache = find_players();
            g_lastScan = now;
        }

        NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:32];
        Il2CppArray *sets[2] = { g_cache, find_players2() };
        for (int si = 0; si < 2; si++) {
            Il2CppArray *arr = sets[si];
            if (!arr) continue;
            for (size_t i = 0; i < arr->bounds.length; i++) {
                Il2CppObject *pm = (Il2CppObject *)kit_arr_at(arr, i);
                if (!pm) continue;
                Il2CppObject *tr = kit_invoke(m_pm_get_tr, pm, NULL);
                if (!tr) continue;
                Il2CppObject *posObj = kit_invoke(m_tr_get_pos, tr, NULL);
                if (!posObj) continue;
                // teammates share the local _side value and are not drawn
                if (g_have_self_side) {
                    int32_t side = read_side((Il2CppObject *)pm);
                    if (side != INT32_MIN && side == g_self_side) continue;
                }
                Vec3 world = *(Vec3 *)((char *)posObj + 0x10);
                CGPoint sp;
                if (!project(cam, world, &sp)) continue;
                [rects addObject:[NSValue valueWithCGRect:CGRectMake(sp.x - 12, sp.y - 18, 24, 36)]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [g_layer setRects:rects]; });
    }
    (void)link;
}
@end

__attribute__((constructor))
static void twin_esp_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kit_resolve();
        [TwinEspDriver start];
    });
}
