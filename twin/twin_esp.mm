// language: Objective-C++, file: twin/twin_esp.mm, target: iOS 15+, arm64
// *every frame rebuilds the layer list; a stale rect on screen is worse than none*
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

typedef struct { float x, y, z; } Vec3;

extern bool twin_cfg_esp;

#pragma mark - layer

@interface TwinEspLayer : UIView
@property (nonatomic, strong) NSMutableArray<UIView *> *pool;
- (void)setRects:(NSArray<NSValue *> *)rects;
@end

@implementation TwinEspLayer

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.pool = [NSMutableArray array];
    }
    return self;
}

// pooled boxes: steady-state frames allocate nothing
- (void)setRects:(NSArray<NSValue *> *)rects {
    NSUInteger need = rects.count;
    while (self.pool.count < need) {
        UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
        box.userInteractionEnabled = NO;
        box.backgroundColor = UIColor.clearColor;
        box.layer.borderColor = UIColor.greenColor.CGColor;
        box.layer.borderWidth = 1.0;
        box.hidden = YES;
        [self addSubview:box];
        [self.pool addObject:box];
    }
    for (NSUInteger i = 0; i < self.pool.count; i++) {
        UIView *box = self.pool[i];
        if (i < need) { box.frame = [rects[i] CGRectValue]; box.hidden = NO; }
        else          { box.hidden = YES; }
    }
}

@end

#pragma mark - managed handles

static Il2CppClass  *c_camera, *c_player, *c_object;
static Il2CppMethod *m_w2s, *m_main, *m_get_pos, *m_get_tf, *m_find;
static TwinEspLayer *g_layer;
static BOOL g_ready;

static Il2CppArray *find_players(void) {
    if (!c_object) c_object = kit_find_class("Object");
    if (!c_player) c_player = kit_find_class("Player");
    if (!m_find && c_object) {
        // the non-generic FindObjectsOfType(Type, bool) overload Unity ships
        for (int argc = 1; argc <= 2 && !m_find; argc++)
            m_find = g_kit.class_get_method_from_name(c_object, "FindObjectsOfType", argc);
    }
    if (!m_find || !c_player) return NULL;
    Il2CppType *t = g_kit.class_get_type(c_player);
    Il2CppObject *typeObj = t ? g_kit.type_get_object(t) : NULL;
    if (!typeObj) return NULL;
    int32_t include_inactive = 0;
    void *args[2] = { typeObj, &include_inactive };
    return (Il2CppArray *)kit_invoke(m_find, NULL, args);
}

static BOOL esp_bind(void) {
    if (!g_domain) return NO;
    c_camera = kit_find_class("Camera");
    c_player = kit_find_class("Player");
    if (!c_camera || !c_player) return NO;
    m_main    = kit_method(c_camera, "get_main", 0);
    m_w2s     = kit_method(c_camera, "WorldToScreenPoint", 1);
    m_get_tf  = kit_method(c_player, "get_transform", 0);
    m_get_pos = kit_method(c_player, "get_position", 0);
    g_ready = (m_main && m_w2s && m_get_tf && m_get_pos);
    return g_ready;
}

// world -> screen; z inside the boxed Vector3 flips sign behind the camera
static BOOL point_to_screen(Il2CppObject *cam, Vec3 world, CGPoint *out) {
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

#pragma mark - driver

@interface TwinEspDriver : NSObject
+ (void)start;
- (void)step:(CADisplayLink *)link;
@end

@implementation TwinEspDriver

+ (instancetype)shared {
    static TwinEspDriver *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TwinEspDriver new]; });
    return s;
}

+ (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) return;
        g_layer = [[TwinEspLayer alloc] initWithFrame:win.bounds];
        [win addSubview:g_layer];
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:[TwinEspDriver shared] selector:@selector(step:)];
        [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
}

- (void)step:(CADisplayLink *)link {
    @autoreleasepool {
        if (!twin_cfg_esp) { [g_layer setRects:@[]]; return; }
        if (!g_domain) { if (!kit_resolve()) return; }
        if (!g_ready && !esp_bind()) return;
        Il2CppObject *cam = kit_invoke(m_main, NULL, NULL);
        if (!cam) return;
        Il2CppArray *players = find_players();
        if (!players) return;

        NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:16];
        for (size_t i = 0; i < players->bounds.length; i++) {
            Il2CppObject *p = kit_arr_at(players, i);
            if (!p) continue;
            Il2CppObject *tf  = kit_invoke(m_get_tf, p, NULL);
            Il2CppObject *pos = tf ? kit_invoke(m_get_pos, tf, NULL) : NULL;
            if (!pos) continue;
            Vec3 world = *(Vec3 *)((char *)pos + 0x10);
            CGPoint sp;
            if (!point_to_screen(cam, world, &sp)) continue;
            [rects addObject:[NSValue valueWithCGRect:CGRectMake(sp.x - 12, sp.y - 18, 24, 36)]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [g_layer setRects:rects]; });
    }
    (void)link;
}

@end

__attribute__((constructor))
static void twin_esp_boot(void) {
    kit_resolve();
    [TwinEspDriver start];
}
