FROM docker.io/nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04@sha256:59e0e4376a0f16d10b03d3a14344b80a866a1674cb4948cb318291387ac05010 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ARG ORT_VERSION=1.23.2
ARG ORT_SHA256=2083e361072a79ce16a90dcd5f5cb3ab92574a82a3ce0ac01e5cfa3158176f53

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl cmake build-essential libopencv-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    archive="onnxruntime-linux-x64-gpu-${ORT_VERSION}.tgz"; \
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --retry-all-errors \
      -o "/tmp/${archive}" \
      "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${archive}"; \
    echo "${ORT_SHA256}  /tmp/${archive}" | sha256sum -c -; \
    mkdir -p /opt/onnxruntime; \
    tar -xzf "/tmp/${archive}" -C /opt/onnxruntime --strip-components=1; \
    rm -f "/tmp/${archive}"; \
    test -f /opt/onnxruntime/include/onnxruntime_cxx_api.h; \
    test -f /opt/onnxruntime/lib/libonnxruntime.so

WORKDIR /build
COPY app/ /app/
RUN cmake -S /app -B /build/mattecast -DCMAKE_BUILD_TYPE=Release \
      -DONNXRUNTIME_ROOT=/opt/onnxruntime \
    && cmake --build /build/mattecast --parallel "$(nproc)"

FROM docker.io/nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04@sha256:59e0e4376a0f16d10b03d3a14344b80a866a1674cb4948cb318291387ac05010

LABEL maintainer="MatteCast"
LABEL description="AI-powered virtual camera using Robust Video Matting and ONNX Runtime"
LABEL org.opencontainers.image.source="local hardened MatteCast build"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    libopencv-core4.5d libopencv-imgproc4.5d libopencv-imgcodecs4.5d libopencv-videoio4.5d \
    python3 python3-pip v4l-utils zlib1g \
    libxcb-cursor0 libxcb-xinerama0 libxcb-icccm4 libxcb-keysyms1 \
    libxcb-shape0 libegl1 libgl1-mesa-glx libxkbcommon0 libxkbcommon-x11-0 \
    libdbus-1-3 fonts-ubuntu fontconfig \
    && fc-cache -fv \
    && rm -rf /var/lib/apt/lists/*

COPY app/gui-requirements.txt /tmp/gui-requirements.txt
RUN pip3 install --no-cache-dir --disable-pip-version-check --only-binary=:all: --no-deps \
    --require-hashes --index-url https://pypi.org/simple \
    -r /tmp/gui-requirements.txt \
    && rm -f /tmp/gui-requirements.txt

COPY --from=builder /build/mattecast/mattecast_server /app/mattecast_server
COPY --from=builder /opt/onnxruntime/lib/ /usr/local/lib/onnxruntime/
COPY app/control_panel.py /app/
COPY assets/ /app/assets/
COPY models/rvm_mobilenetv3_fp32.onnx /app/models/rvm_mobilenetv3_fp32.onnx

ENV LD_LIBRARY_PATH=/usr/local/lib/onnxruntime:$LD_LIBRARY_PATH
WORKDIR /app

RUN mkdir -p /run/mattecast /tmp/mattecast-home /tmp/mattecast-cache /root/.config/mattecast

COPY app/start.sh /app/start.sh
RUN chmod 0755 /app/start.sh

CMD ["/app/start.sh"]
