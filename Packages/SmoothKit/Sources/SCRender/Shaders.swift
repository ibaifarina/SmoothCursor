// Metal source compiled at runtime (once per process) so the package builds with plain `swift build`
// as well as Xcode. All uniform structs consist only of float4s, mirrored on the Swift side as
// flat `[SIMD4<Float>]` arrays in the same order.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4 camera;   // xy view origin (canvas px), z canvas→output scale
    float4 sizes;    // xy output size, zw canvas size
};

struct VOut {
    float4 position [[position]];
    float2 canvas;
};

// Triangle strip over `rect` (canvas space), transformed by the camera.
vertex VOut quad_vertex(uint vid [[vertex_id]],
                        constant FrameUniforms &frame [[buffer(0)]],
                        constant float4 &rect [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    float2 canvas = rect.xy + corner * rect.zw;
    float2 px = (canvas - frame.camera.xy) * frame.camera.z;
    VOut out;
    out.position = float4(px.x / frame.sizes.x * 2.0 - 1.0, 1.0 - px.y / frame.sizes.y * 2.0, 0.0, 1.0);
    out.canvas = canvas;
    return out;
}

// MARK: - Helpers

static float3 srgb_to_linear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float sd_rounded_box(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// MARK: - Background

struct BackgroundUniforms {
    float4 params;          // x kind (0 color, 1 linear, 2 radial, 3 angular, 4 mesh, 5 image), y angle rad, z stops, w grain
    float4 center;          // xy unit center
    float4 colors[8];       // sRGB
    float4 locations[2];
    float4 mesh[9];         // sRGB, row-major 3×3
    float4 imageTransform;  // uv = unit * xy + zw (aspect fill)
};

static float3 stops_color(constant BackgroundUniforms &b, float t) {
    int count = int(b.params.z);
    t = saturate(t);
    float3 c = b.colors[0].rgb;
    for (int i = 1; i < count; i++) {
        float l0 = b.locations[(i - 1) / 4][(i - 1) % 4];
        float l1 = b.locations[i / 4][i % 4];
        if (t >= l0) {
            float f = l1 > l0 ? saturate((t - l0) / (l1 - l0)) : 1.0;
            c = mix(b.colors[i - 1].rgb, b.colors[i].rgb, f);
        }
    }
    return c;
}

fragment float4 background_fragment(VOut in [[stage_in]],
                                    constant FrameUniforms &frame [[buffer(0)]],
                                    constant BackgroundUniforms &b [[buffer(1)]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
    float2 canvasSize = frame.sizes.zw;
    float2 p = in.canvas;
    float2 unit = p / canvasSize;
    int kind = int(b.params.x);
    float3 color;
    if (kind == 5) {
        color = image.sample(smp, unit * b.imageTransform.xy + b.imageTransform.zw).rgb;
    } else {
        float3 srgb;
        if (kind == 0) {
            srgb = b.colors[0].rgb;
        } else if (kind == 1) {
            float2 dir = float2(cos(b.params.y), sin(b.params.y));
            float halfLen = 0.5 * (abs(canvasSize.x * dir.x) + abs(canvasSize.y * dir.y));
            srgb = stops_color(b, 0.5 + dot(p - canvasSize * 0.5, dir) / (2.0 * halfLen));
        } else if (kind == 2) {
            float2 c = b.center.xy * canvasSize;
            float2 far = max(c, canvasSize - c);
            srgb = stops_color(b, length(p - c) / length(far));
        } else if (kind == 3) {
            float2 d = p - b.center.xy * canvasSize;
            srgb = stops_color(b, fract((atan2(d.y, d.x) - b.params.y) / (2.0 * M_PI_F)));
        } else {
            float2 g = saturate(unit) * 2.0;
            float2 cell = min(floor(g), float2(1.0));
            float2 f = smoothstep(0.0, 1.0, g - cell);
            int x = int(cell.x), y = int(cell.y);
            float3 top = mix(b.mesh[y * 3 + x].rgb, b.mesh[y * 3 + x + 1].rgb, f.x);
            float3 bottom = mix(b.mesh[(y + 1) * 3 + x].rgb, b.mesh[(y + 1) * 3 + x + 1].rgb, f.x);
            srgb = mix(top, bottom, f.y);
        }
        // ±½ LSB dither in display space: no banding in 8-bit output.
        srgb += (hash12(in.position.xy) - 0.5) / 255.0;
        color = srgb_to_linear(saturate(srgb));
    }
    if (b.params.w > 0.0) {
        float n = hash12(floor(in.position.xy) + 17.0) - 0.5;
        color = max(color + n * b.params.w * 0.12, 0.0);
    }
    return float4(color, 1.0);
}

// MARK: - Shadow
// Gaussian-blurred rounded rectangle in closed form (Evan Wallace): no blur pass, any size.

static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.50662827463 * sigma);
}

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float shadow_x(float x, float y, float sigma, float corner, float2 halfSize) {
    float delta = min(halfSize.y - corner - abs(y), 0.0);
    float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

static float rounded_box_shadow(float2 lower, float2 upper, float2 point, float sigma, float corner) {
    float2 center = (lower + upper) * 0.5;
    float2 halfSize = (upper - lower) * 0.5;
    point -= center;
    float low = point.y - halfSize.y;
    float high = point.y + halfSize.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float value = 0.0;
    for (int i = 0; i < 4; i++) {
        value += shadow_x(point.x, point.y - y, sigma, corner, halfSize) * gaussian(y, sigma) * step;
        y += step;
    }
    return value;
}

struct ShadowUniforms {
    float4 rect;    // casting rect (canvas)
    float4 params;  // x sigma, y corner radius, z opacity
};

fragment float4 shadow_fragment(VOut in [[stage_in]], constant ShadowUniforms &s [[buffer(1)]]) {
    float value = rounded_box_shadow(s.rect.xy, s.rect.xy + s.rect.zw, in.canvas, s.params.x, s.params.y);
    return float4(0.0, 0.0, 0.0, saturate(value) * s.params.z);
}

// MARK: - Screen

struct ScreenUniforms {
    float4 rect;    // canvas rect
    float4 crop;    // uv origin, uv size
    float4 params;  // x corner radius, y filter (0 bilinear, 1 trilinear, 2 bicubic), zw texture size
};

// 9-tap Catmull-Rom using bilinear taps (MJP). Sharper than bilinear when magnifying.
static float3 sample_catmull_rom(texture2d<float> tex, sampler smp, float2 uv, float2 texSize) {
    float2 samplePos = uv * texSize;
    float2 texPos1 = floor(samplePos - 0.5) + 0.5;
    float2 f = samplePos - texPos1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 offset12 = w2 / w12;
    float2 p0 = (texPos1 - 1.0) / texSize;
    float2 p3 = (texPos1 + 2.0) / texSize;
    float2 p12 = (texPos1 + offset12) / texSize;
    float3 r = 0.0;
    r += tex.sample(smp, float2(p0.x,  p0.y),  level(0)).rgb * w0.x  * w0.y;
    r += tex.sample(smp, float2(p12.x, p0.y),  level(0)).rgb * w12.x * w0.y;
    r += tex.sample(smp, float2(p3.x,  p0.y),  level(0)).rgb * w3.x  * w0.y;
    r += tex.sample(smp, float2(p0.x,  p12.y), level(0)).rgb * w0.x  * w12.y;
    r += tex.sample(smp, float2(p12.x, p12.y), level(0)).rgb * w12.x * w12.y;
    r += tex.sample(smp, float2(p3.x,  p12.y), level(0)).rgb * w3.x  * w12.y;
    r += tex.sample(smp, float2(p0.x,  p3.y),  level(0)).rgb * w0.x  * w3.y;
    r += tex.sample(smp, float2(p12.x, p3.y),  level(0)).rgb * w12.x * w3.y;
    r += tex.sample(smp, float2(p3.x,  p3.y),  level(0)).rgb * w3.x  * w3.y;
    return max(r, 0.0);
}

fragment float4 screen_fragment(VOut in [[stage_in]],
                                constant FrameUniforms &frame [[buffer(0)]],
                                constant ScreenUniforms &s [[buffer(1)]],
                                texture2d<float> tex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    float2 halfSize = s.rect.zw * 0.5;
    float d = sd_rounded_box(in.canvas - (s.rect.xy + halfSize), halfSize, s.params.x);
    // One output pixel of anti-aliasing regardless of zoom.
    float alpha = saturate(0.5 - d * frame.camera.z);
    if (alpha <= 0.0) discard_fragment();
    float2 uv = s.crop.xy + (in.canvas - s.rect.xy) / s.rect.zw * s.crop.zw;
    float3 rgb = s.params.y > 1.5 ? sample_catmull_rom(tex, smp, uv, s.params.zw) : tex.sample(smp, uv).rgb;
    return float4(rgb * alpha, alpha);
}
// MARK: - Cursor

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
};

// Quad from explicit corners (canvas): corners[0] = TL.xy, TR.xy; corners[1] = BL.xy, BR.xy.
vertex SpriteOut corners_vertex(uint vid [[vertex_id]],
                                constant FrameUniforms &frame [[buffer(0)]],
                                constant float4 *corners [[buffer(1)]]) {
    float2 c[4] = { corners[0].xy, corners[0].zw, corners[1].xy, corners[1].zw };
    float2 uvs[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 px = (c[vid] - frame.camera.xy) * frame.camera.z;
    SpriteOut out;
    out.position = float4(px.x / frame.sizes.x * 2.0 - 1.0, 1.0 - px.y / frame.sizes.y * 2.0, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// Texture is premultiplied linear (rgba16Float). params: x opacity, y shadow mode, z shadow blur (mip bias), w shadow strength.
fragment float4 cursor_fragment(SpriteOut in [[stage_in]],
                                constant float4 &params [[buffer(1)]],
                                texture2d<float> tex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    if (params.y > 0.5) {
        float a = tex.sample(smp, in.uv, bias(params.z)).a;
        return float4(0.0, 0.0, 0.0, a * params.x * params.w);
    }
    return tex.sample(smp, in.uv) * params.x;
}

// MARK: - Click effects

struct EffectUniforms {
    float4 geometry; // xy center, z radius, w ring thickness (0 = filled disk)
    float4 color;    // linear rgb, alpha
};

fragment float4 effect_fragment(VOut in [[stage_in]],
                                constant FrameUniforms &frame [[buffer(0)]],
                                constant EffectUniforms &e [[buffer(1)]]) {
    float d = length(in.canvas - e.geometry.xy);
    float px = 0.75 / frame.camera.z;
    float coverage;
    if (e.geometry.w > 0.0) {
        float half_t = e.geometry.w * 0.5;
        coverage = 1.0 - smoothstep(half_t - px, half_t + px, abs(d - e.geometry.z));
    } else {
        coverage = 1.0 - smoothstep(e.geometry.z - px, e.geometry.z + px, d);
    }
    float a = coverage * e.color.a;
    return float4(e.color.rgb * a, a);
}
// MARK: - Motion blur

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
    FullscreenOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

struct BlurUniforms {
    float4 now;    // xy view origin (canvas), z px per canvas unit
    float4 from;   // camera at shutter open
    float4 to;     // camera at shutter close
    float4 params; // x taps, zw target size
};

// Averages the scene along each pixel's path over the shutter. The camera is a pure zoom+pan, so
// where canvas content seen at pixel p at time τ sits in the current frame is exact:
// q(τ) = (origin_τ + p / scale_τ − origin_now) · scale_now.
fragment float4 motion_blur_fragment(FullscreenOut in [[stage_in]],
                                     constant BlurUniforms &u [[buffer(0)]],
                                     texture2d<float> scene [[texture(0)]],
                                     sampler smp [[sampler(0)]]) {
    float2 size = u.params.zw;
    float2 p = in.uv * size;
    float2 qa = (u.from.xy + p / u.from.z - u.now.xy) * u.now.z;
    float2 qb = (u.to.xy + p / u.to.z - u.now.xy) * u.now.z;
    float dist = distance(qa, qb);
    if (dist < 0.75) return scene.sample(smp, in.uv);
    // Only as many samples as this pixel's motion needs (~1.5 px apart).
    int taps = clamp(int(dist / 1.5), 3, int(u.params.x));
    float4 sum = 0.0;
    // Per-pixel jitter turns residual stepping into fine noise.
    float jitter = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    for (int i = 0; i < taps; i++) {
        float t = (float(i) + 0.5 + jitter) / float(taps);
        sum += scene.sample(smp, mix(qa, qb, t) / size);
    }
    return sum / float(taps);
}

// Premultiplied layer (e.g. the accumulated cursor) composited over the target.
fragment float4 layer_fragment(FullscreenOut in [[stage_in]],
                               texture2d<float> layer [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    return layer.sample(smp, in.uv);
}
// MARK: - Mockup: environment

constant float PI_F = 3.14159265358979;

static float2 equirect_uv(float3 d) {
    return float2(0.5 + atan2(d.x, -d.z) / (2.0 * PI_F), acos(clamp(d.y, -1.0, 1.0)) / PI_F);
}

static float3 equirect_dir(float2 uv) {
    float phi = (uv.x - 0.5) * 2.0 * PI_F, theta = uv.y * PI_F;
    return float3(sin(theta) * sin(phi), cos(theta), -sin(theta) * cos(phi));
}

static float2 hammersley(uint i, uint n) {
    uint bits = (i << 16u) | (i >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float2(float(i) / float(n), float(bits) * 2.3283064365386963e-10);
}

// GGX importance-sampled prefilter (N = V = R), with filtered importance sampling to avoid fireflies.
fragment float4 prefilter_fragment(FullscreenOut in [[stage_in]],
                                   constant float4 &p [[buffer(0)]],
                                   texture2d<float> src [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
    float roughness = p.x;
    float3 N = equirect_dir(in.uv);
    float a = roughness * roughness;
    float3 up = abs(N.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 T = normalize(cross(up, N)), B = cross(N, T);
    float texelSolidAngle = 4.0 * PI_F / (p.y * p.z);
    const uint count = 160;
    float3 sum = 0.0;
    float weight = 0.0;
    for (uint i = 0; i < count; i++) {
        float2 xi = hammersley(i, count);
        float phi = 2.0 * PI_F * xi.x;
        float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
        float3 H = normalize(T * (sinTheta * cos(phi)) + B * (sinTheta * sin(phi)) + N * cosTheta);
        float3 L = 2.0 * dot(N, H) * H - N;
        float NoL = dot(N, L);
        if (NoL <= 0.0) continue;
        float NoH = saturate(dot(N, H));
        float d = (NoH * NoH * (a * a - 1.0) + 1.0);
        float D = a * a / (PI_F * d * d);
        float pdf = D * 0.25 + 1e-4;
        float lod = max(0.5 * log2((1.0 / (float(count) * pdf)) / texelSolidAngle) + 1.0, 0.0);
        sum += src.sample(smp, equirect_uv(L), level(lod)).rgb * NoL;
        weight += NoL;
    }
    return float4(sum / max(weight, 1e-4), 1.0);
}

// MARK: - Mockup: phone

struct PhoneVertex {
    float4 position; // w = material
    float4 normal;
    float4 uv;       // xy = model-space face coordinates (mm)
};

struct MockupUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 cameraPos;
    float4 env;        // x yaw, y pitch (rad), z strength, w max lod
    float4 screen;     // x half w, y half h, z corner radius, w landscape
    float4 island;     // x center y, y half w, z half h
    float4 plateau;    // xy center, z size
    float4 frameColor; // linear rgb, w roughness
    float4 backColor;  // linear rgb, w roughness
    float4 misc;       // x screen reflection, y floor y
};

struct PhoneOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 face;
    float material [[flat]];
};

vertex PhoneOut phone_vertex(uint vid [[vertex_id]],
                             const device PhoneVertex *vertices [[buffer(0)]],
                             constant MockupUniforms &u [[buffer(1)]]) {
    PhoneVertex v = vertices[vid];
    float4 world = u.model * float4(v.position.xyz, 1.0);
    PhoneOut out;
    out.position = u.viewProj * world;
    out.world = world.xyz;
    out.normal = (u.model * float4(v.normal.xyz, 0.0)).xyz;
    out.face = v.uv.xy;
    out.material = v.position.w;
    return out;
}

static float3 rotate_env(float3 d, float yaw, float pitch) {
    float cp = cos(-pitch), sp = sin(-pitch);
    d = float3(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
    float cy = cos(-yaw), sy = sin(-yaw);
    return float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
}

static float3 sample_env(texture2d<float> env, sampler smp, constant MockupUniforms &u, float3 dir, float roughness) {
    float3 d = rotate_env(normalize(dir), u.env.x, u.env.y);
    return env.sample(smp, equirect_uv(d), level(roughness * u.env.w)).rgb * u.env.z;
}

// Karis' analytic approximation of the split-sum BRDF lookup.
static float2 env_brdf(float roughness, float NoV) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

static float3 aces(float3 x) {
    return saturate(x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14));
}

static float3 shade(float3 N, float3 V, float3 albedo, float metallic, float roughness,
                    texture2d<float> env, sampler smp, constant MockupUniforms &u, thread float3 &specularOut) {
    float NoV = saturate(dot(N, V));
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float2 ab = env_brdf(roughness, NoV);
    float3 specular = sample_env(env, smp, u, reflect(-V, N), roughness) * (F0 * ab.x + ab.y);
    float3 diffuse = sample_env(env, smp, u, N, 1.0) * albedo * (1.0 - metallic);
    specularOut = specular;
    return diffuse + specular;
}

static float coverage(float d) {
    float w = max(fwidth(d), 1e-4);
    return 1.0 - smoothstep(-w, w, d);
}

fragment float4 phone_fragment(PhoneOut in [[stage_in]],
                               constant MockupUniforms &u [[buffer(1)]],
                               texture2d<float> env [[texture(0)]],
                               texture2d<float> screen [[texture(1)]],
                               sampler envSampler [[sampler(0)]],
                               sampler screenSampler [[sampler(1)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(u.cameraPos.xyz - in.world);
    if (dot(N, V) < 0.0) N = -N;
    int material = int(in.material + 0.5);
    float3 specular;

    if (material == 0) {
        return float4(aces(shade(N, V, u.frameColor.rgb, 1.0, u.frameColor.w, env, envSampler, u, specular)), 1.0);
    }
    if (material == 1) {
        return float4(aces(shade(N, V, u.backColor.rgb, 0.0, u.backColor.w, env, envSampler, u, specular)), 1.0);
    }
    if (material == 4) {
        // Camera plateau: glossy glass with three lenses, flash and sensor.
        float2 p = in.face - u.plateau.xy;
        float s = u.plateau.z;
        float2 lenses[3] = { float2(-0.22, 0.22) * s, float2(-0.22, -0.22) * s, float2(0.22, 0.0) * s };
        float ring = 0.0, glass = 0.0;
        for (int i = 0; i < 3; i++) {
            float d = length(p - lenses[i]);
            ring = max(ring, coverage(d - 0.19 * s));
            glass = max(glass, coverage(d - 0.145 * s));
        }
        float flash = coverage(length(p - float2(0.23, 0.28) * s) - 0.045 * s);
        float sensor = coverage(length(p - float2(0.23, -0.28) * s) - 0.04 * s);
        float3 base = shade(N, V, u.backColor.rgb, 0.0, 0.18, env, envSampler, u, specular);
        float3 metal = shade(N, V, u.frameColor.rgb, 1.0, 0.18, env, envSampler, u, specular);
        float3 lens = shade(N, V, float3(0.004, 0.006, 0.012), 0.0, 0.03, env, envSampler, u, specular) + float3(0.002, 0.004, 0.01);
        float3 flashColor = shade(N, V, float3(0.85, 0.78, 0.6), 0.0, 0.25, env, envSampler, u, specular);
        float3 c = mix(base, metal, ring);
        c = mix(c, lens, glass);
        c = mix(c, flashColor, flash);
        c = mix(c, float3(0.01), sensor);
        return float4(aces(c), 1.0);
    }

    // Front: glass over bezel, screen and Dynamic Island.
    float2 p = in.face;
    float screenMask = coverage(sd_rounded_box(p, u.screen.xy, u.screen.z));
    float2 islandHalf = u.island.yz;
    float islandMask = u.island.y > 0.0 ? coverage(sd_rounded_box(p - float2(0.0, u.island.x), islandHalf, islandHalf.y)) : 0.0;
    float2 uv = u.screen.w > 0.5
        ? float2((u.screen.y - p.y) / (2.0 * u.screen.y), (u.screen.x - p.x) / (2.0 * u.screen.x))
        : float2((p.x + u.screen.x) / (2.0 * u.screen.x), (u.screen.y - p.y) / (2.0 * u.screen.y));
    float3 content = screen.sample(screenSampler, uv).rgb;
    float3 glass = shade(N, V, float3(0.008), 0.0, 0.035, env, envSampler, u, specular);
    float3 bezel = aces(glass);
    float3 lit = content + aces(specular) * u.misc.x;
    float visible = screenMask * (1.0 - islandMask);
    return float4(mix(bezel, lit, visible), 1.0);
}

// MARK: - Mockup: shadow

// The phone flattened onto the floor plane along the light direction.
vertex float4 shadow_vertex(uint vid [[vertex_id]],
                            const device PhoneVertex *vertices [[buffer(0)]],
                            constant MockupUniforms &u [[buffer(1)]],
                            constant float4 &light [[buffer(2)]]) {
    float4 world = u.model * float4(vertices[vid].position.xyz, 1.0);
    float floorY = u.misc.y;
    float t = (world.y - floorY) / max(-light.y, 1e-3);
    float3 p = world.xyz + light.xyz * t;
    p.y = floorY;
    return u.viewProj * float4(p, 1.0);
}

fragment float4 shadow_mask_fragment() {
    return float4(1.0);
}

// Two blurred masks (soft cast shadow + tight contact shadow) darken what's behind.
fragment float4 shadow_composite_fragment(FullscreenOut in [[stage_in]],
                                          constant float4 &p [[buffer(0)]],
                                          texture2d<float> soft [[texture(0)]],
                                          texture2d<float> contact [[texture(1)]],
                                          sampler smp [[sampler(0)]]) {
    float a = saturate(soft.sample(smp, in.uv).r * p.x + contact.sample(smp, in.uv).r * p.y);
    return float4(0.0, 0.0, 0.0, a);
}

// Adds a premultiplied layer scaled by a weight (sub-frame averaging).
fragment float4 accumulate_fragment(FullscreenOut in [[stage_in]],
                                    constant float4 &w [[buffer(0)]],
                                    texture2d<float> layer [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
    return layer.sample(smp, in.uv) * w.x;
}
"""#
