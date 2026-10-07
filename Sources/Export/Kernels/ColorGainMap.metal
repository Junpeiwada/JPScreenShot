// ColorGainMap.metal
// ColorGainMap.swift のカーネル（Metal Shading Language）。HDRForge の同名ファイルから移植。
// 各カーネルの意味と引数の作り方は Swift 側を参照。
//
// - `extern "C"` で名前修飾を止める（Swift 側は MetalKernelLibrary に関数名そのもので渡す）。
// - `[[stitchable]]` にする。
// - 座標が要るカーネルは無い。

#include <CoreImage/CoreImage.h>
using namespace metal;

// ---- templateKernel（ColorGainMap.swift）----
extern "C" [[stitchable]] float4 gainforgeTemplate(coreimage::sample_t s, float m) {
    float l = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(s.rgb * (1.0 + (m - 1.0) * smoothstep(0.05, 0.20, l)), s.a);
}

// ---- logGainKernel（ColorGainMap.swift）----
extern "C" [[stitchable]] float4 gainforgeLogGain(coreimage::sample_t b, coreimage::sample_t a, float offset, float invScale) {
    float3 base = max(b.rgb, 0.0) + float3(offset);
    float3 alt  = max(a.rgb, 0.0) + float3(offset);
    float3 g = max(log2(alt / base), float3(0.0)) * invScale;
    return float4(clamp(g, 0.0, 1.0), 1.0);
}

// ---- gainMapKernel（ColorGainMap.swift）----
extern "C" [[stitchable]] float4 gainforgeGainMap(coreimage::sample_t b, coreimage::sample_t a, float invMax, float offset) {
    float3 base = max(b.rgb, 0.0) + float3(offset);
    float3 alt  = max(a.rgb, 0.0) + float3(offset);
    float3 g = log2(alt / base) * invMax;
    return float4(clamp(g, 0.0, 1.0), 1.0);
}
