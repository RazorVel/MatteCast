# MatteCast Hardened RVM Test Build

This tree is a security/reliability hardening pass plus inference-backend
migration over the original BluCast v1.0.7 source. After replacing the
proprietary NVIDIA Maxine backend with RVM/ONNX Runtime and substantially
reworking the runtime/security model, the project was renamed MatteCast. It is
intended for local hardware validation before production use.

## Backend migration

The legacy proprietary effects backend and its compatibility shim were removed.
MatteCast now uses:

- Robust Video Matting MobileNetV3 FP32 ONNX model;
- ONNX Runtime GPU 1.23.2;
- CUDA 12.8 / cuDNN 9 userspace from a pinned NVIDIA container base;
- OpenCV for capture/compositing/V4L2 output.

The RVM recurrent state is preserved across sequential active frames and reset
when inference stops, fails, or the camera configuration changes.

## Host/container hardening retained

- No passwordless `sudoers` rule.
- Virtual camera `0660` + `uaccess`; command FIFO `0600`.
- Per-user `0700` runtime/configuration directories.
- Runtime/configuration directory symlinks rejected.
- Network disabled by default.
- Private IPC.
- All Linux capabilities dropped.
- `no-new-privileges` enabled.
- Read-only root filesystem.
- Bounded `noexec,nosuid,nodev` tmpfs.
- Whole-home mount removed.
- Media mount read-only and broad mounts require explicit override.
- Session D-Bus and `/dev/dri` are opt-in.
- Isolated Xauthority instead of `xhost +local:`.
- Custom local images require a second explicit opt-in.
- Global v4l2loopback module is never automatically unloaded.

## Additional hardening in the RVM migration

- RVM model download is HTTPS-only, size-checked and SHA-256 pinned.
- Model is validated again by the installer before any privileged host changes.
- Runtime model path is fixed; arbitrary `--model=` input is not accepted.
- ONNX Runtime release archive is SHA-256 pinned.
- Qt GUI dependencies are reduced to PySide6 Essentials + shiboken6 and their
  Linux x86_64 wheels are SHA-256 pinned.
- Container build context remains allowlisted.
- Native binary uses stack protector, FORTIFY, RELRO and immediate binding.
- Host architecture is checked explicitly (`x86_64`).
- Existing `/dev/videoN` conflicts are detected before virtual-camera setup.
- MatteCast now owns only `83-mattecast-*` module/udev configuration files.
- Existing unrelated `options v4l2loopback` configuration causes installation
  to stop instead of being overwritten.
- Uninstaller removes generic legacy configuration only when exact legacy
  BluCast ownership can be established.

## Runtime reliability fixes retained

- Strict bounded non-throwing command parser.
- Malformed FIFO commands ignored instead of terminating the process.
- `SIGPIPE` ignored and virtual-camera write failures trigger safe reopen.
- Camera resolution bounded to 1920×1080.
- Virtual-camera override validated and propagated consistently.
- Settings schema/range validation and atomic mode-`0600` writes.
- Runtime file opens use symlink protections where applicable.
- Background images restricted to regular files under `/media/host`.
- RVM output tensor shape validated before compositing.
- Inference exceptions reset recurrent state and return the original frame.

## Supply-chain boundary

This source archive intentionally does not contain the RVM model or ONNX
Runtime binaries. The model is fetched by an explicit helper command and the
ONNX Runtime package is fetched only during the local container build. Both are
content-pinned with SHA-256 values.

APT packages remain repository-authenticated rather than individually hash-
pinned by this project. The NVIDIA base image itself is digest-pinned.

## Test coverage

`./tests/run_tests.sh` performs reproducible non-hardware checks covering:

1. shell syntax;
2. Python syntax without writing bytecode into the tree;
3. command-parser unit tests;
4. deterministic command-parser fuzzing;
5. RVM math/compositing helpers;
6. strict RVM/server C++ syntax against API-compatible stubs;
7. control/settings security behavior;
8. model/dependency supply-chain assertions;
9. host configuration/uninstaller safety assertions;
10. parser fuzzing under AddressSanitizer + UndefinedBehaviorSanitizer;
11. security regression assertions;
12. stale-artifact/source-tree checks.

When available, an additional `clang++` syntax pass and `shellcheck` pass can be
run as supplementary diagnostics.

## Hardware validation still required

The analysis environment cannot validate the actual NVIDIA driver, CUDA
provider, webcam, X server, or v4l2loopback device. Target-machine testing must
cover:

- local container build;
- ONNX Runtime CUDA provider initialization;
- sustained RVM inference on the target GPU;
- blur/remove/replace visual quality;
- physical-camera format/FPS negotiation;
- virtual-camera consumption by real applications;
- camera unplug/replug and consumer reconnect;
- suspend/resume;
- long-run CPU/GPU/VRAM/RAM stability.

## Residual security boundary

The main remaining host-facing boundary is X11/XWayland plus GPU/video device
access. The launcher narrows these interfaces but cannot make an authenticated
X11 client equivalent to a strongly isolated Wayland/nested-display client.
