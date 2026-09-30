#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include "../app/rvm_math.h"

int main() {
    using namespace mattecast;
    assert(std::fabs(chooseRvmDownsampleRatio(1920,1080) - 0.25f) < 0.0001f);
    assert(std::fabs(chooseRvmDownsampleRatio(1280,720) - 0.375f) < 0.0001f);
    assert(std::fabs(chooseRvmDownsampleRatio(640,480) - 0.75f) < 0.0001f);
    assert(std::fabs(chooseRvmDownsampleRatio(320,240) - 1.0f) < 0.0001f);
    assert(clampAlpha(-1.0f) == 0.0f);
    assert(clampAlpha(2.0f) == 1.0f);
    assert(clampAlpha(0.4f) == 0.4f);
    assert(blendChannel(200, 100, 1.0f) == 200);
    assert(blendChannel(200, 100, 0.0f) == 100);
    assert(blendChannel(200, 100, 0.5f) == 150);
    assert(blurSigma(0.0f) >= 0.5);
    assert(blurSigma(1.0f) <= 25.0);
    std::cout << "RVM math tests passed\n";
}
