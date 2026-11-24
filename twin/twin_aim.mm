// language: Objective-C++, file: twin/twin_aim.mm, target: iOS 15+, arm64
// Aimbot driven by the game's real classes (names read from global-metadata.dat):
//   PlayerMovement  -> per-player transform, position
//   Camera          -> Camera.main, WorldToScreenPoint
//   Transform       -> get_position / get_rotation / set_rotation
// Lock: head bone when reachable, chest fallback. Humanisation mirrors the
// author's anti_ban.lua (42 deg/s slew, 180 ms reaction, 0.35 deg jitter).
#import "il2cpp_kit.h"
#import <UIKit/UIKit.h>
#import <math.h>
#include <stdint.h>

typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y, z, w; } Quat;

static const float kDeg = 57.29578f;

extern bool twin_cfg_aim;

static float cfg_max_turn_deg = 42.f;
static int   cfg_reaction_ms  = 180;
static float cfg_jitter_deg   = 0.35f;
static int   cfg_fire_delay   = 90;
static int   cfg_switch_cd    = 800;
static BOOL  cfg_head_only    = YES;

static Il2CppClass *c_camera, *c_player_movement, *c_transform;
static Il2CppMethod *m_cam_main, *m_w2s;
static Il2CppMethod *m_pm_get_tr, *m_tr_get_pos, *m_tr_get_rot, *m_tr_set_rot;
static Il2CppMethod *m_find_all;

static uint64_t t_start, t_pending_at, t_last_switch, t_pause_until;
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

static BOOL aim_bind(void) {
    if (!g_domain) return NO;
    if (!c_camera) c_camera = kit_find_class("Camera");
    if (!c_player_movement) c_player_movement = kit_find_class("PlayerMovement");
    if (!c_transform) c_transform = kit_find_class("Transform");
    if (!c_camera || !c_player_movement || !c_transform) return NO;

    m_cam_main = kit_method(c_camera, "get_main", 0);
    m_w2s = kit_method(c_camera, "WorldToScreenPoint", 1);
    m_pm_get_tr = kit_method(c_player_movement, "get_transform", 0);
    m_tr_get_pos = kit_method(c_transform, "get_position", 0);
    m_tr_get_rot = kit_method(c_transform, "get_rotation", 0);
    m_tr_set_rot = kit_method(c_transform, "set_rotation", 1);

    Il2CppClass *oc = kit_find_class("Object");
    if (oc && !m_find_all)
        for (int a = 1; a <= 2 && !m_find_all; a++)
            m_find_all = g_kit.class_get_method_from_name(oc, "FindObjectsOfType", a);

    ready = (m_cam_main && m_w2s && m_pm_get_tr && m_tr_get_pos && m_tr_get_rot && m_tr_set_rot && m_find_all);
    return ready;
}

static Il2CppObject *camera_object(void) {
    return m_cam_main ? kit_invoke(m_cam_main, NULL, NULL) : NULL;
}

static Il2CppObject *camera_transform(Il2CppObject *cam) {
    if (!cam) return NULL;
    Il2CppMethod *gt = kit_method(c_camera, "get_transform", 0);
    return gt ? kit_invoke(gt, cam, NULL) : NULL;
}

static Vec3 transform_position(Il2CppObject *tr) {
    Il2CppObject *p = tr ? kit_invoke(m_tr_get_pos, tr, NULL) : NULL;
    return p ? *(Vec3 *)((char *)p + 0x10) : (Vec3){0, 0, 0};
}

static Quat transform_rotation(Il2CppObject *tr) {
    Il2CppObject *q = tr ? kit_invoke(m_tr_get_rot, tr, NULL) : NULL;
    return q ? *(Quat *)((char *)q + 0x10) : (Quat){0, 0, 0, 1};
}

static void set_transform_rotation(Il2CppObject *tr, Quat q) {
    if (!tr || !m_tr_set_rot) return;
    void *args[1] = { &q };
    kit_invoke(m_tr_set_rot, tr, args);
}

// yaw/pitch -> quaternion (Unity order: yaw about Y, pitch about X)
static Quat quat_from_yaw_pitch(float yaw_deg, float pitch_deg) {
    float hy = yaw_deg * 0.5f / kDeg, hp = pitch_deg * 0.5f / kDeg;
    float sy = sinf(hy), cy = cosf(hy), sp = sinf(hp), cp = cosf(hp);
    Quat q;
    q.x = cy * sp;
    q.y = sy * cp;
    q.z = -sy * sp;
    q.w = cy * cp;
    return q;
}

static float aim_yaw, aim_pitch;

static void quat_to_yaw_pitch(Quat q, float *yaw, float *pitch) {
    // Unity forward = R * (0,0,1)
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
        if (!g_domain) { if (!kit_resolve()) return; }
        if (!ready && !aim_bind()) return;

        Il2CppObject *cam = camera_object();
        if (!cam) return;
        Il2CppObject *camTr = camera_transform(cam);
        if (!camTr) return;

        uint64_t t = now_ms();

        // scan every 400 ms; aim math runs every frame against the cached set
        static Il2CppArray *cache;
        static uint64_t lastScan;
        if (!cache || t - lastScan > 400) {
            Il2CppType *ty = g_kit.class_get_type(c_player_movement);
            Il2CppObject *typeObj = ty ? g_kit.type_get_object(ty) : NULL;
            if (typeObj) {
                int32_t inc = 0;
                void *args[2] = { typeObj, &inc };
                cache = (Il2CppArray *)kit_invoke(m_find_all, NULL, args);
            }
            lastScan = t;
        }
        if (!cache || cache->bounds.length == 0) { target = NULL; return; }

        Vec3 eye = transform_position(camTr);

        // pick the nearest player; the local one is whatever shares the camera transform
        void *best = NULL;
        float bestD2 = 1e9f;
        for (size_t i = 0; i < cache->bounds.length; i++) {
            Il2CppObject *pm = (Il2CppObject *)kit_arr_at(cache, i);
            if (!pm) continue;
            Il2CppObject *tr = kit_invoke(m_pm_get_tr, pm, NULL);
            if (!tr || tr == camTr) continue;
            Vec3 p = transform_position(tr);
            float dx = p.x - eye.x, dy = p.y - eye.y, dz = p.z - eye.z;
            float d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < bestD2) { bestD2 = d2; best = pm; }
        }
        if (!best) { target = NULL; return; }

        if (best != target) { target = best; t_pending_at = t; return; }
        if (t - t_pending_at < (uint64_t)cfg_reaction_ms) return;
        if (t_last_switch && t - t_last_switch < (uint64_t)cfg_switch_cd) return;

        Il2CppObject *tgtTr = kit_invoke(m_pm_get_tr, (Il2CppObject *)best, NULL);
        if (!tgtTr) return;
        Vec3 tp = transform_position(tgtTr);
        // head offset: stand-in until a bone accessor is confirmed
        tp.z += cfg_head_only ? 1.6f : 1.0f;

        float dx = tp.x - eye.x, dy = tp.y - eye.y, dz = tp.z - eye.z;
        float wantYaw = atan2f(dx, dz) * kDeg;
        float wantPitch = -atan2f(dy, sqrtf(dx * dx + dz * dz) + 1e-6f) * kDeg;

        float curYaw, curPitch;
        quat_to_yaw_pitch(transform_rotation(camTr), &curYaw, &curPitch);

        float dt = 1.f / 60.f;
        aim_yaw = curYaw + humanize(norm180(wantYaw - curYaw), dt);
        aim_pitch = curPitch + humanize(wantPitch - curPitch, dt);
        aim_pitch = clampf(aim_pitch, -89.f, 89.f);

        set_transform_rotation(camTr, quat_from_yaw_pitch(aim_yaw, aim_pitch));
    }
    (void)link;
}
@end

__attribute__((constructor))
static void twin_aim_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kit_resolve();
        [TwinAim start];
    });
}
