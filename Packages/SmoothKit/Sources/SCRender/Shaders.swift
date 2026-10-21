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
"""#
