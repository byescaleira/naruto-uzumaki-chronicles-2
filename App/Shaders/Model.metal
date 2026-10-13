#include <metal_stdlib>
using namespace metal;

// 3D layer: the game's models (stages, characters) drawn into the linear HDR scene with a
// reversed-Z depth buffer. The PS2 drew them through the VU1 microcode (see re/NOTES.md,
// "3D models"); lighting here is a directional light plus ambient until the microcode's own
// lighting is recovered.

// Must match `SceneVertex` in Scene.swift (64 bytes).
struct ModelVertex {
    float4 position;
    float4 normal;
    float4 color;
    float2 uv;
    float2 padding;
};

// Must match `ModelUniforms` in Scene.swift (160 bytes).
struct ModelUniforms {
    float4x4 clipFromModel;
    float4x4 worldFromModel;
    float4 light;   // xyz towards the light (world), w ambient
    float4 flags;   // x textured, y clamp S, z clamp T, w additive
};

struct ModelOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float4 color;
};

vertex ModelOut model_vertex(uint vid [[vertex_id]],
                             const device ModelVertex* vertices [[buffer(0)]],
                             constant ModelUniforms& u [[buffer(1)]]) {
    const device ModelVertex& v = vertices[vid];
    ModelOut out;
    out.position = u.clipFromModel * v.position;
    out.normal = (u.worldFromModel * float4(v.normal.xyz, 0)).xyz;
    out.uv = v.uv;
    out.color = v.color;
    return out;
}

// The GS samples with REPEAT unless CLAMP_1 says otherwise; models carry mip chains on the GPU.
fragment half4 model_fragment(ModelOut in [[stage_in]],
                              texture2d<half> texture [[texture(0)]],
                              constant ModelUniforms& u [[buffer(1)]]) {
    constexpr sampler trilinear(filter::linear, mip_filter::linear, address::repeat);
    float2 uv = in.uv;
    if (u.flags.y > 0) uv.x = saturate(uv.x);
    if (u.flags.z > 0) uv.y = saturate(uv.y);
    float4 texel = u.flags.x > 0 ? float4(texture.sample(trilinear, uv)) : float4(1);
    float4 color = texel * in.color;
    if (u.flags.w > 0) {
        // Environment pass: Cs·As + Cd.
        return half4(half3(color.rgb * color.a), 0);
    }
    // Alpha test like the GS's TEST_1 (cut-outs: hair, leaves, fences).
    if (color.a < 0.5) discard_fragment();
    // Models without normals (stage floors) carry baked lighting in their vertex colours.
    float shade = 1;
    if (length(in.normal) > 1e-5) {
        float diffuse = abs(dot(normalize(in.normal), normalize(u.light.xyz)));
        shade = u.light.w + (1 - u.light.w) * diffuse;
    }
    return half4(half3(color.rgb * shade), 1);
}
