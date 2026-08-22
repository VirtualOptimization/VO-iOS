#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 외곽선 전용 글로우: 내부 투명 구멍(원 등)에는 글로우를 적용하지 않음.
// 원리: 투명 픽셀 주변의 불투명 픽셀들이 한 방향에 몰려있으면 외부(→ 글로우),
//        사방에서 둘러싸여 있으면 내부 구멍(→ 글로우 없음).
[[stitchable]] half4 outerGlow(
    float2 position,
    SwiftUI::Layer layer,
    float intensity,
    float radius,
    half4 color
) {
    half4 original = layer.sample(position);

    // 불투명 픽셀은 원본 그대로 반환
    if (original.a > 0.5h) {
        return original;
    }

    int iRadius = int(radius);
    float2 directionSum = float2(0.0, 0.0);
    float weightSum    = 0.0;
    float nearestDist  = radius + 1.0;

    for (int dy = -iRadius; dy <= iRadius; dy++) {
        for (int dx = -iRadius; dx <= iRadius; dx++) {
            float2 offset = float2(float(dx), float(dy));
            float  dist   = length(offset);
            if (dist < 0.5 || dist > radius) { continue; }

            half4 s = layer.sample(position + offset);
            if (s.a > 0.5h) {
                float w = float(s.a);
                directionSum += normalize(offset) * w;
                weightSum    += w;
                nearestDist   = min(nearestDist, dist);
            }
        }
    }

    if (weightSum < 0.01) {
        return half4(0.0h);
    }

    // 방향성 지수: 외부 픽셀 → 한쪽 방향에 몰림(크다), 내부 구멍 → 사방 균형(작다)
    float dirMag = length(directionSum) / weightSum;
    if (dirMag < 0.28) {
        return half4(0.0h); // 내부 구멍 → 글로우 없음
    }

    float t         = 1.0 - (nearestDist / radius);
    float glowAlpha = t * t * intensity * min(dirMag * 1.6, 1.0);

    return half4(color.rgb * half(glowAlpha), half(glowAlpha));
}
