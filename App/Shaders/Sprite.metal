#include <metal_stdlib>
using namespace metal;

// 2D layer: the game's sprites (menus, HUD, loading screens) composited into the linear HDR
// scene. Each instance is one GS TRIFAN quad emitted by FUN_00260a40 in SLES_550.90.

// Must match `SpriteInstance` in Sprites.swift (96 bytes).
struct SpriteInstance {
    float2 corners[4];   // top-left, top-right, bottom-right, bottom-left (game 2D space)
    float4 uv;           // s0, t0, s1, t1
    float4 clampRect;    // REGION_CLAMP as sample positions: s min, t min, s max, t max
    float4 color;        // MODULATE factor: rgb (linearised), a (1 = PS2 0x80)
    uint layer;          // texture in the atlas array
    uint3 padding;
};

// Must match `SpriteUniforms` in Sprites.swift (16 bytes).
struct SpriteUniforms {
    float2 scale;        // ndc = p * scale + offset
    float2 offset;
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 clampRect [[flat]];
    float4 color [[flat]];
    uint layer [[flat]];
};

// Four vertices per instance as a triangle strip TR, TL, BR, BL: the two triangles share the
// TL–BR diagonal like the GS TRIFAN (TL, TR, BR, BL), which matters for morphed quads.
vertex SpriteOut sprite_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device SpriteInstance* instances [[buffer(0)]],
                               constant SpriteUniforms& u [[buffer(1)]]) {
    const device SpriteInstance& s = instances[iid];
    const uint corner = vid < 2 ? 1 - vid : vid;
    const float2 st[4] = { s.uv.xy, s.uv.zy, s.uv.zw, s.uv.xw };
    SpriteOut out;
    out.position = float4(s.corners[corner] * u.scale + u.offset, 0.0, 1.0);
    out.uv = st[corner];
    out.clampRect = s.clampRect;
    out.color = s.color;
    out.layer = s.layer;
    return out;
}

// TEX1: bilinear (FUN_00260a40 forces MMAG/MMIN = LINEAR). The atlas is *_srgb, so texels
// arrive linear; the output is premultiplied so one pipeline per ALPHA_1 mode reproduces
//   0x44: Cs·As + Cd·(1 − As)     0x48: Cs·As + Cd     0x42: Cd − Cs·As
fragment half4 sprite_fragment(SpriteOut in [[stage_in]],
                               texture2d_array<half> atlas [[texture(0)]]) {
    // High-resolution atlases carry mipmaps (trilinear when drawn smaller); the game's own
    // textures have one level, so this stays the plain bilinear sample there.
    constexpr sampler bilinear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    const float2 st = clamp(in.uv, in.clampRect.xy, in.clampRect.zw);
    const half4 texel = atlas.sample(bilinear, st, in.layer);
    const float alpha = float(texel.a) * in.color.a;
    const float3 rgb = float3(texel.rgb) * in.color.rgb;
    return half4(half3(rgb * alpha), half(alpha));
}
