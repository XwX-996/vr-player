#include <metal_stdlib>
using namespace metal;

struct SphereVertex {
    float3 position;
    float2 textureCoordinate;
};

struct SphereUniforms {
    float4x4 modelViewProjection;
    uint eyeIndex;
    uint stereoLayout;
};

struct SphereVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex SphereVertexOut sphereVertex(
    uint vertexID [[vertex_id]],
    const device SphereVertex *vertices [[buffer(0)]],
    constant SphereUniforms &uniforms [[buffer(1)]]) {
    SphereVertexOut output;
    SphereVertex input = vertices[vertexID];
    output.position = uniforms.modelViewProjection * float4(input.position, 1.0);
    float u = input.textureCoordinate.x;
    if (uniforms.stereoLayout == 1) {
        u = u * 0.5 + float(uniforms.eyeIndex) * 0.5;
    }
    output.textureCoordinate = float2(u, input.textureCoordinate.y);
    return output;
}

fragment half4 yuvFragment(
    SphereVertexOut input [[stage_in]],
    texture2d<half> lumaTexture [[texture(0)]],
    texture2d<half> chromaTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half y = lumaTexture.sample(textureSampler, input.textureCoordinate).r - half(16.0 / 255.0);
    half2 cbcr = chromaTexture.sample(textureSampler, input.textureCoordinate).rg - half2(0.5, 0.5);
    half3 rgb;
    rgb.r = half(1.164) * y + half(1.793) * cbcr.y;
    rgb.g = half(1.164) * y - half(0.213) * cbcr.x - half(0.533) * cbcr.y;
    rgb.b = half(1.164) * y + half(2.112) * cbcr.x;
    return half4(saturate(rgb), 1.0);
}

struct HUDVertex {
    float3 position;
    float2 textureCoordinate;
};

struct HUDUniforms {
    float4x4 modelViewProjection;
};

struct HUDVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex HUDVertexOut hudVertex(
    uint vertexID [[vertex_id]],
    const device HUDVertex *vertices [[buffer(0)]],
    constant HUDUniforms &uniforms [[buffer(1)]]) {
    HUDVertexOut output;
    HUDVertex input = vertices[vertexID];
    output.position = uniforms.modelViewProjection * float4(input.position, 1.0);
    output.textureCoordinate = input.textureCoordinate;
    return output;
}

fragment half4 hudFragment(
    HUDVertexOut input [[stage_in]],
    texture2d<half> hudTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return hudTexture.sample(textureSampler, input.textureCoordinate);
}

struct ReticleUniforms {
    float2 ndcScale;
    float progress;
    uint active;
};

struct ReticleVertexOut {
    float4 position [[position]];
    float2 coordinate;
};

vertex ReticleVertexOut reticleVertex(
    uint vertexID [[vertex_id]],
    constant ReticleUniforms &uniforms [[buffer(0)]]) {
    const float2 positions[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    const float2 coordinates[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    ReticleVertexOut output;
    output.position = float4(positions[vertexID] * uniforms.ndcScale, 0, 1);
    output.coordinate = coordinates[vertexID];
    return output;
}

fragment half4 reticleFragment(
    ReticleVertexOut input [[stage_in]],
    constant ReticleUniforms &uniforms [[buffer(0)]]) {
    float2 centered = input.coordinate * 2.0 - 1.0;
    float radius = length(centered);
    if (radius < 0.13) {
        return half4(1, 1, 1, 0.96);
    }
    if (radius < 0.70 && radius > 0.54) {
        float alpha = 0.38;
        if (uniforms.active != 0) {
            float angle = atan2(centered.y, centered.x) + M_PI_F;
            float normalized = angle / (2.0 * M_PI_F);
            alpha = normalized <= uniforms.progress ? 0.98 : 0.26;
        }
        return half4(1, 1, 1, half(alpha));
    }
    return half4(0, 0, 0, 0);
}

struct FullScreenVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex FullScreenVertexOut fullScreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    const float2 coordinates[3] = { float2(0, 1), float2(2, 1), float2(0, -1) };
    FullScreenVertexOut output;
    output.position = float4(positions[vertexID], 0, 1);
    output.textureCoordinate = coordinates[vertexID];
    return output;
}

struct DistortionUniforms {
    float k1;
    float k2;
    float horizontalInset;
    float verticalInset;
};

fragment half4 distortionFragment(
    FullScreenVertexOut input [[stage_in]],
    texture2d<half> eyeTexture [[texture(0)]],
    constant DistortionUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float eye = input.textureCoordinate.x >= 0.5 ? 1.0 : 0.0;
    float localU = input.textureCoordinate.x * 2.0 - eye;
    float2 local = float2(localU, input.textureCoordinate.y) * 2.0 - 1.0;
    local.x /= max(1.0 - uniforms.horizontalInset, 0.01);
    local.y /= max(1.0 - uniforms.verticalInset, 0.01);
    float radiusSquared = dot(local, local);
    float factor = 1.0 + uniforms.k1 * radiusSquared + uniforms.k2 * radiusSquared * radiusSquared;
    float2 sampledLocal = local * factor;
    if (abs(sampledLocal.x) > 1.0 || abs(sampledLocal.y) > 1.0) {
        return half4(0, 0, 0, 1);
    }
    float2 sampled = sampledLocal * 0.5 + 0.5;
    sampled.x = sampled.x * 0.5 + eye * 0.5;
    return eyeTexture.sample(textureSampler, sampled);
}
