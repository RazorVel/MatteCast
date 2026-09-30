#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VCAM_DEVICE="${MATTECAST_VCAM_DEVICE:-/dev/video10}"
[[ "$VCAM_DEVICE" =~ ^/dev/video[0-9]+$ ]] || { echo "Error: MATTECAST_VCAM_DEVICE must be /dev/video<N>" >&2; exit 1; }
VCAM_NR="${VCAM_DEVICE#/dev/video}"
VCAM_LABEL="MatteCast Virtual Camera"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}"
SHARED_HOST_DIR="$RUNTIME_BASE/mattecast-${UID}"
CONTAINER_SHARED_DIR="/run/mattecast"
CONFIG_DIR="$HOME/.config/mattecast"
MEDIA_HOST_DIR="${MATTECAST_MEDIA_DIR:-$HOME/Pictures}"
IMAGE_OVERRIDE="${MATTECAST_IMAGE:-}"

fail() { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }

if [ -d "$MEDIA_HOST_DIR" ]; then
    MEDIA_REAL="$(readlink -f -- "$MEDIA_HOST_DIR")"
    HOME_REAL="$(readlink -f -- "$HOME")"
    case "$MEDIA_REAL" in
        /|/home|/root|"$HOME_REAL")
            [ "${MATTECAST_ALLOW_BROAD_MEDIA:-0}" = "1" ] || \
                fail "Refusing broad media mount ($MEDIA_REAL). Choose a dedicated image directory, or set MATTECAST_ALLOW_BROAD_MEDIA=1 if this exposure is intentional."
            warn "broad media mount explicitly enabled: $MEDIA_REAL"
            ;;
    esac
fi

if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
else
    fail "podman or docker required"
fi

image_exists() {
    if [ "$CONTAINER_CMD" = "podman" ]; then
        "$CONTAINER_CMD" image exists "$1" >/dev/null 2>&1
    else
        "$CONTAINER_CMD" image inspect "$1" >/dev/null 2>&1
    fi
}

if [ -n "$IMAGE_OVERRIDE" ]; then
    [ "${MATTECAST_ALLOW_CUSTOM_IMAGE:-0}" = "1" ] || fail "MATTECAST_IMAGE is disabled by default. Set MATTECAST_ALLOW_CUSTOM_IMAGE=1 only for an image you built or independently verified."
    image_exists "$IMAGE_OVERRIDE" || fail "MATTECAST_IMAGE does not exist locally: $IMAGE_OVERRIDE"
    warn "custom container image explicitly enabled; it receives camera, GPU, X11, config, and media access"
    IMAGE_NAME="$IMAGE_OVERRIDE"
else
    IMAGE_NAME=""
    for candidate in "mattecast:hardened-local" "localhost/mattecast:hardened-local"; do
        if image_exists "$candidate"; then
            IMAGE_NAME="$candidate"
            break
        fi
    done
    [ -n "$IMAGE_NAME" ] || fail "patched local image not found. Run ./install.sh first. MatteCast will not silently pull an upstream image."
fi

CONTAINER_NAME="mattecast-${UID}"
MANAGED_LABEL="io.mattecast.managed"

container_exists() {
    "$CONTAINER_CMD" container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
    [ "$("$CONTAINER_CMD" container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "true" ]
}

container_is_managed() {
    [ "$("$CONTAINER_CMD" container inspect --format '{{index .Config.Labels "io.mattecast.managed"}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "true" ]
}

container_is_legacy_mattecast() {
    local image
    image="$("$CONTAINER_CMD" container inspect --format '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    case "$image" in
        mattecast:hardened-local|localhost/mattecast:hardened-local) return 0 ;;
        *) return 1 ;;
    esac
}

if container_exists; then
    if container_running; then
        fail "MatteCast is already running in container $CONTAINER_NAME"
    fi
    if container_is_managed || container_is_legacy_mattecast; then
        warn "removing stale MatteCast container: $CONTAINER_NAME"
        "$CONTAINER_CMD" rm -f "$CONTAINER_NAME" >/dev/null || \
            fail "could not remove stale MatteCast container: $CONTAINER_NAME"
    else
        fail "container name $CONTAINER_NAME is already in use by an unmanaged container; remove or rename it manually"
    fi
fi

MODPROBE_BIN="$(command -v modprobe || true)"
[ -n "$MODPROBE_BIN" ] || fail "modprobe not found"

video_name() {
    local dev="$1" base
    base="${dev##*/}"
    [ -r "/sys/class/video4linux/$base/name" ] || return 1
    cat "/sys/class/video4linux/$base/name"
}

validate_virtual_camera() {
    [ -c "$VCAM_DEVICE" ] || fail "$VCAM_DEVICE exists but is not a character video device"
    local name
    name="$(video_name "$VCAM_DEVICE" 2>/dev/null || true)"
    [ "$name" = "$VCAM_LABEL" ] || \
        fail "$VCAM_DEVICE is not the MatteCast virtual camera (found: '${name:-unknown device}')"
}

run_privileged() {
    if command -v sudo &>/dev/null && [ -t 0 ]; then
        sudo "$@"
    elif command -v pkexec &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        pkexec "$@"
    else
        return 1
    fi
}

ensure_virtual_camera() {
    if [ -e "$VCAM_DEVICE" ]; then
        validate_virtual_camera
        return 0
    fi
    echo "Virtual camera is missing; authorization is required to load v4l2loopback."

    if lsmod | grep -q '^v4l2loopback'; then
        fail "v4l2loopback is already loaded but $VCAM_DEVICE is absent. MatteCast will not unload a module that may belong to another application. Run ./install.sh and reboot, or reload v4l2loopback manually when it is safe."
    fi

    run_privileged "$MODPROBE_BIN" v4l2loopback \
        devices=1 "video_nr=$VCAM_NR" "card_label=$VCAM_LABEL" \
        exclusive_caps=1 max_buffers=2 max_openers=10 \
        || fail "cannot load v4l2loopback. Run ./install.sh or load it manually as root."
    sleep 1
    [ -e "$VCAM_DEVICE" ] || fail "virtual camera $VCAM_DEVICE was not created"
    validate_virtual_camera
}

ensure_virtual_camera

[ -L "$SHARED_HOST_DIR" ] && fail "runtime directory must not be a symlink: $SHARED_HOST_DIR"
if [ -e "$SHARED_HOST_DIR" ]; then
    [ -d "$SHARED_HOST_DIR" ] || fail "runtime path is not a directory: $SHARED_HOST_DIR"
    [ -O "$SHARED_HOST_DIR" ] || fail "unsafe runtime directory ownership: $SHARED_HOST_DIR"
fi
[ -L "$CONFIG_DIR" ] && fail "configuration directory must not be a symlink: $CONFIG_DIR"
if [ -e "$CONFIG_DIR" ]; then
    [ -d "$CONFIG_DIR" ] || fail "configuration path is not a directory: $CONFIG_DIR"
    [ -O "$CONFIG_DIR" ] || fail "unsafe configuration directory ownership: $CONFIG_DIR"
fi
install -d -m 700 "$SHARED_HOST_DIR" "$CONFIG_DIR"
printf '0\n' > "$SHARED_HOST_DIR/consumers"
chmod 600 "$SHARED_HOST_DIR/consumers"
rm -f "$SHARED_HOST_DIR/preview.jpg" "$SHARED_HOST_DIR/preview.jpg.tmp" \
      "$SHARED_HOST_DIR/cmd.pipe" "$SHARED_HOST_DIR/server.pid" "$SHARED_HOST_DIR/.xauth"

WATCHER_PID=""
if [ -x "$SCRIPT_DIR/scripts/vcam_watcher.sh" ]; then
    "$SCRIPT_DIR/scripts/vcam_watcher.sh" "$VCAM_DEVICE" "$SHARED_HOST_DIR" &
    WATCHER_PID=$!
fi

cleanup() {
    if container_exists && container_is_managed; then
        "$CONTAINER_CMD" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [ -n "$WATCHER_PID" ]; then
        kill "$WATCHER_PID" 2>/dev/null || true
        wait "$WATCHER_PID" 2>/dev/null || true
    fi
    rm -f "$SHARED_HOST_DIR/consumers" "$SHARED_HOST_DIR/preview.jpg" \
          "$SHARED_HOST_DIR/preview.jpg.tmp" "$SHARED_HOST_DIR/cmd.pipe" \
          "$SHARED_HOST_DIR/server.pid" "$SHARED_HOST_DIR/.xauth" 2>/dev/null || true
    rmdir "$SHARED_HOST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

GPU_ARGS=()
if [ "$CONTAINER_CMD" = "podman" ]; then
    GPU_ARGS+=(--device nvidia.com/gpu=all --userns=keep-id --group-add keep-groups)
else
    GPU_ARGS+=(--gpus all --user "$(id -u):$(id -g)")
    for group_name in video render; do
        gid="$(getent group "$group_name" 2>/dev/null | cut -d: -f3 || true)"
        [ -n "$gid" ] && GPU_ARGS+=(--group-add "$gid")
    done
fi

is_capture_device() {
    local dev="$1" caps value
    caps="$(v4l2-ctl -D -d "$dev" 2>/dev/null |
        awk '$1 == "Device" && $2 == "Caps" && $3 == ":" { print $4; exit }')"
    [[ "$caps" =~ ^0x[0-9A-Fa-f]+$ ]] || return 1
    value=$((caps))
    # V4L2_CAP_VIDEO_CAPTURE=0x00000001, V4L2_CAP_VIDEO_CAPTURE_MPLANE=0x00001000.
    (( (value & 0x00000001) != 0 || (value & 0x00001000) != 0 ))
}

command -v v4l2-ctl &>/dev/null || fail "v4l2-ctl is required to identify safe camera capture nodes"
CAMERA_ARGS=(--device "$VCAM_DEVICE:$VCAM_DEVICE")
for cam in /dev/video*; do
    [ -c "$cam" ] || continue
    [ "$cam" = "$VCAM_DEVICE" ] && continue
    if is_capture_device "$cam"; then
        CAMERA_ARGS+=(--device "$cam:$cam")
    fi
done

DISPLAY_ARGS=()
[ -n "${DISPLAY:-}" ] || fail "DISPLAY is not set; this hardened launcher currently requires X11/XWayland"
command -v xauth &>/dev/null || fail "xauth is required (Ubuntu: sudo apt install xauth; Fedora: sudo dnf install xorg-x11-xauth)"
XAUTH_FILE="$SHARED_HOST_DIR/.xauth"
touch "$XAUTH_FILE"
chmod 600 "$XAUTH_FILE"
if ! xauth nlist "$DISPLAY" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_FILE" nmerge - 2>/dev/null; then
    fail "could not create an isolated X11 authorization cookie"
fi
[ -s "$XAUTH_FILE" ] || fail "no X11 authorization cookie available for DISPLAY=$DISPLAY"
DISPLAY_ARGS+=(
    -e "DISPLAY=$DISPLAY"
    -e "XAUTHORITY=/run/mattecast.xauth"
    -v "/tmp/.X11-unix:/tmp/.X11-unix:ro"
    -v "$XAUTH_FILE:/run/mattecast.xauth:ro"
)

DBUS_ARGS=()
if [ "${MATTECAST_ENABLE_DBUS:-0}" = "1" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DBUS_SOCKET="${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
    DBUS_SOCKET="${DBUS_SOCKET%%,*}"
    if [ -S "$DBUS_SOCKET" ]; then
        warn "session D-Bus access enabled by MATTECAST_ENABLE_DBUS=1"
        DBUS_ARGS+=( -v "$DBUS_SOCKET:$DBUS_SOCKET" -e "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" )
    fi
fi

MEDIA_ARGS=()
if [ -d "$MEDIA_HOST_DIR" ]; then
    MEDIA_ARGS+=( -v "$MEDIA_HOST_DIR:/media/host:ro" )
else
    warn "background-image directory does not exist: $MEDIA_HOST_DIR"
    warn "set MATTECAST_MEDIA_DIR=/path/to/images to enable background browsing"
fi

SELINUX_ARGS=()
if [ "${MATTECAST_DISABLE_SELINUX_LABEL:-0}" = "1" ]; then
    warn "SELinux container labeling disabled by explicit request"
    SELINUX_ARGS+=(--security-opt label=disable)
fi

COMMON_ARGS=(
    --rm
    --name "$CONTAINER_NAME"
    --label "$MANAGED_LABEL=true"
    --network none
    --ipc private
    --cap-drop ALL
    --security-opt no-new-privileges
    --pids-limit 512
    --read-only
    --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=256m"
    -e "NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics,display"
    -e "NVIDIA_VISIBLE_DEVICES=all"
    -e "QT_QPA_PLATFORM=xcb"
    -e "QT_LOGGING_RULES=*.debug=false"
    -e "HOME=/tmp/mattecast-home"
    -e "XDG_CACHE_HOME=/tmp/mattecast-cache"
    -e "PYTHONDONTWRITEBYTECODE=1"
    -e "MATTECAST_CONFIG_DIR=/config"
    -e "MATTECAST_MEDIA_DIR=/media/host"
    -e "MATTECAST_SHARED_DIR=$CONTAINER_SHARED_DIR"
    -e "MATTECAST_VCAM_DEVICE=$VCAM_DEVICE"
    -v "$CONFIG_DIR:/config:rw"
    -v "$SHARED_HOST_DIR:$CONTAINER_SHARED_DIR:rw"
)

if [ "${MATTECAST_ENABLE_DRI:-0}" = "1" ] && [ -d /dev/dri ]; then
    warn "DRI device access enabled by MATTECAST_ENABLE_DRI=1"
    for dri in /dev/dri/*; do
        [ -e "$dri" ] && COMMON_ARGS+=( --device "$dri:$dri" )
    done
fi

printf 'Starting MatteCast with image %s\n' "$IMAGE_NAME"
"$CONTAINER_CMD" run \
    "${COMMON_ARGS[@]}" \
    "${GPU_ARGS[@]}" \
    "${CAMERA_ARGS[@]}" \
    "${DISPLAY_ARGS[@]}" \
    "${DBUS_ARGS[@]}" \
    "${MEDIA_ARGS[@]}" \
    "${SELINUX_ARGS[@]}" \
    "$IMAGE_NAME"
