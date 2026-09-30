#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(name):
    return (ROOT / name).read_text()


install = text("install.sh")
run = text("run.sh")
server = text("app/server.cpp")
rvm = text("app/rvm_processor.cpp")
cmake = text("app/CMakeLists.txt")
control = text("app/control_panel.py")
start = text("app/start.sh")
container = text("Containerfile")
remote = text("scripts/install-remote.sh")
push = text("scripts/push-to-ghcr.sh")
security = text("SECURITY.md")
publish = text(".github/workflows/publish.yml")
dockerignore = text(".dockerignore")
watcher = text("scripts/vcam_watcher.sh")
sign = text(".github/workflows/remote-sign.yml")
uninstall = text("scripts/uninstall.sh")

# Original privilege/isolation regressions remain closed.
assert 'LEGACY_SUDOERS_LINE=' in install
assert 'sudo grep -Fqx -- "$LEGACY_SUDOERS_LINE"' in install
assert 'tee "$LEGACY_SUDOERS"' not in install
assert 'MODE="0666"' not in install
assert "chmod 666" not in install
assert "--network host" not in run
assert "--ipc=host" not in run
assert "$HOME:/host_home" not in run
assert "xhost +local" not in run
assert "--network none" in run
assert "--ipc private" in run
assert "--cap-drop ALL" in run
assert "no-new-privileges" in run
assert "--read-only" in run
assert '--tmpfs "/tmp:rw,nosuid,nodev,noexec,size=256m"' in run
assert "MATTECAST_ENABLE_DBUS" in run
assert "MATTECAST_DISABLE_SELINUX_LABEL" in run
assert "MATTECAST_ALLOW_CUSTOM_IMAGE" in run
assert "MATTECAST_ALLOW_BROAD_MEDIA" in run
assert "ghcr.io/andrei9383/blucast:latest" not in run
assert "ghcr.io/andrei9383/mattecast:latest" not in run

# Runtime/control-file hardening.
assert "mkfifo(CMD_PIPE_PATH, 0600)" in server
assert "mkdir(SHARED_DIR, 0700)" in server
assert "signal(SIGPIPE, SIG_IGN)" in server
assert "std::stoi" not in server
assert "std::stof" not in server
assert "O_NOFOLLOW" in server
assert 'static const char *SHARED_DIR      = "/run/mattecast"' in server
assert "isAllowedBackgroundPath" in server
assert "os.O_NOFOLLOW" in control
assert "allowed_background_path" in control
assert "NamedTemporaryFile" in control and "os.replace" in control
assert 'umask(0077);' in server
assert 'len(cmd.encode("utf-8")) > 4096' in control
assert "runtime directory must not be a symlink" in run
assert "configuration directory must not be a symlink" in run
assert "Refusing symlink runtime directory" in watcher
assert "QSvgRenderer" not in control
assert "self._quitting" in control
assert "self.tray_icon.hide()" in control
assert 'echo "$name did not stop after SIGTERM; forcing shutdown." >&2' in start
assert "wait -n -p FIRST_PID" in start
assert "MatteCast GUI did not exit after server shutdown; terminating it." in start
assert "kill -KILL" in start
assert 'MANAGED_LABEL="io.mattecast.managed"' in run
assert 'container_is_managed' in run
assert 'container_is_legacy_mattecast' in run
assert '--label "$MANAGED_LABEL=true"' in run

# Active application namespace is MatteCast. BluCast remains only in explicit
# installer/uninstaller legacy migration paths.
for content in (run, server, rvm, cmake, control, container, watcher):
    assert "BLUCAST_" not in content
    assert "/run/blucast" not in content
    assert "blucast_server" not in content
assert "MATTECAST_" in run
assert "/run/mattecast" in server
assert "mattecast_server" in cmake

# Camera/input bounds and host-global module safety.
assert "3840, 2160" not in control
assert "2560, 1440" not in control
assert "MAX_WIDTH      = 1920" in control
assert "modprobe -r v4l2loopback" not in install
assert "modprobe -r v4l2loopback" not in run
assert "modprobe -r v4l2loopback" not in uninstall
assert '[[ "$VCAM_DEVICE" =~ ^/dev/video[0-9]+$ ]]' in run
assert "83-mattecast-v4l2loopback.conf" in install
assert "Existing v4l2loopback options found" in install
assert "is already used by" in install
assert "validate_virtual_camera" in run
assert "is not the MatteCast virtual camera" in run
assert "is_capture_device" in run
assert "0x00000001" in run and "0x00001000" in run
assert 'v4l2-ctl -d "$cam" --all' not in run
assert 'elif [[ "$cam" =~ ^/dev/video[0-9]+$ ]]' not in run
assert "CAP_PROP_FOURCC" in server
assert "preferred MJPG" in server
assert "Camera negotiated:" in server
assert "Virtual camera rejected requested format" in server
assert "closeDevice();\n            return false;" in server
assert "Resolution change rejected: virtual camera is in use" in server
assert "read_consumer_count" in control
assert "self.res_combo.setEnabled(not locked)" in control
assert "Resolution locked while MatteCast Virtual Camera is in use." in control

# Build/dependency hardening.
assert "RUN cat > /app/start.sh <<" not in container
assert "COPY app/start.sh /app/start.sh" in container
assert "RUN chmod 0755 /app/start.sh" in container
assert "--no-install-recommends" in container
assert "--only-binary=:all:" in container
assert "--no-deps" in container
assert "--require-hashes" in container
assert "--index-url https://pypi.org/simple" in container
assert "PySide6-Addons" not in container
assert "-fstack-protector-strong" in cmake
assert "-fPIE" in cmake and " -pie " in cmake
assert "-Wl,-z,relro,-z,now" in cmake
assert "**" in dockerignore and "!models/rvm_mobilenetv3_fp32.onnx" in dockerignore
assert "mv -fT" in watcher

# Remote/mutable image workflow remains disabled.
assert "remote prebuilt installation is intentionally disabled" in remote
assert "exit 2" in push and "CONTAINER_CMD push" not in push
assert "--network none" in security
assert "passwordless sudoers rule" in security
assert "ghcr.io/" not in publish
assert "docker/login-action" not in sign
assert "uses:" not in publish

# Removed legacy inference implementation remains absent from executable code/build.
for content in (container, cmake, server, run, install):
    assert "VideoFX" not in content
    assert "TensorRT-8.5.1.7" not in content
    assert "cc_spoof" not in content
    assert "MATTECAST_ENABLE_CC_SPOOF" not in content
assert not (ROOT / "app/cc_spoof.c").exists()
assert not (ROOT / "scripts/safe_extract_sdk.py").exists()

# RVM / ONNX Runtime backend security and state behavior.
assert "rvm_mobilenetv3_fp32.onnx" in container
assert "RvmProcessor" in server
assert "AppendExecutionProvider_CUDA" in rvm
assert "recurrent_" in rvm and "resetState" in rvm
assert "chooseRvmDownsampleRatio" in rvm
assert 'arg.rfind("--model="' not in server
assert 'static constexpr const char* MODEL_PATH = "/app/models/rvm_mobilenetv3_fp32.onnx"' in server
assert "Failed to read RVM alpha tensor" in rvm
assert "numpy==" not in container
assert "/app/mattecast_server --model=" not in container
assert "fetch-rvm-model.sh" in remote
assert "sha256sum -c" in container
assert "sha256sum -c" in install
assert "12.8.1-cudnn-runtime-ubuntu22.04@sha256:59e0e4376a0f16d10b03d3a14344b80a866a1674cb4948cb318291387ac05010" in container

print("security regression tests passed")
