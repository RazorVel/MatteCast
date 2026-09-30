#pragma once

#include <memory>
#include <string>
#include <vector>

#include <onnxruntime_cxx_api.h>
#include <opencv2/opencv.hpp>

class RvmProcessor {
public:
    RvmProcessor();
    ~RvmProcessor();

    RvmProcessor(const RvmProcessor&) = delete;
    RvmProcessor& operator=(const RvmProcessor&) = delete;

    bool init(const std::string& modelPath, bool useCuda = true);
    bool allocate(int width, int height);
    void resetState();

    cv::Mat process(const cv::Mat& frame, int mode, float blurStrength);
    void setBackground(const std::string& path, int width, int height);

private:
    bool runMatte(const cv::Mat& frame, std::vector<Ort::Value>& outputs);
    cv::Mat composite(const cv::Mat& frame, const float* alpha, int mode,
                      float blurStrength) const;
    bool validateAlpha(const Ort::Value& alpha, int width, int height) const;
    void resizeBackground(int width, int height);

    Ort::Env env_;
    Ort::SessionOptions sessionOptions_;
    std::unique_ptr<Ort::Session> session_;
    Ort::MemoryInfo cpuMemory_;
    std::vector<Ort::Value> recurrent_;
    std::vector<float> inputBuffer_;
    std::string modelPath_;
    cv::Mat backgroundOriginal_;
    cv::Mat backgroundResized_;
    int width_ = 0;
    int height_ = 0;
    bool inited_ = false;
    bool inferenceWasActive_ = false;
};
