# Security Policy

## Reporting a vulnerability

Report security issues privately to the project maintainer rather than posting
exploit details in a public issue. Include the affected revision, impact,
preconditions, minimal reproduction steps, and a suggested mitigation when
known.

## Security model

MatteCast processes webcam frames locally. The normal runtime container has no
network access and receives only the host resources required for its function.

### Container boundary

Default launcher behavior:

- `--network none`;
- private IPC namespace;
- `--cap-drop ALL`;
- `no-new-privileges`;
- read-only root filesystem;
- bounded `noexec,nosuid,nodev` `/tmp` tmpfs;
- no session D-Bus mount;
- no whole-home-directory mount;
- no `/dev/dri` access unless explicitly enabled;
- selected video devices only;
- isolated Xauthority cookie instead of broad `xhost` authorization;
- per-user runtime/configuration directories with restrictive permissions;
- custom images and broad media mounts require a separate explicit opt-in.

The container still receives an X11/XWayland connection, NVIDIA GPU access, and
selected video devices. Those are meaningful host interfaces and remain part of
the trusted computing boundary.

### Privilege model

MatteCast does not install a passwordless sudoers rule. Privilege is requested
only for host setup that genuinely requires it, such as installing/loading
`v4l2loopback` and writing system configuration.

The virtual-camera udev rule uses `MODE="0660"` plus `uaccess`; the device is not
made world-writable.

Host v4l2loopback configuration uses MatteCast-specific filenames. Installation
refuses to overwrite/compete with a different existing `options v4l2loopback`
configuration. The uninstaller does not blindly remove generic v4l2loopback
configuration belonging to another application.

### Runtime/control files

The command FIFO is mode `0600`. Sensitive opens reject symlinks where
applicable, runtime/configuration directories are ownership-checked, settings
are schema/range validated, and settings updates use atomic replacement.

Background replacement accepts only regular files resolving beneath the
read-only `/media/host` mount.

### Supply chain

The default launcher never silently pulls a third-party MatteCast image. The
application is built locally as `mattecast:hardened-local`.

Supply-chain controls include:

- NVIDIA CUDA base image referenced by immutable digest;
- official RVM model fetched only on explicit request, with exact size and
  SHA-256 verification;
- ONNX Runtime GPU archive fetched from the Microsoft GitHub release and
  SHA-256 verified before extraction;
- GUI Python wheels restricted to exact versions, binary wheels, and
  PyPI-published SHA-256 hashes;
- allowlisted container build context via `.dockerignore`;
- no mutable upstream MatteCast `latest` fallback;
- remote image publishing disabled in this test tree.

APT packages are authenticated by the repositories configured in the pinned
base image, but their exact package versions are not independently content-
pinned by this project. A rebuild at a later date can therefore receive newer
repository package revisions.

### Model and inference engine

The RVM model is treated as executable inference input. It is accepted only at
the pinned path after SHA-256 validation before the image build. Runtime model
path overrides are not accepted by the server.

ONNX Runtime inference failures and malformed output tensors fail closed to the
original frame rather than terminating the server. Recurrent state is reset on
inference failure and camera reconfiguration.

### Data privacy

By default the running container cannot create outbound network connections.
Only the explicitly selected read-only media directory (default `~/Pictures`)
is exposed for background images. The entire home directory is not mounted.

## Residual risks

### X11 trust

An authenticated X11 client has significant access to its X server. The
isolated cookie is narrower than `xhost +local:`, but it is not a strong GUI
sandbox. A future host-native GUI or nested display server would provide a
stronger boundary.

### Native media/inference parsers

OpenCV, Qt image handling, ONNX Runtime, NVIDIA CUDA/cuDNN, the camera driver,
and the kernel V4L2 stack process complex native inputs. Container isolation
reduces impact but does not eliminate vulnerabilities in those components.

### Optional compatibility switches

`MATTECAST_ENABLE_DBUS=1`, `MATTECAST_ENABLE_DRI=1`,
`MATTECAST_DISABLE_SELINUX_LABEL=1`, `MATTECAST_ALLOW_BROAD_MEDIA=1`, and custom
container-image overrides intentionally expand the trust boundary. Use them
only when necessary and with inputs/images you trust.
