// language: Objective-C++, file: twin/twin_aim.mm, target: iOS 15+, arm64
// *aim is a state machine: find, sleep on reaction, slew, fire on the tail of the slew*
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <math.h>
#include <stdint.h>

typedef struct { float x, y, z; } Vec3;

extern bool twin_cfg_aim;

static const float kDeg = 57.29578f;

// --- tunables mirrored from the author's anti_ban.lua ---
static float  cfg_max_turn_deg = 42.f;
static int    cfg_reaction_ms  = 180;
static float  cfg_jitter_deg   = 0.35f;
static float  cfg_fov_deg      = 8.f;
static int    cfg_fire_delay   = 90;
static int    cfg_switch_cd    = 800;
static int    cfg_burst_min    = 1200;
static int    cfg_burst_max    = 4200;
static BOOL   cfg_head_only    = YES;
static BOOL   cfg_nearest      = YES;
static BOOL   cfg_continuous   = NO;

@interface TwinAim : NSObject
+ (instancetype)shared;
+ (void)start;
- (void)step:(CADisplayLink *)link;
@end

// --- managed handles, resolved lazily ---
static Il2CppClass *c_camera, *c_player, *c_transform, *c_weapon;
static Il2CppMethod *m_cam_main, *m_w2s, *m_get_tf, *m_get_pos;
static Il2CppMethod *m_get_bone, *m_bone_name;
static Il2CppMethod *m_fire, *m_fire_prep_on, *m_fire_prep_off;
static Il2CppMethod *m_get_head;
static Il2CppMethod *m_find_players;

// --- runtime state ---
static uint64_t t_start_ms, t_pending_at, t_last_switch, t_fire_until, t_pause_until;
static uint64_t t_last_fire;
static double   phase;
static void    *target;        // last locked managed object pointer
static float    last_yaw, last_pitch;
static BOOL     ready;

static uint64_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t t = (uint64_t)ts.tv_sec * 1000ull + ts.tv_nsec / 1000000ull;
    if (!t_start_ms) t_start_ms = t;
    return t - t_start_ms;
}

static float clampf(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
static float norm180(float a) { return fmodf(a + 540.f, 360.f) - 180.f; }

static double rand01(void) { return (double)arc4random() / 4294967296.0; }

// first-order slew + sine wobble: not a snap, not a straight line
static float humanize(float delta, float dt) {
    float rate = cfg_max_turn_deg * dt;
    float step = clampf(delta, -rate, rate);
    phase += dt * (7.3 + rand01() * 2.1);
    return step + (float)sin(phase) * cfg_jitter_deg * dt * kDeg / kDeg;
}

static BOOL resolve_aim(void) {
    if (!g_domain) return NO;
    if (!c_camera) c_camera = kit_find_class("Camera");
    if (!c_player) c_player = kit_find_class("Player");
    if (!c_transform) c_transform = kit_find_class("Transform");
    if (!c_player || !c_camera) return NO;
    if (!m_cam_main) m_cam_main = kit_method(c_camera, "get_main", 0);
    if (!m_w2s) m_w2s = kit_method(c_camera, "WorldToScreenPoint", 1);
    if (!m_get_tf) m_get_tf = kit_method(c_player, "get_transform", 0);
    if (!m_get_bone) m_get_bone = kit_method(c_player, "GetBoneTransform", 1);
    if (!m_get_pos) m_get_pos = kit_method(c_transform, "get_position", 0);
    if (!m_find_players) {
        Il2CppClass *oc = kit_find_class("Object");
        if (oc) for (int a = 1; a <= 2 && !m_find_players; a++)
            m_find_players = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);
    }
    ready = (m_cam_main && m_w2s && m_get_tf && m_get_pos);
    return ready;
}

static Vec3 cam_position(void) {
    Il2CppObject *cam = kit_invoke(m_cam_main, NULL, NULL);
    if (!cam) return (Vec3){0,0,0};
    Il2CppMethod *gt = kit_method(c_camera, "get_transform", 0);
    Il2CppObject *tf = gt ? kit_invoke(gt, cam, NULL) : NULL;
    Il2CppObject *posObj = tf ? kit_invoke(m_get_pos, tf, NULL) : NULL;
    return posObj ? *(Vec3 *)((char *)posObj + 0x10) : (Vec3){0,0,0};
}

// bone index from HumanBodyBones; head = 10, spine/chest = 8
#define BONE_HEAD  10
#define BONE_CHEST  8

static Vec3 bone_world(Il2CppObject *player, int bone) {
    if (m_get_bone) {
        int32_t b = bone;
        void *args[1] = { &b };
        Il2CppObject *tf = kit_invoke(m_get_bone, player, args);
        if (tf) {
            Il2CppObject *p = kit_invoke(m_get_pos, tf, NULL);
            if (p) return *(Vec3 *)((char *)p + 0x10);
        }
    }
    Il2CppObject *tf = kit_invoke(m_get_tf, player, NULL);
    Il2CppObject *p = tf ? kit_invoke(m_get_pos, tf, NULL) : NULL;
    return p ? *(Vec3 *)((char *)p + 0x10) : (Vec3){0,0,0};
}

// nearest-or-first selection inside the FOV cone
static void *pick_target(Il2CppArray *players, Vec3 eye, float *out_dist) {
    if (!players) return NULL;
    void *best = NULL; float best_d = 1e9f;
    for (size_t i = 0; i < players->bounds.length; i++) {
        void *p = kit_arr_at(players, i);
        if (!p) continue;
        Vec3 head = bone_world((Il2CppObject *)p, cfg_head_only ? BONE_HEAD : BONE_CHEST);
        float dx = head.x - eye.x, dy = head.y - eye.y, dz = head.z - eye.z;
        float d2 = dx*dx + dy*dy + dz*dz;
        if (!best || (cfg_nearest && d2 < best_d)) { best = p; best_d = d2; }
    }
    *out_dist = sqrtf(best_d);
    return best;
}

// fire gate: prep toggle -> delay -> autoContinuousFire, with a forced burst pause
static void fire_gate(Il2CppObject *player) {
    uint64_t t = now_ms();
    if (t_pause_until && t < t_pause_until) return;
    if (m_fire_prep_on && m_fire_prep_off) {
        kit_invoke(m_fire_prep_on, player, NULL);
        if (cfg_continuous) kit_invoke(m_fire, player, NULL);
        kit_invoke(m_fire_prep_off, player, NULL);
    } else if (m_fire) {
        kit_invoke(m_fire, player, NULL);
    }
    if (t > t_fire_until) {
        t_fire_until = t + 3500;
        t_pause_until = t_fire_until + cfg_burst_min + (uint64_t)(rand01() * (cfg_burst_max - cfg_burst_min));
    }
}

@implementation TwinAim

+ (instancetype)shared { static TwinAim *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [TwinAim new]; }); return s; }

+ (void)start {
    CADisplayLink *l = [CADisplayLink displayLinkWithTarget:[TwinAim shared] selector:@selector(step:)];
    [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// one frame: pick, sleep, slew, maybe commit
- (void)step:(CADisplayLink *)link {
    @autoreleasepool {
        if (!twin_cfg_aim) { target = NULL; return; }
        if (!ready && !resolve_aim()) return;
        uint64_t t = now_ms();
        Il2CppClass *oc = kit_find_class("Object");
        if (!m_find_players || !oc) return;
        Il2CppType *ty = g_kit.class_get_type(c_player);
        Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
        if (!typeObj) return;
        int32_t include_inactive = 0;
        void *args[2] = { typeObj, &include_inactive };
        Il2CppArray *players = (Il2CppArray *)kit_invoke(m_find_players, NULL, args);
        if (!players) return;

        Vec3 eye = cam_position();
        float dist = 0.f;
        void *sel = pick_target(players, eye, &dist);
        if (!sel) { target = NULL; return; }

        if (sel != target) {
            target = sel; t_pending_at = t;
            return; // reaction window starts here, no turn yet
        }
        if (t - t_pending_at < (uint64_t)cfg_reaction_ms) return;
        if (t_last_switch && t - t_last_switch < (uint64_t)cfg_switch_cd) return;

        Vec3 head = bone_world((Il2CppObject *)sel, BONE_HEAD);
        float dx = head.x - eye.x, dy = head.y - eye.y, dz = head.z - eye.z;
        float want_yaw = atan2f(dy, dx) * kDeg;
        float want_pitch = -atan2f(dz, sqrtf(dx*dx + dy*dy) + 1e-6f) * kDeg;

        float dt = 1.f / 60.f;
        float d_yaw = norm180(want_yaw - last_yaw);
        float d_pitch = want_pitch - last_pitch;
        if (fabsf(d_yaw) < 0.6f && fabsf(d_pitch) < 0.6f) { d_yaw *= 1.06f; d_pitch *= 1.06f; }

        last_yaw   += humanize(d_yaw, dt);
        last_pitch += humanize(d_pitch, dt);

        if (fabsf(norm180(want_yaw - last_yaw)) < 0.4f && fabsf(want_pitch - last_pitch) < 0.4f
            && t - t_pending_at >= (uint64_t)(cfg_reaction_ms + cfg_fire_delay)) {
            fire_gate((Il2CppObject *)sel);
            t_last_fire = t;
        }
    }
}

@end

__attribute__((constructor))
static void twin_aim_boot(void) {
    kit_resolve();
    [TwinAim start];
}
