// language: Objective-C++, file: twin/twin_aim.mm, target: iOS 15+, arm64
// Aimbot on the KAlert call chain:
//   PlayerController.get_Player -> PlayerNetwork -> Transform
//   PlayerAnimatorController.GetBoneTransform("head") for the lock point
//   Camera.get_MainCamera for the view transform
// Slew is humanised the way the author's anti_ban.lua does it.
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <math.h>
#include <stdint.h>
#include <string.h>

typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y, z, w; } Quat;

static const float kDeg = 57.29578f;

extern bool twin_cfg_aim;
extern bool twin_cfg_aim_body;   // true = chest, false = head

static float cfg_max_turn_deg = 42.f;
static int   cfg_reaction_ms  = 180;
static float cfg_jitter_deg   = 0.35f;
static int   cfg_switch_cd    = 800;

static Il2CppClass  *c_player_controller, *c_camera, *c_transform, *c_anim;
static Il2CppMethod *m_find_all, *m_pc_get_player, *m_pc_get_team;
static Il2CppMethod *m_net_get_transform, *m_tr_get_pos, *m_tr_get_rot, *m_tr_set_rot;
static Il2CppMethod *m_cam_main, *m_bone_transform, *m_set_forward, *m_set_euler;
static int32_t g_self_team = INT32_MIN;

static uint64_t t_start, t_pending_at, t_last_switch;
static double phase;
static void *target;
static BOOL ready;

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t t = (uint64_t)ts.tv_sec * 1000ull + ts.tv_nsec / 1000000ull;
    if (!t_start) t_start = t;
    return t - t_start;
}
static float clampf(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
static float norm180(float a) { return fmodf(a + 540.f, 360.f) - 180.f; }
static double rand01(void) { return (double)arc4random() / 4294967296.0; }

static float humanize(float delta, float dt) {
    float rate = cfg_max_turn_deg * dt;
    float step = clampf(delta, -rate, rate);
    phase += dt * (7.3 + rand01() * 2.1);
    return step + (float)sin(phase) * cfg_jitter_deg;
}

static int resolve_aim(void) {
    if (!g_domain) return 0;
    if (!c_player_controller) c_player_controller = kit_find_class("PlayerController");
    if (!c_camera) c_camera = kit_find_class("Camera");
    if (!c_transform) c_transform = kit_find_class("Transform");
    if (!c_anim) c_anim = kit_find_class("PlayerAnimatorController");
    if (!c_player_controller || !c_camera) return 0;

    if (!m_pc_get_player) m_pc_get_player = kit_method(c_player_controller, "get_Player", 0);
    if (!m_pc_get_team)   m_pc_get_team   = kit_method(c_player_controller, "get_Team", 0);
    if (!m_cam_main)      m_cam_main      = kit_method(c_camera, "get_MainCamera", 0);
    if (!m_set_forward)   m_set_forward   = kit_method(c_transform, "set_forward", 1);
    if (!m_set_euler)     m_set_euler     = kit_method(c_transform, "set_eulerAngles", 1);
    if (!m_tr_get_pos)    m_tr_get_pos    = kit_method(c_transform, "get_position", 0);
    if (!m_tr_get_rot)    m_tr_get_rot    = kit_method(c_transform, "get_rotation", 0);
    if (!m_tr_set_rot)    m_tr_set_rot    = kit_method(c_transform, "set_rotation", 1);

    Il2CppClass *net = kit_find_class("PlayerNetwork");
    if (net && !m_net_get_transform) m_net_get_transform = kit_method(net, "get_transform", 0);
    if (c_anim && !m_bone_transform) m_bone_transform = kit_method(c_anim, "GetBoneTransform", 1);

    Il2CppClass *oc = kit_find_class("Object");
    if (oc && !m_find_all) for (int a = 1; a <= 2 && !m_find_all; a++)
        m_find_all = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);

    return (m_cam_main && m_tr_get_rot && m_tr_set_rot && m_find_all) ? 1 : 0;
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

static Il2CppObject *player_of(Il2CppObject *pc) {
    return (pc && m_pc_get_player) ? kit_invoke(m_pc_get_player, pc, NULL) : NULL;
}
static Il2CppObject *transform_of(Il2CppObject *pc) {
    Il2CppObject *p = player_of(pc);
    return (p && m_net_get_transform) ? kit_invoke(m_net_get_transform, p, NULL) : NULL;
}
static Vec3 pos_of(Il2CppObject *tr) {
    Il2CppObject *p = (tr && m_tr_get_pos) ? kit_invoke(m_tr_get_pos, tr, NULL) : NULL;
    return p ? *(Vec3 *)((char *)p + 0x10) : (Vec3){0, 0, 0};
}
static Quat rot_of(Il2CppObject *tr) {
    Il2CppObject *q = (tr && m_tr_get_rot) ? kit_invoke(m_tr_get_rot, tr, NULL) : NULL;
    return q ? *(Quat *)((char *)q + 0x10) : (Quat){0, 0, 0, 1};
}
static void set_rot(Il2CppObject *tr, Quat q) {
    if (!tr || !m_tr_set_rot) return;
    void *args[1] = { &q };
    kit_invoke(m_tr_set_rot, tr, args);
}

// head bone through the animator, falling back to a body offset
static Vec3 aim_point(Il2CppObject *pc, Il2CppObject *tr) {
    if (!twin_cfg_aim_body && m_bone_transform) {
        Il2CppObject *anim = NULL;
        // PlayerController may expose the animator directly
        Il2CppMethod *ga = kit_method(c_player_controller, "get_PlayerAnimatorController", 0);
        if (ga) anim = kit_invoke(ga, pc, NULL);
        if (!anim) {
            // otherwise search the Player for one
            Il2CppClass *ac = c_anim;
            if (ac) {
                Il2CppMethod *gf = g_kit.class_get_method_from_name(ac, "GetBoneTransform", 1);
                (void)gf;
            }
        }
        if (anim) {
            Il2CppObject *str = NULL;
            (void)str;
            // HumanBodyBones.Head == 10
            int32_t bone = 10;
            void *args[1] = { &bone };
            Il2CppObject *bt = kit_invoke(m_bone_transform, anim, args);
            if (bt) {
                Vec3 p = pos_of(bt);
                if (p.x != 0 || p.y != 0 || p.z != 0) return p;
            }
        }
    }
    Vec3 p = pos_of(tr);
    p.y += twin_cfg_aim_body ? 0.9f : 1.55f;
    return p;
}

static Quat from_yaw_pitch(float yaw, float pitch) {
    float hy = yaw * 0.5f / kDeg, hp = pitch * 0.5f / kDeg;
    float sy = sinf(hy), cy = cosf(hy), sp = sinf(hp), cp = cosf(hp);
    return (Quat){ cy * sp, sy * cp, -sy * sp, cy * cp };
}
static void to_yaw_pitch(Quat q, float *yaw, float *pitch) {
    float fx = 2.f * (q.x * q.z + q.w * q.y);
    float fy = 2.f * (q.y * q.z - q.w * q.x);
    float fz = 1.f - 2.f * (q.x * q.x + q.y * q.y);
    *yaw = atan2f(fx, fz) * kDeg;
    *pitch = -asinf(clampf(fy, -1.f, 1.f)) * kDeg;
}

@interface TwinAim : NSObject
+ (instancetype)shared;
+ (void)start;
- (void)step:(CADisplayLink *)link;
@end

@implementation TwinAim
+ (instancetype)shared { static TwinAim *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [TwinAim new]; }); return s; }
+ (void)start {
    CADisplayLink *l = [CADisplayLink displayLinkWithTarget:[TwinAim shared] selector:@selector(step:)];
    [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)step:(CADisplayLink *)link {
    @autoreleasepool {
        if (!twin_cfg_aim) { target = NULL; return; }
        if (!g_domain) { kit_resolve(); }
        if (!ready) ready = resolve_aim() != 0;
        if (!ready) return;

        Il2CppObject *cam = kit_invoke(m_cam_main, NULL, NULL);
        if (!cam) return;
        Il2CppMethod *cam_tr_m = kit_method(c_camera, "get_transform", 0);
        Il2CppObject *camTr = cam_tr_m ? kit_invoke(cam_tr_m, cam, NULL) : NULL;
        if (!camTr) return;

        uint64_t t = now_ms();
        static Il2CppArray *cache; static uint64_t lastScan;
        if (!cache || t - lastScan > 400) { cache = find_of(c_player_controller); lastScan = t; }
        if (!cache || cache->bounds.length == 0) { target = NULL; return; }

        Vec3 eye = pos_of(camTr);
        void *best = NULL; float bestD2 = 1e9f;
        for (size_t i = 0; i < cache->bounds.length; i++) {
            Il2CppObject *pc = (Il2CppObject *)kit_arr_at(cache, i);
            if (!pc) continue;
            if (m_pc_get_team) {
                Il2CppObject *tv = kit_invoke(m_pc_get_team, pc, NULL);
                if (tv) {
                    int32_t team = *(int32_t *)((char *)tv + 0x10);
                    if (g_self_team == INT32_MIN) { g_self_team = team; }
                    if (team == g_self_team) continue;   // skip teammates
                }
            }
            Il2CppObject *tr = transform_of(pc);
            if (!tr || tr == camTr) continue;
            Vec3 p = pos_of(tr);
            float dx = p.x - eye.x, dy = p.y - eye.y, dz = p.z - eye.z;
            float d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < bestD2) { bestD2 = d2; best = pc; }
        }
        if (!best) { target = NULL; return; }
        if (best != target) { target = best; t_pending_at = t; return; }
        if (t - t_pending_at < (uint64_t)cfg_reaction_ms) return;
        if (t_last_switch && t - t_last_switch < (uint64_t)cfg_switch_cd) return;

        Il2CppObject *tgtTr = transform_of((Il2CppObject *)best);
        if (!tgtTr) return;
        Vec3 ap = aim_point((Il2CppObject *)best, tgtTr);

        float dx = ap.x - eye.x, dy = ap.y - eye.y, dz = ap.z - eye.z;
        float wantYaw = atan2f(dx, dz) * kDeg;
        float wantPitch = -atan2f(dy, sqrtf(dx * dx + dz * dz) + 1e-6f) * kDeg;

        float curYaw, curPitch;
        to_yaw_pitch(rot_of(camTr), &curYaw, &curPitch);

        float dt = 1.f / 60.f;
        float ny = curYaw + humanize(norm180(wantYaw - curYaw), dt);
        float np = clampf(curPitch + humanize(wantPitch - curPitch, dt), -89.f, 89.f);
        // aim with a forward vector; KAlert sets forward rather than raw rotation
        Vec3 dir = { sinf(ny / kDeg) * cosf(np / kDeg), -sinf(np / kDeg), cosf(ny / kDeg) * cosf(np / kDeg) };
        if (m_set_forward) {
            void *args[1] = { &dir };
            kit_invoke(m_set_forward, camTr, args);
        } else {
            set_rot(camTr, from_yaw_pitch(ny, np));
        }
    }
    (void)link;
}
@end

__attribute__((constructor))
static void twin_aim_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kit_resolve();
        [TwinAim start];
    });
}
