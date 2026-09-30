#include <cassert>
#include <cstdint>
#include <iostream>
#include <random>
#include <string>
#include "../app/command_parser.h"

int main() {
    std::mt19937 rng(0xB10CA57u);
    std::uniform_int_distribution<int> len_dist(0, 512);
    std::uniform_int_distribution<int> byte_dist(1, 126);

    for (int i = 0; i < 100000; ++i) {
        int len = len_dist(rng);
        std::string input;
        input.reserve(static_cast<size_t>(len));
        for (int j = 0; j < len; ++j) {
            input.push_back(static_cast<char>(byte_dist(rng)));
        }
        auto cmd = mattecast::parseCommand(input);
        (void)cmd;
    }

    /* Explicit pathological numeric sizes/values. */
    assert(mattecast::parseCommand("FPS:999999999999999999999999").type == mattecast::CommandType::Invalid);
    assert(mattecast::parseCommand("RESOLUTION:999999999999999999x1").type == mattecast::CommandType::Invalid);
    assert(mattecast::parseCommand("BLUR:1e999999").type == mattecast::CommandType::Invalid);

    std::cout << "command parser fuzz test passed\n";
    return 0;
}
