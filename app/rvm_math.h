#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace mattecast {

inline float chooseRvmDownsampleRatio(int width, int height) {
    const int longest = std::max(width, height);
    if (longest <= 0) return 1.0f;
    // RVM recommends keeping the low-resolution stage roughly 256-512 px.
    // Target 480 px for webcam/portrait framing: 1280 -> .375, 1920 -> .25.
    return std::clamp(480.0f / static_cast<float>(longest), 0.25f, 1.0f);
}

inline float clampAlpha(float alpha) {
    if (!std::isfinite(alpha)) return 0.0f;
    return std::clamp(alpha, 0.0f, 1.0f);
}

inline std::uint8_t blendChannel(std::uint8_t foreground,
                                 std::uint8_t background,
                                 float alpha) {
    const float a = clampAlpha(alpha);
    const float value = static_cast<float>(foreground) * a +
                        static_cast<float>(background) * (1.0f - a);
    return static_cast<std::uint8_t>(std::clamp(std::lround(value), 0L, 255L));
}

inline double blurSigma(float strength) {
    const float s = std::clamp(strength, 0.0f, 1.0f);
    return 0.5 + static_cast<double>(s) * 24.5;
}

}  // namespace mattecast
