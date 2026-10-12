#include <metal_stdlib>
using namespace metal;

// Must match `FrameUniforms` in FrameUniforms.swift.
struct FrameUniforms {
    float2 resolution;      // drawable size in pixels
    float time;             // seconds since start (fixed 60 Hz steps)
    float sdrWhiteNits;     // nits that 1.0 maps to on PQ output
    float headroom;         // EDR headroom (max linear value) on extended-linear output
    uint outputMode;        // 0 = extended linear Display P3 (EDR), 1 = PQ BT.2100 (HDR10)
    float2 padding;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle covering the target; no vertex buffer.
vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: - Scene (placeholder until the original renderer is reimplemented)

// Linear BT.709, scene-referred: 1.0 = SDR reference white.
fragment half4 boot_scene_fragment(FullscreenOut in [[stage_in]],
                                   constant FrameUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 p = (in.uv - 0.5) * float2(aspect, 1.0);

    // Dusk sky gradient (Konoha orange to indigo).
    float3 top = float3(0.05, 0.04, 0.16);
    float3 horizon = float3(1.0, 0.36, 0.08);
    float3 color = mix(horizon, top, smoothstep(-0.15, 0.5, -p.y));

    // Rotating spiral, the Uzumaki swirl, drawn in SDR range.
    float r = length(p);
    float a = atan2(p.y, p.x);
    float spiral = sin(a * 3.0 + log(max(r, 1e-3)) * 9.0 - u.time * 2.0);
    float ring = smoothstep(0.32, 0.30, r) * smoothstep(0.08, 0.10, r);
    color = mix(color, float3(0.95, 0.42, 0.05), ring * smoothstep(0.0, 0.25, spiral));

    // HDR highlight: a sun disc well above SDR white to exercise the output transform.
    float2 sun = float2(0.55 * aspect * 0.5, -0.22);
    float d = length(p - sun);
    color += float3(1.0, 0.85, 0.6) * (smoothstep(0.06, 0.05, d) * 8.0 + exp(-d * 14.0) * 1.5);

    return half4(half3(color), 1.0h);
}

// MARK: - Output transform

constant float3x3 BT709_TO_P3 = float3x3(
    float3(0.8225, 0.0332, 0.0171),
    float3(0.1774, 0.9669, 0.0724),
    float3(0.0000, 0.0000, 0.9108));

constant float3x3 BT709_TO_BT2020 = float3x3(
    float3(0.6274, 0.0691, 0.0164),
    float3(0.3293, 0.9195, 0.0880),
    float3(0.0433, 0.0114, 0.8956));

// SMPTE ST 2084 inverse EOTF; input in units of 10 000 nits.
static float3 pq_encode(float3 y) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float3 p = pow(clamp(y, 0.0, 1.0), m1);
    return pow((c1 + c2 * p) / (1.0 + c3 * p), m2);
}

// Smooth shoulder that keeps SDR untouched and rolls highlights into [1, peak].
static float3 shoulder(float3 c, float peak) {
    float3 over = max(c - 1.0, 0.0);
    float range = max(peak - 1.0, 1e-4);
    return min(c, 1.0) + range * (1.0 - exp(-over / range));
}

fragment float4 output_fragment(FullscreenOut in [[stage_in]],
                                texture2d<half> scene [[texture(0)]],
                                constant FrameUniforms& u [[buffer(0)]]) {
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float3 c = max(float3(scene.sample(linearClamp, in.uv).rgb), 0.0);
    if (u.outputMode == 0) {
        // Extended linear Display P3: 1.0 = SDR white, values above 1.0 use EDR headroom.
        return float4(shoulder(BT709_TO_P3 * c, u.headroom), 1.0);
    }
    // PQ BT.2100 (HDR10 signal; tvOS maps it into the TV's HDR10 / Dolby Vision mode).
    float peakNits = 1000.0;
    float3 nits = shoulder(BT709_TO_BT2020 * c, peakNits / u.sdrWhiteNits) * u.sdrWhiteNits;
    return float4(pq_encode(nits / 10000.0), 1.0);
}
