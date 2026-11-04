// Core Image color kernels for Strewn's color pipeline, version 1.
// Build settings (in project.yml): OTHER_METAL_COMPILER_FLAGS = -fcikernel, MTLLINKER_FLAGS = -cikernel
//
// Every kernel here receives linear Rec.2020 (D65) values, because ColorPipeline wraps each
// call in matchedFromWorkingSpace / matchedToWorkingSpace. So the math is the same whichever
// CIContext renders it (camera preview, editor, export, Photos extension).
//
// FROZEN once a build ships: never change a *_v1 function. Add *_v2 functions and a new
// PipelineVersion instead, so photos edited with v1 keep rendering the same.
// The Swift mirror of this math is in ToneCurve.swift; keep the two in sync.
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

// MARK: Shared helpers

static inline float strewnLuma(float3 c) {
    return dot(c, float3(0.2627, 0.6780, 0.0593));          // Rec.2020 luminance weights
}

static inline float3 strewnSRGBEncode(float3 l) {
    l = clamp(l, 0.0, 1.0);
    return select(1.055 * pow(l, float3(1.0 / 2.4)) - 0.055, l * 12.92, l <= 0.0031308);
}

static inline float3 strewnSRGBDecode(float3 v) {
    v = clamp(v, 0.0, 1.0);
    return select(pow((v + 0.055) / 1.055, float3(2.4)), v / 12.92, v <= 0.04045);
}

static inline float strewnGauss(float x, float mu, float sigma) {
    float d = (x - mu) / sigma;
    return exp(-0.5 * d * d);
}

// Characteristic (H&D) curve. Stops from middle grey in, print value 0…1 out.
// Middle grey lands on 0.5; gamma is the slope; toe softens the entry into black and
// shoulder (1 = none, lower = earlier) rolls highlights off the way film does.
static inline float strewnHD(float e, float gamma, float toe, float shoulder) {
    float y = 0.5 + 0.5 * tanh(e * 0.3 * gamma);
    y = y * y / (y + toe + 1e-5) * (1.0 + toe);
    float k = 1.0 + 2.0 * (1.0 - shoulder);
    float top = 1.0 - pow(max(1.0 - y, 0.0), k);
    return mix(y, top, smoothstep(0.5, 1.0, y));
}

// MARK: Scene-referred stages (linear Rec.2020 in and out)

// Recipe light and color adjustments, all global and resolution independent.
// toneA = (contrast, highlights, shadows, whites), toneB = (blacks, saturation, vibrance, vignette),
// each -1…1. extent = (x, y, width, height) of the full frame, for the vignette.
float4 strewnSceneTone_v1(sample_t s, float4 toneA, float4 toneB, float4 extent, destination dest) {
    float3 c = s.rgb;
    float Y = strewnLuma(c);
    if (Y > 1e-6) {
        float e = log2(Y / 0.18);
        float e2 = e * (1.0 + 0.4 * toneA.x);                       // contrast around middle grey
        e2 += 1.5 * toneA.y * strewnGauss(e, 2.0, 1.2);            // highlights
        e2 += 1.5 * toneA.z * strewnGauss(e, -2.5, 1.5);           // shadows
        e2 += 1.0 * toneA.w * strewnGauss(e, 3.5, 1.0);            // whites
        e2 += 1.0 * toneB.x * strewnGauss(e, -5.0, 1.2);           // blacks
        // Vignette as an exposure falloff toward the corners (positive darkens).
        float2 centre = extent.xy + 0.5 * extent.zw;
        float r = length((dest.coord() - centre) / (0.5 * extent.zw)) / 1.41421356;
        e2 -= 1.5 * toneB.w * pow(smoothstep(0.25, 1.0, r), 1.5);
        c *= exp2(e2 - e);
        Y = strewnLuma(c);
    }
    // Saturation and vibrance around luminance, so brightness doesn't move.
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sat = mx > 1e-6 ? (mx - mn) / mx : 0.0;
    float amount = 1.0 + toneB.y + toneB.z * (1.0 - clamp(sat, 0.0, 1.0));
    c = Y + (c - Y) * max(amount, 0.0);
    return float4(c, s.a);
}

// Light that halates: the luminance above `threshold` (scene-linear), as grey.
float4 strewnHalationSource_v1(sample_t s, float threshold) {
    float over = max(strewnLuma(s.rgb) - threshold, 0.0);
    return float4(float3(over), s.a);
}

// The film. Scene-linear in (after the stock's crosstalk matrix), print values 0…1 out
// (display-encoded, Rec.2020 primaries). halo is the blurred halation source;
// halation = (tint r, g, b, amount). gamma and offset are per dye layer;
// curve = (toe, shoulder, blackLift, whitePoint).
float4 strewnFilm_v1(sample_t s, sample_t halo, float4 halation, float3 gamma, float3 offset, float4 curve) {
    float3 c = max(s.rgb + halo.rgb * halation.rgb * halation.a, float3(1e-6));
    float3 e = log2(c / 0.18) + offset;
    float3 y = float3(strewnHD(e.r, gamma.r, curve.x, curve.y),
                      strewnHD(e.g, gamma.g, curve.x, curve.y),
                      strewnHD(e.b, gamma.b, curve.x, curve.y));
    y = curve.z + (curve.w - curve.z) * clamp(y, 0.0, 1.0);
    return float4(y, s.a);
}

// MARK: Output (print values in, linear Rec.2020 out, inside Display P3)

// Adds grain in print space, weighted toward the midtones like real grain, then converts to
// linear light and compresses anything outside Display P3 toward its own luminance instead
// of clipping per channel (which shifts hue). grain = (amount, chroma, 0, 0).
float4 strewnOutput_v1(sample_t y, sample_t noise, float4 grain) {
    float3 v = y.rgb;
    float lum = strewnLuma(v);
    float weight = 4.0 * lum * (1.0 - lum);
    float3 n = float3(noise.r - 0.5) + grain.y * (noise.rgb - 0.5);
    v = clamp(v + grain.x * weight * n, 0.0, 1.0);

    float3 lin2020 = strewnSRGBDecode(v);
    float3 p3 = float3(dot(lin2020, float3( 1.343579, -0.282180, -0.061398)),
                       dot(lin2020, float3(-0.065299,  1.075787, -0.010490)),
                       dot(lin2020, float3( 0.002822, -0.019598,  1.016777)));
    float L = dot(p3, float3(0.228975, 0.691739, 0.079287));          // P3 luminance
    float mn = min(p3.r, min(p3.g, p3.b));
    if (mn < 0.0 && L > 0.0) { p3 = L + (p3 - L) * (L / (L - mn)); }
    float mx = max(p3.r, max(p3.g, p3.b));
    if (mx > 1.0 && L < 1.0) { p3 = L + (p3 - L) * ((1.0 - L) / (mx - L)); }
    p3 = clamp(p3, 0.0, 1.0);
    float3 out = float3(dot(p3, float3( 0.753833, 0.198598, 0.047569)),
                        dot(p3, float3( 0.045745, 0.941778, 0.012479)),
                        dot(p3, float3(-0.001210, 0.017601, 0.983608)));
    return float4(out, y.a);
}

// MARK: Inputs that aren't RAW

// Apple Log (BT.2020 primaries) code values to scene-linear. Constants from Apple's Apple Log
// profile, as published in colour-science. Input must be the uninterpreted buffer values.
float4 strewnAppleLogDecode_v1(sample_t s) {
    const float R0 = -0.05641088, Rt = 0.01, sigma = 47.28711236;
    const float beta = 0.00964052, gamma = 0.08550479, delta = 0.69336945;
    const float Pt = sigma * (Rt - R0) * (Rt - R0);
    float3 P = s.rgb;
    float3 hi = exp2((P - delta) / gamma) - beta;
    float3 lo = sqrt(max(P, 0.0) / sigma) + R0;
    float3 R = select(lo, hi, P >= Pt);
    R = select(R, float3(R0), P < 0.0);
    return float4(R, s.a);
}

// Approximate scene-linear from an already tone-mapped image (Apple's processed HEIF, imports,
// non-Log preview frames): undo a generic filmic curve on luminance and keep the chroma ratios.
// contrast is the slope of the curve being undone.
float4 strewnInverseDisplay_v1(sample_t s, float contrast) {
    float3 c = max(s.rgb, 0.0);
    float Yd = strewnLuma(c);
    if (Yd <= 1e-6) { return float4(0.0, 0.0, 0.0, s.a); }
    float v = strewnSRGBEncode(float3(Yd)).x;
    float t = clamp(2.0 * v - 1.0, -0.995, 0.995);
    float e = 0.5 * log((1.0 + t) / (1.0 - t)) / (0.3 * contrast);    // atanh
    float Ys = 0.18 * exp2(e);
    return float4(c * (Ys / Yd), s.a);
}

// Per-channel correction learned by PreviewCalibrator: k0…k6 are stops to add at
// -6, -4, -2, 0, +2, +4, +6 stops from middle grey (r, g, b each), linearly interpolated.
float4 strewnPreviewCorrect_v1(sample_t s, float3 k0, float3 k1, float3 k2, float3 k3, float3 k4, float3 k5, float3 k6) {
    float3 c = max(s.rgb, float3(1e-6));
    float3 e = log2(c / 0.18);
    float3 t = clamp((e + 6.0) / 2.0, 0.0, 5.999);
    float3 lo = floor(t);
    float3 f = t - lo;
    float3 out;
    for (int ch = 0; ch < 3; ch++) {
        float kv[7] = { k0[ch], k1[ch], k2[ch], k3[ch], k4[ch], k5[ch], k6[ch] };
        int i = int(lo[ch]);
        out[ch] = c[ch] * exp2(mix(kv[i], kv[i + 1], f[ch]));
    }
    return float4(out, s.a);
}

// MARK: Metering and LUT helpers

// Centre-weighted log-average metering: outputs (w·stops, w) per pixel; CIAreaAverage of this
// gives the weighted mean stops from middle grey as r / g.
float4 strewnMeter_v1(sample_t s, float4 extent, destination dest) {
    float Y = max(strewnLuma(s.rgb), 1e-6);
    float e = clamp(log2(Y / 0.18), -10.0, 6.0);
    float2 centre = extent.xy + 0.5 * extent.zw;
    float2 d = (dest.coord() - centre) / (0.5 * extent.zw);
    float w = 0.25 + exp(-dot(d, d) / (2.0 * 0.35 * 0.35));
    return float4(w * e, w, 0.0, 1.0);
}

// Scene-linear ↔ log 0…1 covering 0.18·2^-8 … 0.18·2^+6, for 3D LUTs built offline.
float4 strewnLogEncode_v1(sample_t s) {
    float3 x = max(s.rgb, float3(1e-5));
    return float4(clamp((log2(x / 0.18) + 8.0) / 14.0, 0.0, 1.0), s.a);
}

float4 strewnLogDecode_v1(sample_t s) {
    return float4(0.18 * exp2(s.rgb * 14.0 - 8.0), s.a);
}

}
}
