// SDRClamp.metal
// SDRConversion.swift のカーネル。1.0 を超えた画素だけ、色相（RGB 比）を保ったまま切り詰める。
// `extern "C"` + `[[stitchable]]` の流儀は ColorGainMap.metal と同じ。

#include <CoreImage/CoreImage.h>
using namespace metal;

// sample_t はプレマルチプライ済み。切り詰めはストレート（非プレマルチ）の値で行い、戻す。
// m = max(r,g,b) が 1 以下の画素は値を一切変えない（負値＝色域外も触らない）。
extern "C" [[stitchable]] float4 jpsHueKeepClamp(coreimage::sample_t s) {
    float a = s.a;
    if (a <= 0.0) { return s; }
    float3 c = s.rgb / a;
    float m = max(c.r, max(c.g, c.b));
    if (m > 1.0) { c /= m; }
    return float4(c * a, a);
}
