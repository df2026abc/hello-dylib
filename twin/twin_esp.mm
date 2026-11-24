// language: Objective-C++, file: twin/twin_esp.mm, target: iOS 15+, arm64
// ESP mirrored from KAlert's actual method table (addresses 0x64305-0x6464d),
// which is the set of il2cpp_class_get_method_from_name lookups it performs:
//   Camera.get_MainCamera -> WorldToScreenPoint
//   PlayerController.get_Player -> PlayerNetwork/Player -> get_transform -> get_position
//   PlayerController.get_Team / get_IsMine -> skip self and teammates
//   PlayerController.get_IsDeath -> skip corpses
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

// ---------------- handles ----------------

static Il2CppClass  *c_cam, *c_pc, *c_tr;
static Il2CppMethod *m_find;
static Il2CppMethod *m_cam_main, *m_cam_w2s;
static Il2CppMethod *m_pc_get_player, *m_pc_get_team, *m_pc_is_mine, *m_pc_is_death;
static Il2CppMethod *m_net_get_tf;
static Il2CppMethod *m_tr_get_pos;

static TwinEspLayer *g_layer;
static BOOL g_ready;
static int32_t g_team = INT32_MIN;
static Il2CppArray *g_cache;
static CFAbsoluteTime g_scan;

static int bind_esp(void) {
    if (!g_domain) return 0;
    if (!c_cam)  c_cam  = kit_find_class("Camera");
    if (!c_pc)   c_pc   = kit_find_class("PlayerController");
    if (!c_tr)   c_tr   = kit_find_class("Transform");
    if (!c_cam || !c_pc) return 0;

    if (!m_cam_main)     m_cam_main     = kit_method(c_cam, "get_MainCamera", 0);
    if (!m_cam_w2s)      m_cam_w2s      = kit_method(c_cam, "WorldToScreenPoint", 1);
    if (!m_pc_get_player) m_pc_get_player = kit_method(c_pc, "get_Player", 0);
    if (!m_pc_get_team)  m_pc_get_team  = kit_method(c_pc, "get_Team", 0);
    if (!m_pc_is_mine)   m_pc_is_mine   = kit_method(c_pc, "get_IsMine", 0);
    if (!m_pc_is_death)  m_pc_is_death  = kit_method(c_pc, "get_IsDeath", 0);
    if (!m_tr_get_pos)   m_tr_get_pos   = kit_method(c_tr, "get_position", 0);

    // PlayerNetwork carries the transform of a remote player
    Il2CppClass *net = kit_find_class("PlayerNetwork");
    if (net && !m_net_get_tf) m_net_get_tf = kit_method(net, "get_transform", 0);

    Il2CppClass *oc = kit_find_class("Object");
    if (oc && !m_find) for (int a = 1; a <= 2 && !m_find; a++)
        m_find = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);

    return (m_cam_main && m_cam_w2s && m_pc_get_player && m_tr_get_pos && m_find) ? 1 : 0;
}

static Il2CppObject *invoke0(Il2CppMethod *m, Il2CppObject *self) {
    return (m && self) ? kit_invoke(m, self, NULL) : NULL;
}

static Vec3 vec_of(Il2CppObject *boxed) {
    return boxed ? *(Vec3 *)((char *)boxed + 0x10) : (Vec3){0, 0, 0};
}

static BOOL bool_of(Il2CppObject *boxed) {
    return boxed ? (*(int32_t *)((char *)boxed + 0x10) != 0) : NO;
}

static int32_t int_of(Il2CppObject *boxed) {
    return boxed ? *(int32_t *)((char *)boxed + 0x10) : INT32_MIN;
}

// PlayerController -> Player -> Transform
static Il2CppObject *transform_of(Il2CppObject *pc) {
    Il2CppObject *player = invoke0(m_pc_get_player, pc);
    if (!player) return NULL;
    return invoke0(m_net_get_tf, player);
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

static Il2CppArray *find_of_pc(void) {
    if (!m_find || !c_pc) return NULL;
    Il2CppType *ty = g_kit.class_get_type(c_pc);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) return NULL;
    int32_t inc = 0;
    void *args[2] = { typeObj, &inc };
    return (Il2CppArray *)kit_invoke(m_find, NULL, args);
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

        Il2CppObject *cam = kit_invoke(m_cam_main, NULL, NULL);
        if (!cam) return;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!g_cache || now - g_scan > 0.4) { g_cache = find_of_pc(); g_scan = now; }
        if (!g_cache) return;

        NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:16];
        for (size_t i = 0; i < g_cache->bounds.length; i++) {
            Il2CppObject *pc = (Il2CppObject *)kit_arr_at(g_cache, i);
            if (!pc) continue;

            if (m_pc_is_mine && bool_of(invoke0(m_pc_is_mine, pc))) continue;   // self
            if (m_pc_is_death && bool_of(invoke0(m_pc_is_death, pc))) continue; // corpse

            Il2CppObject *tv = invoke0(m_pc_get_team, pc);
            if (tv) {
                int32_t t = int_of(tv);
                if (g_team == INT32_MIN) g_team = t;
                else if (t == g_team) continue;   // teammate
            }

            Il2CppObject *tr = transform_of(pc);
            if (!tr) continue;
            Vec3 w = vec_of(invoke0(m_tr_get_pos, tr));
            CGPoint sp;
            if (!project(cam, w, &sp)) continue;
            [rects addObject:[NSValue valueWithCGRect:CGRectMake(sp.x - 12, sp.y - 18, 24, 36)]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [g_layer setRects:rects]; });
    }
    (void)link;
}
@end

