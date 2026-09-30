#pragma once

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>

namespace mattecast {

constexpr int kMaxCameraWidth = 1920;
constexpr int kMaxCameraHeight = 1080;
constexpr int kMaxCameraFps = 120;

enum class CommandType {
    Invalid,
    Quit,
    WindowVisible,
    WindowHidden,
    Mode,
    Blur,
    Background,
    Device,
    Resolution,
    Fps,
};

struct Command {
    CommandType type = CommandType::Invalid;
    int intValue = 0;
    float floatValue = 0.0f;
    int width = 0;
    int height = 0;
    std::string text;
};

inline bool parseIntStrict(const std::string &value, int &out) {
    if (value.empty()) return false;
    errno = 0;
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    if (errno != 0 || end == value.c_str() || *end != '\0') return false;
    if (parsed < std::numeric_limits<int>::min() ||
        parsed > std::numeric_limits<int>::max()) return false;
    out = static_cast<int>(parsed);
    return true;
}

inline bool parseFloatStrict(const std::string &value, float &out) {
    if (value.empty()) return false;
    errno = 0;
    char *end = nullptr;
    float parsed = std::strtof(value.c_str(), &end);
    if (errno != 0 || end == value.c_str() || *end != '\0' || !std::isfinite(parsed)) {
        return false;
    }
    out = parsed;
    return true;
}

inline bool isVideoDevicePath(const std::string &path,
                              const std::string &virtualDevice = "/dev/video10") {
    static const std::string prefix = "/dev/video";
    if (path.rfind(prefix, 0) != 0 || path.size() == prefix.size()) return false;
    for (size_t i = prefix.size(); i < path.size(); ++i) {
        if (path[i] < '0' || path[i] > '9') return false;
    }
    return path != virtualDevice;  // Never allow the virtual output as input.
}

inline Command parseCommand(std::string line,
                            const std::string &virtualDevice = "/dev/video10") {
    Command result;
    if (!line.empty() && line.back() == '\r') line.pop_back();

    if (line == "QUIT") {
        result.type = CommandType::Quit;
        return result;
    }
    if (line == "WINDOW:visible") {
        result.type = CommandType::WindowVisible;
        return result;
    }
    if (line == "WINDOW:hidden") {
        result.type = CommandType::WindowHidden;
        return result;
    }
    if (line.rfind("MODE:", 0) == 0) {
        int mode = 0;
        if (parseIntStrict(line.substr(5), mode) && mode >= 0 && mode <= 7) {
            result.type = CommandType::Mode;
            result.intValue = mode;
        }
        return result;
    }
    if (line.rfind("BLUR:", 0) == 0) {
        float strength = 0.0f;
        if (parseFloatStrict(line.substr(5), strength) && strength >= 0.0f && strength <= 1.0f) {
            result.type = CommandType::Blur;
            result.floatValue = strength;
        }
        return result;
    }
    if (line.rfind("BG:", 0) == 0) {
        std::string path = line.substr(3);
        if (!path.empty() && path.size() <= 4096 && path.find('\0') == std::string::npos) {
            result.type = CommandType::Background;
            result.text = std::move(path);
        }
        return result;
    }
    if (line.rfind("DEVICE:", 0) == 0) {
        std::string path = line.substr(7);
        if (isVideoDevicePath(path, virtualDevice)) {
            result.type = CommandType::Device;
            result.text = std::move(path);
        }
        return result;
    }
    if (line.rfind("RESOLUTION:", 0) == 0) {
        std::string res = line.substr(11);
        auto x = res.find('x');
        if (x == std::string::npos || x == 0 || x + 1 >= res.size() || res.find('x', x + 1) != std::string::npos) {
            return result;
        }
        int width = 0, height = 0;
        if (parseIntStrict(res.substr(0, x), width) &&
            parseIntStrict(res.substr(x + 1), height) &&
            width > 0 && height > 0 &&
            width <= kMaxCameraWidth && height <= kMaxCameraHeight) {
            result.type = CommandType::Resolution;
            result.width = width;
            result.height = height;
        }
        return result;
    }
    if (line.rfind("FPS:", 0) == 0) {
        int fps = 0;
        if (parseIntStrict(line.substr(4), fps) && fps > 0 && fps <= kMaxCameraFps) {
            result.type = CommandType::Fps;
            result.intValue = fps;
        }
        return result;
    }

    return result;
}

}  // namespace mattecast
