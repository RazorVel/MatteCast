#include <fcntl.h>
#include <linux/videodev2.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>


#include <atomic>
#include <chrono>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "command_parser.h"
#include "opencv2/opencv.hpp"
#include "rvm_processor.h"

//  Paths ───────────────────────────────────────────────────────────────
static const char *SHARED_DIR      = "/run/mattecast";
static const char *CMD_PIPE_PATH   = "/run/mattecast/cmd.pipe";
static const char *CONSUMERS_FILE  = "/run/mattecast/consumers";
static const char *PREVIEW_FILE    = "/run/mattecast/preview.jpg";
static const char *PREVIEW_TMP     = "/run/mattecast/preview.jpg.tmp";
static const char *PID_FILE        = "/run/mattecast/server.pid";
static const char *runtimeVcamDevice() {
    const char *value = getenv("MATTECAST_VCAM_DEVICE");
    if (!value) return "/dev/video10";
    static const char prefix[] = "/dev/video";
    if (strncmp(value, prefix, sizeof(prefix) - 1) != 0 || value[sizeof(prefix) - 1] == '\0') {
        return "/dev/video10";
    }
    for (const char *p = value + sizeof(prefix) - 1; *p; ++p) {
        if (*p < '0' || *p > '9') return "/dev/video10";
    }
    return value;
}
static const char *VCAM_DEVICE = runtimeVcamDevice();

//  Global state
static std::atomic<bool>  g_running{true};
static std::atomic<bool>  g_windowVisible{true};
static std::atomic<int>   g_effectMode{6};
static std::atomic<float> g_blurStrength{0.5f};
static std::atomic<int>   g_cameraWidth{1280};
static std::atomic<int>   g_cameraHeight{720};
static std::atomic<int>   g_cameraFps{30};
static std::atomic<bool>  g_cameraSettingsChanged{false};

static std::mutex  g_deviceMutex;
static std::string g_inputDevice;
static bool        g_deviceChanged = false;

static std::mutex  g_bgMutex;
static std::string g_bgFile;
static bool        g_bgChanged = false;

//  Effect modes ────────────────────────────────────────────────────────
enum EffectMode {
    MODE_MATTE    = 0,
    MODE_LIGHT    = 1,
    MODE_GREEN    = 2,
    MODE_WHITE    = 3,
    MODE_NONE     = 4,
    MODE_BG       = 5,
    MODE_BLUR     = 6,
    MODE_DENOISE  = 7,
};

//  Utility: read consumer count from file ──────────────────────────────
static int readConsumerCount() {
    int fd = ::open(CONSUMERS_FILE, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return 0;
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return 0; }
    int n = 0;
    if (fscanf(f, "%d", &n) != 1) n = 0;
    fclose(f);
    return n < 0 ? 0 : n;
}

//  Utility: write PID file without following a hostile symlink.
static void writePidFile() {
    int fd = ::open(PID_FILE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%d\n", getpid());
    if (len > 0) {
        size_t offset = 0;
        const size_t total = static_cast<size_t>(len);
        while (offset < total) {
            ssize_t n = ::write(fd, buf + offset, total - offset);
            if (n > 0) {
                offset += static_cast<size_t>(n);
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            break;
        }
    }
    close(fd);
}

static bool ensureSecureRuntimeDirectory() {
    if (mkdir(SHARED_DIR, 0700) != 0 && errno != EEXIST) return false;
    struct stat st{};
    if (lstat(SHARED_DIR, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid()) return false;
    return chmod(SHARED_DIR, 0700) == 0;
}

static bool isAllowedBackgroundPath(const std::string &path) {
    if (path.empty()) return false;
    char resolved[PATH_MAX];
    if (!realpath(path.c_str(), resolved)) return false;
    static const char root[] = "/media/host";
    const size_t n = sizeof(root) - 1;
    if (strncmp(resolved, root, n) != 0) return false;
    if (resolved[n] != '\0' && resolved[n] != '/') return false;
    struct stat st{};
    return stat(resolved, &st) == 0 && S_ISREG(st.st_mode);
}

// ══════════════════════════════════════════════════════════════════════════
// Virtual Camera
// ══════════════════════════════════════════════════════════════════════════
class VirtualCamera {
public:
    VirtualCamera() : fd_(-1), width_(0), height_(0), fps_(0) {}

    ~VirtualCamera() {
        if (fd_ >= 0) {
            int type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
            ioctl(fd_, VIDIOC_STREAMOFF, &type);
            close(fd_);
        }
    }

    bool open(int width, int height, int fps) {
        // reopen if resolution changed
        if (fd_ >= 0 && (width_ != width || height_ != height)) {
            closeDevice();
        }
        if (fd_ >= 0) {
            if (fps_ != fps) setFrameRate(fps);
            return true;
        }

        fd_ = ::open(VCAM_DEVICE, O_WRONLY);
        if (fd_ < 0) {
            std::cerr << "Cannot open virtual camera " << VCAM_DEVICE << std::endl;
            return false;
        }

        struct v4l2_format fmt{};
        fmt.type                 = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        fmt.fmt.pix.width        = width;
        fmt.fmt.pix.height       = height;
        fmt.fmt.pix.pixelformat  = V4L2_PIX_FMT_YUV420;
        fmt.fmt.pix.sizeimage    = width * height * 3 / 2;
        fmt.fmt.pix.field        = V4L2_FIELD_NONE;
        if (ioctl(fd_, VIDIOC_S_FMT, &fmt) < 0) {
            std::cerr << "VIDIOC_S_FMT failed for virtual camera (errno=" << errno << ")" << std::endl;
            closeDevice();
            return false;
        }
        if (fmt.fmt.pix.width != static_cast<__u32>(width) ||
            fmt.fmt.pix.height != static_cast<__u32>(height) ||
            fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUV420) {
            std::cerr << "Virtual camera rejected requested format "
                      << width << "x" << height << " YU12; negotiated "
                      << fmt.fmt.pix.width << "x" << fmt.fmt.pix.height
                      << " instead" << std::endl;
            closeDevice();
            return false;
        }

        setFrameRate(fps);

        width_  = static_cast<int>(fmt.fmt.pix.width);
        height_ = static_cast<int>(fmt.fmt.pix.height);
        std::cout << "Virtual camera: " << VCAM_DEVICE
                  << " @ " << width_ << "x" << height_
                  << " " << fps_ << "fps" << std::endl;
        return true;
    }

    void writeFrame(const cv::Mat &bgr) {
        if (fd_ < 0) return;
        cv::Mat yuv;
        if (bgr.cols != width_ || bgr.rows != height_) {
            cv::Mat resized;
            cv::resize(bgr, resized, cv::Size(width_, height_));
            cv::cvtColor(resized, yuv, cv::COLOR_BGR2YUV_I420);
        } else {
            cv::cvtColor(bgr, yuv, cv::COLOR_BGR2YUV_I420);
        }
        writeBuffer(yuv.data, yuv.total() * yuv.elemSize());
    }

    void writeIdleFrame() {
        if (fd_ < 0) return;
        if (idleYuv_.empty() || idleW_ != width_ || idleH_ != height_) {
            int w = width_  > 0 ? width_  : 1280;
            int h = height_ > 0 ? height_ : 720;
            cv::Mat black = cv::Mat::zeros(h, w, CV_8UC3);
            cv::putText(black, "Camera Off",
                        cv::Point(w / 2 - 120, h / 2),
                        cv::FONT_HERSHEY_SIMPLEX, 1.5,
                        cv::Scalar(80, 80, 80), 2);
            cv::cvtColor(black, idleYuv_, cv::COLOR_BGR2YUV_I420);
            idleW_ = w;
            idleH_ = h;
        }
        writeBuffer(idleYuv_.data, idleYuv_.total() * idleYuv_.elemSize());
    }

    bool isOpen() const { return fd_ >= 0; }
    int width()  const { return width_; }
    int height() const { return height_; }

private:
    void closeDevice() {
        if (fd_ < 0) return;
        int type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        ioctl(fd_, VIDIOC_STREAMOFF, &type);
        close(fd_);
        fd_ = -1;
    }

    void setFrameRate(int fps) {
        int safeFps = fps > 0 ? fps : 30;
        struct v4l2_streamparm parm{};
        parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        parm.parm.output.timeperframe.numerator = 1;
        parm.parm.output.timeperframe.denominator = safeFps;
        if (fd_ >= 0 && ioctl(fd_, VIDIOC_S_PARM, &parm) < 0) {
            std::cerr << "Warning: VIDIOC_S_PARM failed" << std::endl;
        }
        fps_ = safeFps;
    }

    bool writeBuffer(const unsigned char *data, size_t size) {
        if (fd_ < 0) return false;
        size_t written = 0;
        while (written < size) {
            ssize_t n = ::write(fd_, data + written, size - written);
            if (n > 0) {
                written += static_cast<size_t>(n);
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) {
                std::cerr << "Virtual camera write failed (errno=" << errno
                          << "); will reopen" << std::endl;
            } else {
                std::cerr << "Virtual camera write returned 0; will reopen" << std::endl;
            }
            closeDevice();
            return false;
        }
        return true;
    }

    int fd_, width_, height_, fps_;
    cv::Mat idleYuv_;
    int idleW_ = 0, idleH_ = 0;
};

// ══════════════════════════════════════════════════════════════════════════
// Preview writer
// ══════════════════════════════════════════════════════════════════════════
static void writePreviewJpeg(const cv::Mat &bgr) {
    static std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 80};
    std::vector<uchar> buf;
    cv::imencode(".jpg", bgr, buf, params);

    int fd = ::open(PREVIEW_TMP, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    FILE *f = fdopen(fd, "wb");
    if (!f) { close(fd); return; }
    size_t written = fwrite(buf.data(), 1, buf.size(), f);
    bool ok = (written == buf.size() && fflush(f) == 0);
    fclose(f);
    if (ok) {
        if (rename(PREVIEW_TMP, PREVIEW_FILE) != 0) unlink(PREVIEW_TMP);
    } else {
        unlink(PREVIEW_TMP);
    }
}

// ══════════════════════════════════════════════════════════════════════════
// Command Listener
// ══════════════════════════════════════════════════════════════════════════
static void applyCommand(const mattecast::Command &command) {
    using mattecast::CommandType;
    switch (command.type) {
    case CommandType::Quit:
        g_running = false;
        break;
    case CommandType::WindowVisible:
        g_windowVisible = true;
        break;
    case CommandType::WindowHidden:
        g_windowVisible = false;
        break;
    case CommandType::Mode:
        g_effectMode = command.intValue;
        break;
    case CommandType::Blur:
        g_blurStrength = command.floatValue;
        break;
    case CommandType::Background: {
        if (!isAllowedBackgroundPath(command.text)) {
            std::cerr << "Ignoring background outside /media/host or non-regular file" << std::endl;
            break;
        }
        std::lock_guard<std::mutex> lock(g_bgMutex);
        g_bgFile = command.text;
        g_bgChanged = true;
        break;
    }
    case CommandType::Device: {
        std::lock_guard<std::mutex> lock(g_deviceMutex);
        if (command.text != g_inputDevice) {
            g_inputDevice = command.text;
            g_deviceChanged = true;
        }
        break;
    }
    case CommandType::Resolution:
        if (readConsumerCount() > 0) {
            std::cerr << "Resolution change rejected: virtual camera is in use" << std::endl;
            break;
        }
        g_cameraWidth = command.width;
        g_cameraHeight = command.height;
        g_cameraSettingsChanged = true;
        break;
    case CommandType::Fps:
        g_cameraFps = command.intValue;
        g_cameraSettingsChanged = true;
        break;
    case CommandType::Invalid:
        break;
    }
}

static void commandListener() {
    umask(0077);
    if (!ensureSecureRuntimeDirectory()) {
        std::cerr << "Unsafe or unavailable runtime directory" << std::endl;
        g_running = false;
        return;
    }
    unlink(CMD_PIPE_PATH);
    if (mkfifo(CMD_PIPE_PATH, 0600) != 0) {
        std::cerr << "Cannot create command pipe" << std::endl;
        g_running = false;
        return;
    }
    chmod(CMD_PIPE_PATH, 0600);

    std::string pending;
    while (g_running) {
        int fd = ::open(CMD_PIPE_PATH, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        struct stat pipeStat{};
        if (fstat(fd, &pipeStat) != 0 || !S_ISFIFO(pipeStat.st_mode) || pipeStat.st_uid != geteuid()) {
            std::cerr << "Command pipe failed ownership/type validation" << std::endl;
            close(fd);
            g_running = false;
            break;
        }

        struct pollfd pfd = {fd, POLLIN, 0};
        while (g_running) {
            int ret = poll(&pfd, 1, 500);
            if (ret < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (ret == 0) continue;
            if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
            if (!(pfd.revents & POLLIN)) continue;

            char buf[1024];
            ssize_t n = ::read(fd, buf, sizeof(buf));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            pending.append(buf, static_cast<size_t>(n));

            if (pending.size() > 8192) {
                std::cerr << "Discarding oversized command input" << std::endl;
                pending.clear();
                continue;
            }

            size_t newline = 0;
            while ((newline = pending.find('\n')) != std::string::npos) {
                std::string line = pending.substr(0, newline);
                pending.erase(0, newline + 1);
                auto command = mattecast::parseCommand(line, VCAM_DEVICE);
                if (command.type == mattecast::CommandType::Invalid) {
                    std::cerr << "Ignoring invalid command" << std::endl;
                    continue;
                }
                applyCommand(command);
            }
        }
        close(fd);
    }
    unlink(CMD_PIPE_PATH);
}

static int mjpgFourcc() {
    return static_cast<int>('M') |
           (static_cast<int>('J') << 8) |
           (static_cast<int>('P') << 16) |
           (static_cast<int>('G') << 24);
}

static std::string fourccString(double raw) {
    unsigned int value = static_cast<unsigned int>(raw);
    char code[5] = {
        static_cast<char>(value & 0xffu),
        static_cast<char>((value >> 8) & 0xffu),
        static_cast<char>((value >> 16) & 0xffu),
        static_cast<char>((value >> 24) & 0xffu),
        '\0'
    };
    for (int i = 0; i < 4; ++i) {
        if (code[i] < 32 || code[i] > 126) code[i] = '?';
    }
    return std::string(code);
}

// ══════════════════════════════════════════════════════════════════════════
// Camera auto-detection
// ══════════════════════════════════════════════════════════════════════════
static std::string autoDetectCamera() {
    for (int i = 0; i <= 9; i++) {
        std::string path = "/dev/video" + std::to_string(i);
        if (path == VCAM_DEVICE) continue;
        struct stat st;
        if (stat(path.c_str(), &st) != 0) continue;
        cv::VideoCapture test;
        test.open(path, cv::CAP_V4L2);
        if (test.isOpened()) {
            test.release();
            return path;
        }
    }
    return "";
}

// ══════════════════════════════════════════════════════════════════════════
// Main loop
// ══════════════════════════════════════════════════════════════════════════
static void signalHandler(int) { g_running = false; }

int main(int argc, char **argv) {
    umask(0077);
    signal(SIGINT,  signalHandler);
    signal(SIGTERM, signalHandler);
    signal(SIGPIPE, SIG_IGN);

    setenv("OPENCV_VIDEOIO_PRIORITY_V4L2",     "990", 0);
    setenv("OPENCV_VIDEOIO_PRIORITY_GSTREAMER", "0",   0);

    static constexpr const char* MODEL_PATH = "/app/models/rvm_mobilenetv3_fp32.onnx";
    bool useCuda = true;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--cpu") useCuda = false;
        else {
            std::cerr << "Unknown argument: " << arg << std::endl;
            return 2;
        }
    }

    std::cout << "════════════════════════════════════" << std::endl;
    std::cout << "           MatteCast Server" << std::endl;
    std::cout << "════════════════════════════════════" << std::endl;
    std::cout << "Model:     " << MODEL_PATH << std::endl;
    std::cout << "Provider:  " << (useCuda ? "CUDA" : "CPU") << std::endl;

    writePidFile();

    std::thread cmdThread(commandListener);

    RvmProcessor rvm;
    if (!rvm.init(MODEL_PATH, useCuda)) {
        std::cerr << "Failed to initialize RVM inference" << std::endl;
        g_running = false;
        cmdThread.join();
        return 1;
    }

    VirtualCamera vcam;
    int vcamW = g_cameraWidth.load();
    int vcamH = g_cameraHeight.load();
    int vcamFps = g_cameraFps.load();
    vcam.open(vcamW, vcamH, vcamFps);
    vcam.writeIdleFrame();

    cv::VideoCapture cap;
    bool cameraActive = false;
    bool buffersReady = false;
    int curWidth = 0, curHeight = 0;
    std::string currentDevice;
    bool lastNeedCamera = false;

    std::cout << "Ready. Listening on " << CMD_PIPE_PATH << std::endl;

    while (g_running) {
        int consumers = readConsumerCount();
        bool windowVis = g_windowVisible.load();
        bool needCamera = windowVis || (consumers > 0);

        if (needCamera != lastNeedCamera) {
            std::cout << (needCamera ? "Camera: activating" : "Camera: going idle") << std::endl;
            lastNeedCamera = needCamera;
        }

        if (!needCamera) {
            if (cameraActive) {
                cap.release();
                cameraActive = false;
                rvm.resetState();
                std::cout << "Camera released" << std::endl;
            }
            if (vcam.isOpen()) {
                vcam.writeIdleFrame();
            }
            unlink(PREVIEW_FILE);
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            continue;
        }

        if (!cameraActive) {
            {
                std::lock_guard<std::mutex> lock(g_deviceMutex);
                if (!g_inputDevice.empty()) currentDevice = g_inputDevice;
                g_deviceChanged = false;
            }

            if (currentDevice.empty()) {
                currentDevice = autoDetectCamera();
                if (!currentDevice.empty()) {
                    std::cout << "Auto-detected camera: " << currentDevice << std::endl;
                }
            }

            if (!currentDevice.empty()) {
                cap.open(currentDevice, cv::CAP_V4L2);
            } else {
                cap.open(0, cv::CAP_V4L2);
            }

            if (!cap.isOpened()) {
                std::cerr << "Cannot open camera" << std::endl;
                std::this_thread::sleep_for(std::chrono::seconds(1));
                continue;
            }

            int reqW   = g_cameraWidth.load();
            int reqH   = g_cameraHeight.load();
            int reqFps = g_cameraFps.load();

            // UVC cameras commonly expose high-resolution/high-FPS modes only as MJPEG.
            // Set the pixel format before width/height/fps so V4L2 can select those modes.
            bool mjpgAccepted = cap.set(cv::CAP_PROP_FOURCC, mjpgFourcc());
            cap.set(cv::CAP_PROP_FRAME_WIDTH,  reqW);
            cap.set(cv::CAP_PROP_FRAME_HEIGHT, reqH);
            cap.set(cv::CAP_PROP_FPS,          reqFps);

            curWidth  = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
            curHeight = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
            double curFps = cap.get(cv::CAP_PROP_FPS);
            std::string curFourcc = fourccString(cap.get(cv::CAP_PROP_FOURCC));
            std::cout << "Camera requested: " << reqW << "x" << reqH
                      << " @ " << reqFps << "fps, preferred MJPG" << std::endl;
            std::cout << "Camera negotiated: " << curWidth << "x" << curHeight
                      << " @ " << curFps << "fps, " << curFourcc
                      << (mjpgAccepted ? "" : " (MJPG request not accepted)") << std::endl;

            // Reconfigure inference state if resolution changed.
            if (curWidth <= 0 || curHeight <= 0 ||
                curWidth > mattecast::kMaxCameraWidth || curHeight > mattecast::kMaxCameraHeight) {
                std::cerr << "Camera negotiated unsupported resolution: "
                          << curWidth << "x" << curHeight << std::endl;
                cap.release();
                std::this_thread::sleep_for(std::chrono::seconds(1));
                continue;
            }

            if (!buffersReady || curWidth != vcamW || curHeight != vcamH) {
                if (!rvm.allocate(curWidth, curHeight)) {
                    std::cerr << "Failed to configure RVM processor" << std::endl;
                    cap.release();
                    std::this_thread::sleep_for(std::chrono::seconds(1));
                    continue;
                }
                buffersReady = true;
            }

            if (!vcam.open(curWidth, curHeight, reqFps)) {
                std::this_thread::sleep_for(std::chrono::seconds(1));
                continue;
            }
            vcamW = curWidth;
            vcamH = curHeight;
            vcamFps = reqFps;

            cameraActive = true;
        }

        {
            std::lock_guard<std::mutex> lock(g_deviceMutex);
            if (g_deviceChanged) {
                g_deviceChanged = false;
                cap.release();
                cameraActive = false;
                buffersReady = false;
                rvm.resetState();
                continue;
            }
        }
        if (g_cameraSettingsChanged.exchange(false)) {
            cap.release();
            cameraActive = false;
            buffersReady = false;
            rvm.resetState();
            continue;
        }

        {
            std::lock_guard<std::mutex> lock(g_bgMutex);
            if (g_bgChanged && !g_bgFile.empty()) {
                rvm.setBackground(g_bgFile, curWidth, curHeight);
                g_bgChanged = false;
            }
        }

        cv::Mat frame;
        cap >> frame;
        if (frame.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        int mode = g_effectMode.load();
        cv::Mat result = rvm.process(frame, mode, g_blurStrength.load());

        if (!vcam.isOpen()) vcam.open(vcamW, vcamH, vcamFps);
        vcam.writeFrame(result);

        if (windowVis) {
            writePreviewJpeg(result);
        }
    }

    if (cameraActive) cap.release();
    unlink(PID_FILE);
    unlink(PREVIEW_FILE);
    unlink(PREVIEW_TMP);

    g_running = false;
    cmdThread.join();
    std::cout << "MatteCast closed." << std::endl;
    return 0;
}
