// language: Objective-C++, file: twin/twin_esp.mm, target: iOS 15+, arm64
// ESP on the real method table of CounterFlame 1.4.1 (read from global-metadata
// with the validated 0x24 method stride):
//   PlayerController.get_MainCamera        -> then Camera.WorldToScreenPoint
//   PlayerController.get_Player            -> Player
//   PlayerController.get_IsDeath / get_Health
//   PlayerNetwork.TryGetPosition           -> world position
//   Player.get_Team / get_IsAlive
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <string.h>

typedef struct { float x, y, z; } Vec3;

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
    UIColor *green = [UIColor colorWithRed:0.15 green:1.0 blue:0.35 alpha:twin_cfg_opacity];
    for (NSUInteger i = 0; i < self.pool.count; i++) {
        UIView *box = self.pool[i];
        if (i < need) { box.layer.borderColor = green.CGColor; box.frame = [rects[i] CGRectValue]; box.hidden = NO; }
        else box.hidden = YES;
    }
}
@end

// ---------------- handles ----------------

static Il2CppClass  *c_cam, *c_pc, *c_player, *c_net;
static Il2CppMethod *m_find;
static Il2CppMethod *m_pc_main_cam, *m_pc_get_player, *m_pc_is_death;
static Il2CppMethod *m_player_team, *m_player_alive;
static Il2CppMethod *m_cam_w2s;
static Il2CppMethod *m_net_try_pos;

static TwinEspLayer *g_layer;
static BOOL g_ready;
static int32_t g_team = INT32_MIN;
static Il2CppArray *g_cache;
static CFAbsoluteTime g_scan;

static Il2CppArray *scan_pc(void) {
    if (!m_find || !c_pc) return NULL;
    Il2CppType *ty = g_kit.class_get_type(c_pc);
    Il2CppObject *to = ty ? g_kit.type_get_object(ty) : NULL;
    if (!to) return NULL;
    int32_t inc = 0;
    void *args[2] = { to, &inc };
    return (Il2CppArray *)kit_invoke(m_find, NULL, args);
}

static int bind_esp(void) {
    if (!g_domain) return 0;
    if (!c_pc)     c_pc     = kit_find_class("PlayerController");
    if (!c_cam)    c_cam    = kit_find_class("Camera");
    if (!c_net)    c_net    = kit_find_class("PlayerNetwork");
    if (!c_player) c_player = kit_find_class("Player");
    if (!c_pc || !c_cam || !c_net) return 0;

    if (!m_pc_main_cam)  m_pc_main_cam  = kit_method(c_pc, "get_MainCamera", 0);
    if (!m_pc_get_player) m_pc_get_player = kit_method(c_pc, "get_Player", 0);
    if (!m_pc_is_death)  m_pc_is_death  = kit_method(c_pc, "get_IsDeath", 0);
    if (!m_cam_w2s)      m_cam_w2s      = kit_method(c_cam, "WorldToScreenPoint", 1);
    if (!m_net_try_pos)  m_net_try_pos  = kit_method(c_net, "TryGetPosition", -1);
    if (!m_player_team)  m_player_team  = kit_method(c_player, "get_Team", 0);
    if (!m_player_alive) m_player_alive = kit_method(c_player, "get_IsAlive", 0);

    Il2CppClass *oc = kit_find_class("Object");
    if (oc && !m_find) for (int a = 1; a <= 2 && !m_find; a++)
        m_find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);

    return (m_pc_main_cam && m_pc_get_player && m_cam_w2s && m_find) ? 1 : 0;
}

static Il2CppObject *inv0(Il2CppMethod *m, Il2CppObject *s) { return (m && s) ? kit_invoke(m, s, NULL) : NULL; }
static Vec3 vec_of(Il2CppObject *b) { return b ? *(Vec3 *)((char *)b + 0x10) : (Vec3){0,0,0}; }
static BOOL bool_of(Il2CppObject *b) { return b ? (*(int32_t *)((char *)b + 0x10) != 0) : NO; }
static int32_t int_of(Il2CppObject *b) { return b ? *(int32_t *)((char *)b + 0x10) : INT32_MIN; }

// PlayerController -> Player -> PlayerNetwork, then TryGetPosition
static BOOL player_world(Il2CppObject *pc, Vec3 *out) {
    Il2CppObject *player = inv0(m_pc_get_player, pc);
    if (!player) return NO;
    // PlayerNetwork sits on the same GameObject; TryGetPosition may take an out param
    if (m_net_try_pos) {
        Vec3 tmp = {0,0,0};
        void *args[2] = { &tmp, NULL };
        Il2CppObject *r = kit_invoke(m_net_try_pos, player, args);
        if (r) {
            if (bool_of(r)) { *out = tmp; return YES; }
            return NO;
        }
        if (tmp.x != 0 || tmp.y != 0 || tmp.z != 0) { *out = tmp; return YES; }
    }
    return NO;
}

static BOOL project(Il2CppObject *cam, Vec3 w, CGPoint *out) {
    if (!cam || !m_cam_w2s) return NO;
    void *args[1] = { &w };
    Il2CppObject *res = kit_invoke(m_cam_w2s, cam, args);
    if (!res) return NO;
    Vec3 *v = (Vec3 *)((char *)res + 0x10);
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
+ (instancetype)shared { static TwinEspDriver *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [TwinEspDriver new]; }); return s; }
+ (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) { win = w; break; }
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
        if (!twin_cfg_esp) { if (g_layer) [g_layer setRects:@[]]; return; }
        if (!g_domain) kit_resolve();
        if (!g_ready) g_ready = bind_esp() != 0;
        if (!g_ready) return;

        // the camera comes from any live PlayerController
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!g_cache || now - g_scan > 0.4) { g_cache = scan_pc(); g_scan = now; }
        if (!g_cache || g_cache->bounds.length == 0) return;

        Il2CppObject *cam = NULL;
        for (size_t i = 0; i < g_cache->bounds.length && !cam; i++) {
            Il2CppObject *pc = (Il2CppObject *)kit_arr_at(g_cache, i);
            if (pc) cam = inv0(m_pc_main_cam, pc);
        }
        if (!cam) return;

        NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:16];
        for (size_t i = 0; i < g_cache->bounds.length; i++) {
            Il2CppObject *pc = (Il2CppObject *)kit_arr_at(g_cache, i);
            if (!pc) continue;
            if (m_pc_is_death && bool_of(inv0(m_pc_is_death, pc))) continue;

            Il2CppObject *player = inv0(m_pc_get_player, pc);
            if (!player) continue;
            if (m_player_alive && !bool_of(inv0(m_player_alive, player))) continue;
            if (m_player_team) {
                Il2CppObject *tv = inv0(m_player_team, player);
                if (tv) {
                    int32_t t = int_of(tv);
                    if (g_team == INT32_MIN) { g_team = t; continue; }  // first = local
                    if (t == g_team) continue;                          // teammate
                }
            }

            Vec3 w;
            if (!player_world(pc, &w)) continue;
            CGPoint sp;
            if (!project(cam, w, &sp)) continue;
            [rects addObject:[NSValue valueWithCGRect:CGRectMake(sp.x - 12, sp.y - 18, 24, 36)]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [g_layer setRects:rects]; });
    }
    (void)link;
}
@end

__attribute__((constructor))
static void twin_esp_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kit_resolve();
        [TwinEspDriver start];
    });
}
