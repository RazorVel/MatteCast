#include "rvm_processor.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>

#include "rvm_math.h"

namespace {
constexpr int MODE_MATTE   = 0;
constexpr int MODE_LIGHT   = 1;
constexpr int MODE_GREEN   = 2;
constexpr int MODE_WHITE   = 3;
constexpr int MODE_NONE    = 4;
constexpr int MODE_BG      = 5;
constexpr int MODE_BLUR    = 6;
constexpr int MODE_DENOISE = 7;

constexpr std::array<const char*, 6> kInputNames = {
    "src", "r1i", "r2i", "r3i", "r4i", "downsample_ratio"
};
constexpr std::array<const char*, 5> kOutputNames = {
    "pha", "r1o", "r2o", "r3o", "r4o"
};
}

RvmProcessor::RvmProcessor()
    : env_(ORT_LOGGING_LEVEL_WARNING, "mattecast-rvm"),
      sessionOptions_(),
      cpuMemory_(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {}

RvmProcessor::~RvmProcessor() = default;

bool RvmProcessor::init(const std::string& modelPath, bool useCuda) {
    try {
        sessionOptions_.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        sessionOptions_.SetIntraOpNumThreads(1);
        sessionOptions_.SetInterOpNumThreads(1);

        if (useCuda) {
            OrtCUDAProviderOptions cuda{};
            cuda.device_id = 0;
            sessionOptions_.AppendExecutionProvider_CUDA(cuda);
        }

        session_ = std::make_unique<Ort::Session>(
            env_, modelPath.c_str(), sessionOptions_);
        modelPath_ = modelPath;
        inited_ = true;
        std::cout << "RVM model loaded with ONNX Runtime ("
                  << (useCuda ? "CUDA" : "CPU") << "): " << modelPath << std::endl;
        return true;
    } catch (const Ort::Exception& e) {
        std::cerr << "Failed to initialize RVM/ONNX Runtime: " << e.what() << std::endl;
        session_.reset();
        inited_ = false;
        return false;
    }
}

bool RvmProcessor::allocate(int width, int height) {
    if (!inited_ || width <= 0 || height <= 0) return false;
    if (width != width_ || height != height_) {
        width_ = width;
        height_ = height;
        inputBuffer_.assign(static_cast<size_t>(3) * width_ * height_, 0.0f);
        resetState();
        resizeBackground(width_, height_);
    }
    return true;
}

void RvmProcessor::resetState() {
    recurrent_.clear();
    inferenceWasActive_ = false;
}

bool RvmProcessor::runMatte(const cv::Mat& frame, std::vector<Ort::Value>& outputs) {
    if (!session_ || frame.empty() || frame.cols != width_ || frame.rows != height_) {
        return false;
    }

    const size_t pixels = static_cast<size_t>(width_) * static_cast<size_t>(height_);
    if (inputBuffer_.size() != pixels * 3) return false;

    // RVM expects normalized RGB NCHW. OpenCV camera frames are BGR HWC.
    for (int y = 0; y < height_; ++y) {
        for (int x = 0; x < width_; ++x) {
            const size_t i = static_cast<size_t>(y) * width_ + x;
            const cv::Vec3b p = frame.at<cv::Vec3b>(y, x);
            inputBuffer_[i]              = static_cast<float>(p[2]) / 255.0f;
            inputBuffer_[pixels + i]     = static_cast<float>(p[1]) / 255.0f;
            inputBuffer_[pixels * 2 + i] = static_cast<float>(p[0]) / 255.0f;
        }
    }

    std::array<int64_t, 4> srcShape{1, 3, height_, width_};
    std::array<int64_t, 4> recShape{1, 1, 1, 1};
    std::array<int64_t, 1> scalarShape{1};
    std::array<float, 4> initialRec{0.0f, 0.0f, 0.0f, 0.0f};
    float ratio = mattecast::chooseRvmDownsampleRatio(width_, height_);

    std::vector<Ort::Value> inputs;
    inputs.reserve(6);
    inputs.emplace_back(Ort::Value::CreateTensor<float>(
        cpuMemory_, inputBuffer_.data(), inputBuffer_.size(),
        srcShape.data(), srcShape.size()));

    if (recurrent_.size() == 4) {
        for (auto& state : recurrent_) inputs.emplace_back(std::move(state));
        recurrent_.clear();
    } else {
        for (size_t i = 0; i < initialRec.size(); ++i) {
            inputs.emplace_back(Ort::Value::CreateTensor<float>(
                cpuMemory_, &initialRec[i], 1, recShape.data(), recShape.size()));
        }
    }

    inputs.emplace_back(Ort::Value::CreateTensor<float>(
        cpuMemory_, &ratio, 1, scalarShape.data(), scalarShape.size()));

    try {
        outputs = session_->Run(
            Ort::RunOptions{nullptr},
            kInputNames.data(), inputs.data(), inputs.size(),
            kOutputNames.data(), kOutputNames.size());
    } catch (const Ort::Exception& e) {
        std::cerr << "RVM inference failed: " << e.what() << std::endl;
        resetState();
        return false;
    }

    if (outputs.size() != kOutputNames.size() ||
        !validateAlpha(outputs[0], width_, height_)) {
        std::cerr << "RVM returned unexpected output tensors" << std::endl;
        resetState();
        return false;
    }

    recurrent_.reserve(4);
    for (size_t i = 1; i < outputs.size(); ++i) {
        recurrent_.emplace_back(std::move(outputs[i]));
    }
    inferenceWasActive_ = true;
    return true;
}

bool RvmProcessor::validateAlpha(const Ort::Value& alpha, int width, int height) const {
    try {
        auto info = alpha.GetTensorTypeAndShapeInfo();
        const auto shape = info.GetShape();
        return shape.size() == 4 && shape[0] == 1 && shape[1] == 1 &&
               shape[2] == height && shape[3] == width;
    } catch (const Ort::Exception&) {
        return false;
    }
}

cv::Mat RvmProcessor::composite(const cv::Mat& frame, const float* alpha,
                                int mode, float blurStrength) const {
    cv::Mat result(frame.rows, frame.cols, CV_8UC3);
    cv::Mat background;

    if (mode == MODE_BLUR) {
        if (blurStrength <= 0.001f) return frame.clone();
        cv::GaussianBlur(frame, background, cv::Size(0, 0),
                         mattecast::blurSigma(blurStrength),
                         mattecast::blurSigma(blurStrength));
    } else if (mode == MODE_BG && !backgroundResized_.empty()) {
        background = backgroundResized_;
    }

    const size_t width = static_cast<size_t>(frame.cols);
    for (int y = 0; y < frame.rows; ++y) {
        for (int x = 0; x < frame.cols; ++x) {
            const size_t i = static_cast<size_t>(y) * width + static_cast<size_t>(x);
            const float a = mattecast::clampAlpha(alpha[i]);

            if (mode == MODE_MATTE) {
                const auto v = static_cast<unsigned char>(std::lround(a * 255.0f));
                result.at<cv::Vec3b>(y, x) = cv::Vec3b(v, v, v);
                continue;
            }

            const cv::Vec3b fg = frame.at<cv::Vec3b>(y, x);
            cv::Vec3b bg;
            switch (mode) {
            case MODE_GREEN:
                bg = cv::Vec3b(0, 255, 0);
                break;
            case MODE_WHITE:
                bg = cv::Vec3b(255, 255, 255);
                break;
            case MODE_LIGHT:
                bg = cv::Vec3b(
                    static_cast<unsigned char>(fg[0] / 2),
                    static_cast<unsigned char>(fg[1] / 2),
                    static_cast<unsigned char>(fg[2] / 2));
                break;
            case MODE_BG:
                bg = background.empty() ? cv::Vec3b(0, 200, 0)
                                        : background.at<cv::Vec3b>(y, x);
                break;
            case MODE_BLUR:
                bg = background.at<cv::Vec3b>(y, x);
                break;
            default:
                bg = fg;
                break;
            }

            result.at<cv::Vec3b>(y, x) = cv::Vec3b(
                mattecast::blendChannel(fg[0], bg[0], a),
                mattecast::blendChannel(fg[1], bg[1], a),
                mattecast::blendChannel(fg[2], bg[2], a));
        }
    }
    return result;
}

cv::Mat RvmProcessor::process(const cv::Mat& frame, int mode, float blurStrength) {
    if (!inited_ || frame.empty()) return frame.clone();
    if (mode == MODE_NONE || mode == MODE_DENOISE) {
        if (inferenceWasActive_) resetState();
        return frame.clone();
    }
    if (frame.cols != width_ || frame.rows != height_) return frame.clone();

    std::vector<Ort::Value> outputs;
    if (!runMatte(frame, outputs)) return frame.clone();

    try {
        const float* alpha = outputs[0].GetTensorData<float>();
        if (!alpha) {
            resetState();
            return frame.clone();
        }
        return composite(frame, alpha, mode, blurStrength);
    } catch (const Ort::Exception& e) {
        std::cerr << "Failed to read RVM alpha tensor: " << e.what() << std::endl;
        resetState();
        return frame.clone();
    }
}

void RvmProcessor::setBackground(const std::string& path, int width, int height) {
    cv::Mat loaded = cv::imread(path, cv::IMREAD_COLOR);
    if (loaded.empty()) {
        std::cerr << "Could not load background image: " << path << std::endl;
        return;
    }
    backgroundOriginal_ = loaded;
    resizeBackground(width, height);
    std::cout << "Background: " << path << std::endl;
}

void RvmProcessor::resizeBackground(int width, int height) {
    if (backgroundOriginal_.empty() || width <= 0 || height <= 0) {
        backgroundResized_ = cv::Mat();
        return;
    }
    cv::resize(backgroundOriginal_, backgroundResized_, cv::Size(width, height));
}
