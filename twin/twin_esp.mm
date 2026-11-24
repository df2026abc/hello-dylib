// language: Objective-C++, file: twin/twin_esp.mm, target: iOS 15+, arm64
// ESP built on the same call chain KAlert uses:
//   PlayerController.get_Player -> PlayerNetwork -> Transform.get_position
//   Camera.get_MainCamera -> Camera.WorldToScreenPoint
//   PlayerController.get_Team for the friendly check
// Green 1px outline only; teammates are skipped.
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <string.h>

typedef struct { float x, y, z; } Vec3;

extern bool twin_cfg_esp;
extern float twin_cfg_opacity;

// ---------------- view ----------------

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

// ---------------- managed handles ----------------

static Il2CppClass  *c_player_controller, *c_camera, *c_transform, *c_object;
static Il2CppMethod *m_find_all, *m_pc_get_player, *m_pc_get_team;
static Il2CppMethod *m_cam_main, *m_w2s;
static Il2CppMethod *m_net_get_transform;
static Il2CppMethod *m_tr_get_pos;
static int32_t g_self_team = INT32_MIN;
static TwinEspLayer *g_layer;
static BOOL g_bound;
static Il2CppArray *g_cache;
static CFAbsoluteTime g_lastScan;

static int resolve_esp(void) {
    if (!g_domain) return 0;
    if (!c_player_controller) c_player_controller = kit_find_class("PlayerController");
    if (!c_camera) c_camera = kit_find_class("Camera");
    if (!c_transform) c_transform = kit_find_class("Transform");
    if (!c_object) c_object = kit_find_class("Object");
    if (!c_player_controller || !c_camera) return 0;

    if (!m_pc_get_player) m_pc_get_player = kit_method(c_player_controller, "get_Player", 0);
    if (!m_pc_get_team)   m_pc_get_team   = kit_method(c_player_controller, "get_Team", 0);
    if (!m_cam_main)      m_cam_main      = kit_method(c_camera, "get_MainCamera", 0);
    if (!m_w2s)           m_w2s           = kit_method(c_camera, "WorldToScreenPoint", 1);
    if (!m_tr_get_pos)    m_tr_get_pos    = kit_method(c_transform, "get_position", 0);

    // PlayerNetwork carries the Transform; resolve it lazily once the class exists
    Il2CppClass *net = kit_find_class("PlayerNetwork");
    if (net && !m_net_get_transform) m_net_get_transform = kit_method(net, "get_transform", 0);

    if (c_object && !m_find_all) {
        for (int a = 1; a <= 2 && !m_find_all; a++)
            m_find_all = g_kit.class_get_method_from_name(c_object, "FindObjectsOfType", a);
    }
    return (m_cam_main && m_w2s && m_tr_get_pos && m_find_all) ? 1 : 0;
}

static Il2CppArray *find_of(Il2CppClass *k) {
    if (!k || !m_find_all) return NULL;
    Il2CppType *ty = g_kit.class_get_type(k);
    Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
    if (!typeObj) return NULL;
    int32_t inc = 0;
    void *args[2] = { typeObj, &inc };
    return (Il2CppArray *)kit_invoke(m_find_all, NULL, args);
}

// PlayerController -> Player -> Transform
static Il2CppObject *transform_of(Il2CppObject *pc) {
    if (!pc) return NULL;
    Il2CppObject *player = m_pc_get_player ? kit_invoke(m_pc_get_player, pc, NULL) : NULL;
    if (!player) return NULL;
    Il2CppObject *tr = m_net_get_transform ? kit_invoke(m_net_get_transform, player, NULL) : NULL;
    return tr;
}

static Vec3 world_of(Il2CppObject *tr) {
    Il2CppObject *p = (tr && m_tr_get_pos) ? kit_invoke(m_tr_get_pos, tr, NULL) : NULL;
    return p ? *(Vec3 *)((char *)p + 0x10) : (Vec3){0, 0, 0};
}

static BOOL project(Il2CppObject *cam, Vec3 world, CGPoint *out) {
    if (!cam || !m_w2s) return NO;
    void *args[1] = { &world };
    Il2CppObject *res = kit_invoke(m_w2s, cam, args);
    if (!res) return NO;
    Vec3 *v = (Vec3 *)((char *)res + 0x10);
    if (v->z <= 0.01f) return NO;
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat h = UIScreen.mainScreen.bounds.size.height * scale;
    out->x = v->x / scale;
    out->y = (h - v->y) / scale;
    return YES;
}

// ---------------- driver ----------------

@interface TwinEspDriver : NSObject
+ (instancetype)shared;
+ (void)start;
- (void)step:(CADisplayLink *)link;
@end

@implementation TwinEspDriver
+ (instancetype)shared {
    static TwinEspDriver *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [TwinEspDriver new]; });
    return s;
}
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
        if (!twin_cfg_esp) {
            if (g_layer) [g_layer setRects:@[]];
            return;
        }
        if (!g_domain) { kit_resolve(); }
        if (!g_bound) g_bound = resolve_esp() != 0;
        if (!g_bound) return;

        Il2CppObject *cam = kit_invoke(m_cam_main, NULL, NULL);
        if (!cam) return;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!g_cache || now - g_lastScan > 0.5) {
            g_cache = find_of(c_player_controller);
            g_lastScan = now;
        }
        if (!g_cache) return;

        NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:16];
        for (size_t i = 0; i < g_cache->bounds.length; i++) {
            Il2CppObject *pc = (Il2CppObject *)kit_arr_at(g_cache, i);
            if (!pc) continue;

            // team check: same team as the local player means a teammate
            if (g_self_team != INT32_MIN && m_pc_get_team) {
                Il2CppObject *tv = kit_invoke(m_pc_get_team, pc, NULL);
                if (tv) {
                    int32_t team = *(int32_t *)((char *)tv + 0x10);
                    if (team == g_self_team) continue;
                }
            } else if (m_pc_get_team) {
                Il2CppObject *tv = kit_invoke(m_pc_get_team, pc, NULL);
                if (tv) g_self_team = *(int32_t *)((char *)tv + 0x10);
            }

            Il2CppObject *tr = transform_of(pc);
            if (!tr) continue;
            Vec3 world = world_of(tr);
            CGPoint sp;
            if (!project(cam, world, &sp)) continue;
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
