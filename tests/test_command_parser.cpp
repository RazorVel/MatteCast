#include <cassert>
#include <cmath>
#include <iostream>
#include "../app/command_parser.h"

using mattecast::CommandType;
using mattecast::parseCommand;

int main() {
    assert(parseCommand("QUIT").type == CommandType::Quit);
    assert(parseCommand("WINDOW:visible").type == CommandType::WindowVisible);
    assert(parseCommand("WINDOW:hidden\r").type == CommandType::WindowHidden);

    auto mode = parseCommand("MODE:6");
    assert(mode.type == CommandType::Mode && mode.intValue == 6);
    assert(parseCommand("MODE:nope").type == CommandType::Invalid);
    assert(parseCommand("MODE:999").type == CommandType::Invalid);

    auto blur = parseCommand("BLUR:0.75");
    assert(blur.type == CommandType::Blur && std::fabs(blur.floatValue - 0.75f) < 0.001f);
    assert(parseCommand("BLUR:nan").type == CommandType::Invalid);
    assert(parseCommand("BLUR:1.1").type == CommandType::Invalid);

    auto dev = parseCommand("DEVICE:/dev/video2");
    assert(dev.type == CommandType::Device && dev.text == "/dev/video2");
    assert(parseCommand("DEVICE:/dev/video10").type == CommandType::Invalid);
    assert(parseCommand("DEVICE:/etc/passwd").type == CommandType::Invalid);
    assert(parseCommand("DEVICE:/dev/video11", "/dev/video11").type == CommandType::Invalid);
    assert(parseCommand("DEVICE:/dev/video10", "/dev/video11").type == CommandType::Device);

    auto res = parseCommand("RESOLUTION:1920x1080");
    assert(res.type == CommandType::Resolution && res.width == 1920 && res.height == 1080);
    assert(parseCommand("RESOLUTION:3840x2160").type == CommandType::Invalid);
    assert(parseCommand("RESOLUTION:1920xbad").type == CommandType::Invalid);
    assert(parseCommand("RESOLUTION:1920x1080x1").type == CommandType::Invalid);

    auto fps = parseCommand("FPS:60");
    assert(fps.type == CommandType::Fps && fps.intValue == 60);
    assert(parseCommand("FPS:0").type == CommandType::Invalid);
    assert(parseCommand("FPS:121").type == CommandType::Invalid);
    assert(parseCommand("FPS:30junk").type == CommandType::Invalid);

    auto bg = parseCommand("BG:/media/host/background image.jpg");
    assert(bg.type == CommandType::Background);

    std::cout << "command parser tests passed\n";
    return 0;
}
