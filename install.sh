#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="mattecast:hardened-local"
VCAM_DEVICE="${MATTECAST_VCAM_DEVICE:-/dev/video10}"
[[ "$VCAM_DEVICE" =~ ^/dev/video[0-9]+$ ]] || { echo "Invalid MATTECAST_VCAM_DEVICE: $VCAM_DEVICE" >&2; exit 1; }
VCAM_NR="${VCAM_DEVICE#/dev/video}"
VCAM_LABEL="MatteCast Virtual Camera"

MATTECAST_MODULES_CONF="/etc/modules-load.d/83-mattecast-v4l2loopback.conf"
MATTECAST_MODPROBE_CONF="/etc/modprobe.d/83-mattecast-v4l2loopback.conf"
MATTECAST_UDEV_RULE="/etc/udev/rules.d/83-mattecast-vcam.rules"

# Exact legacy BluCast identifiers are retained only for safe migration/cleanup.
LEGACY_BLUCAST_LABEL="BluCast Virtual Camera"
LEGACY_BLUCAST_MODULES_CONF="/etc/modules-load.d/83-blucast-v4l2loopback.conf"
LEGACY_BLUCAST_MODPROBE_CONF="/etc/modprobe.d/83-blucast-v4l2loopback.conf"
LEGACY_BLUCAST_UDEV_RULE="/etc/udev/rules.d/83-blucast-vcam.rules"
LEGACY_SUDOERS="/etc/sudoers.d/blucast-v4l2loopback"
LEGACY_MODULES_CONF="/etc/modules-load.d/v4l2loopback.conf"
LEGACY_MODPROBE_CONF="/etc/modprobe.d/v4l2loopback.conf"

EXPECTED_OPTIONS="options v4l2loopback devices=1 video_nr=${VCAM_NR} card_label=\"${VCAM_LABEL}\" exclusive_caps=1 max_buffers=2 max_openers=10"
EXPECTED_UDEV="SUBSYSTEM==\"video4linux\", ATTR{name}==\"${VCAM_LABEL}\", GROUP=\"video\", MODE=\"0660\", TAG+=\"uaccess\""
LEGACY_BLUCAST_OPTIONS="options v4l2loopback devices=1 video_nr=${VCAM_NR} card_label=\"${LEGACY_BLUCAST_LABEL}\" exclusive_caps=1 max_buffers=2 max_openers=10"
LEGACY_BLUCAST_UDEV="SUBSYSTEM==\"video4linux\", ATTR{name}==\"${LEGACY_BLUCAST_LABEL}\", GROUP=\"video\", MODE=\"0660\", TAG+=\"uaccess\""

MODEL="$SCRIPT_DIR/models/rvm_mobilenetv3_fp32.onnx"
MODEL_SHA256="88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828"
MODEL_SIZE=14975696
CURRENT_USER="$(id -un)"
LEGACY_SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/modprobe v4l2loopback *"

log()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
die()  { echo -e "  ${RED}✗${NC} $*"; exit 1; }

exact_file() {
    local path="$1" expected="$2"
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(cat -- "$path" 2>/dev/null || true)" = "$expected" ]
}

video_name() {
    local dev="$1" base
    base="${dev##*/}"
    [ -r "/sys/class/video4linux/$base/name" ] || return 1
    cat "/sys/class/video4linux/$base/name"
}

echo -e "\n${BLUE}══════════════════════════════════════${NC}"
echo -e "${BLUE}      MatteCast Hardened Installer${NC}"
echo -e "${BLUE}══════════════════════════════════════${NC}\n"

echo -e "${BLUE}[1/5]${NC} Checking prerequisites..."
[ "$(uname -m)" = "x86_64" ] || die "This build currently supports Linux x86_64 only."
if command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
else
    die "Podman or Docker required."
fi
log "Container runtime: $CONTAINER_CMD"

command -v nvidia-smi &>/dev/null || die "NVIDIA driver not found. Install NVIDIA drivers first."
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
[ -n "$GPU_NAME" ] || die "nvidia-smi could not query a GPU"
log "GPU: $GPU_NAME"
command -v sha256sum &>/dev/null || die "sha256sum is required"

ACTIVE_LEGACY_BLUCAST=0
if [ -e "$VCAM_DEVICE" ]; then
    NAME="$(video_name "$VCAM_DEVICE" 2>/dev/null || true)"
    case "$NAME" in
        "$VCAM_LABEL") ;;
        "$LEGACY_BLUCAST_LABEL") ACTIVE_LEGACY_BLUCAST=1 ;;
        *) die "$VCAM_DEVICE is already used by '${NAME:-unknown device}'. Choose a free MATTECAST_VCAM_DEVICE before installing." ;;
    esac
fi

echo -e "${BLUE}[2/5]${NC} Verifying RVM model..."
[ -f "$MODEL" ] && [ ! -L "$MODEL" ] || die "RVM model missing. Run ./scripts/fetch-rvm-model.sh first."
[ "$(stat -c %s -- "$MODEL")" = "$MODEL_SIZE" ] || die "RVM model size mismatch; remove it and run ./scripts/fetch-rvm-model.sh again."
printf '%s  %s\n' "$MODEL_SHA256" "$MODEL" | sha256sum -c - >/dev/null 2>&1 \
    || die "RVM model checksum mismatch; remove it and run ./scripts/fetch-rvm-model.sh again."
log "RVM model verified"

install_host_package() {
    local apt_pkg="$1" dnf_pkg="${2:-$1}"
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y "$apt_pkg"
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y "$dnf_pkg"
    else
        return 1
    fi
}

command -v xauth &>/dev/null || install_host_package xauth xorg-x11-xauth || die "xauth is required"
command -v v4l2-ctl &>/dev/null || install_host_package v4l-utils v4l-utils || die "v4l2-ctl is required"
for tool_pkg in "lsof lsof" "fuser psmisc"; do
    tool="${tool_pkg%% *}"; pkg="${tool_pkg##* }"
    if ! command -v "$tool" &>/dev/null; then
        install_host_package "$pkg" "$pkg" >/dev/null 2>&1 || true
    fi
done

# Remove only the exact vulnerable sudoers rule written by older BluCast versions.
if [ -e "$LEGACY_SUDOERS" ]; then
    if sudo grep -Fqx -- "$LEGACY_SUDOERS_LINE" "$LEGACY_SUDOERS" 2>/dev/null; then
        sudo rm -f -- "$LEGACY_SUDOERS"
        log "Removed exact legacy passwordless modprobe rule"
    else
        warn "Left $LEGACY_SUDOERS untouched because its contents do not match the known legacy BluCast rule."
    fi
fi

echo -e "${BLUE}[3/5]${NC} Setting up virtual camera..."
if ! modinfo v4l2loopback &>/dev/null 2>&1; then
    echo "  Installing v4l2loopback..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y v4l2loopback kmod-v4l2loopback 2>/dev/null \
            || sudo dnf install -y v4l2loopback 2>/dev/null \
            || die "Failed to install v4l2loopback"
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y v4l2loopback-dkms v4l2loopback-utils \
            || die "Failed to install v4l2loopback"
    else
        die "Unsupported package manager. Install v4l2loopback manually."
    fi
fi
modinfo v4l2loopback &>/dev/null 2>&1 || die "v4l2loopback module not available; a reboot may be required"

# Prove ownership of legacy BluCast configuration before migrating/removing it.
legacy_blucast_named_owned=0
if exact_file "$LEGACY_BLUCAST_MODULES_CONF" "v4l2loopback" && \
   exact_file "$LEGACY_BLUCAST_MODPROBE_CONF" "$LEGACY_BLUCAST_OPTIONS" && \
   exact_file "$LEGACY_BLUCAST_UDEV_RULE" "$LEGACY_BLUCAST_UDEV"; then
    legacy_blucast_named_owned=1
fi

legacy_blucast_generic_owned=0
if exact_file "$LEGACY_MODULES_CONF" "v4l2loopback" && \
   exact_file "$LEGACY_MODPROBE_CONF" "$LEGACY_BLUCAST_OPTIONS" && \
   exact_file "$LEGACY_BLUCAST_UDEV_RULE" "$LEGACY_BLUCAST_UDEV"; then
    legacy_blucast_generic_owned=1
fi

if [ "$ACTIVE_LEGACY_BLUCAST" = "1" ] && \
   [ "$legacy_blucast_named_owned" != "1" ] && \
   [ "$legacy_blucast_generic_owned" != "1" ]; then
    die "$VCAM_DEVICE is the legacy BluCast virtual camera, but its host configuration ownership cannot be verified; refusing automatic migration."
fi

# Refuse to overwrite MatteCast-owned files if an administrator has changed them.
if [ -e "$MATTECAST_MODULES_CONF" ] && ! exact_file "$MATTECAST_MODULES_CONF" "v4l2loopback"; then
    die "$MATTECAST_MODULES_CONF already exists with unexpected contents; refusing to overwrite it."
fi
if [ -e "$MATTECAST_MODPROBE_CONF" ] && ! exact_file "$MATTECAST_MODPROBE_CONF" "$EXPECTED_OPTIONS"; then
    die "$MATTECAST_MODPROBE_CONF already exists with unexpected contents; refusing to overwrite it."
fi
if [ -e "$MATTECAST_UDEV_RULE" ] && ! exact_file "$MATTECAST_UDEV_RULE" "$EXPECTED_UDEV"; then
    die "$MATTECAST_UDEV_RULE already exists with unexpected contents; refusing to overwrite it."
fi

# Refuse to compete with unrelated v4l2loopback options. Exact legacy BluCast
# files proven above are allowed only so they can be migrated safely.
for conf in /etc/modprobe.d/*; do
    [ -f "$conf" ] || continue
    [ "$conf" = "$MATTECAST_MODPROBE_CONF" ] && continue
    if [ "$conf" = "$LEGACY_BLUCAST_MODPROBE_CONF" ] && [ "$legacy_blucast_named_owned" = "1" ]; then
        continue
    fi
    if [ "$conf" = "$LEGACY_MODPROBE_CONF" ] && [ "$legacy_blucast_generic_owned" = "1" ]; then
        continue
    fi
    if grep -Eq '^[[:space:]]*options[[:space:]]+v4l2loopback([[:space:]]|$)' "$conf" 2>/dev/null; then
        die "Existing v4l2loopback options found in $conf. Refusing to overwrite/compete with another virtual-camera configuration. Integrate MatteCast manually or remove the conflict first."
    fi
done

printf 'v4l2loopback\n' | sudo tee "$MATTECAST_MODULES_CONF" >/dev/null
printf '%s\n' "$EXPECTED_OPTIONS" | sudo tee "$MATTECAST_MODPROBE_CONF" >/dev/null
printf '%s\n' "$EXPECTED_UDEV" | sudo tee "$MATTECAST_UDEV_RULE" >/dev/null

# Remove only exact legacy BluCast configuration after the replacement exists.
if [ "$legacy_blucast_named_owned" = "1" ]; then
    sudo rm -f -- "$LEGACY_BLUCAST_MODULES_CONF" "$LEGACY_BLUCAST_MODPROBE_CONF" "$LEGACY_BLUCAST_UDEV_RULE"
    log "Migrated exact legacy BluCast namespaced configuration"
elif [ "$legacy_blucast_generic_owned" = "1" ]; then
    sudo rm -f -- "$LEGACY_MODULES_CONF" "$LEGACY_MODPROBE_CONF" "$LEGACY_BLUCAST_UDEV_RULE"
    log "Migrated exact legacy BluCast generic configuration"
fi

sudo udevadm control --reload-rules 2>/dev/null || true
log "Persistent MatteCast-specific module and udev configuration installed"

REBOOT_REQUIRED=0
if [ "$ACTIVE_LEGACY_BLUCAST" = "1" ]; then
    REBOOT_REQUIRED=1
    warn "Legacy BluCast v4l2loopback instance is still loaded as '$LEGACY_BLUCAST_LABEL'."
    warn "Reboot once to activate the new '$VCAM_LABEL' module configuration."
elif [ ! -e "$VCAM_DEVICE" ]; then
    if lsmod | grep -q '^v4l2loopback'; then
        die "v4l2loopback is already loaded without $VCAM_DEVICE. Refusing to unload a module that may be used by OBS/other apps. Close other virtual-camera users and reboot once so the new MatteCast module options take effect."
    fi
    sudo modprobe v4l2loopback \
        devices=1 video_nr="$VCAM_NR" card_label="$VCAM_LABEL" \
        exclusive_caps=1 max_buffers=2 max_openers=10
    sleep 1
fi

if [ "$REBOOT_REQUIRED" = "0" ]; then
    [ -e "$VCAM_DEVICE" ] || die "Failed to create virtual camera at $VCAM_DEVICE"
    NAME="$(video_name "$VCAM_DEVICE" 2>/dev/null || true)"
    [ "$NAME" = "$VCAM_LABEL" ] || die "$VCAM_DEVICE exists but is not the MatteCast virtual camera (found: '${NAME:-unknown}')."
    sudo udevadm trigger --action=change "$VCAM_DEVICE" 2>/dev/null || true
    log "Virtual camera active at $VCAM_DEVICE"

    if [ ! -r "$VCAM_DEVICE" ] || [ ! -w "$VCAM_DEVICE" ]; then
        warn "Your current session does not yet have read/write access to $VCAM_DEVICE."
        warn "Logging out/in normally refreshes uaccess ACLs; do not chmod the device to 0666."
    fi
fi

# Preserve user settings when upgrading from BluCast, but never merge through
# symlinks or overwrite an existing MatteCast configuration directory.
LEGACY_CONFIG_DIR="$HOME/.config/blucast"
CONFIG_DIR="$HOME/.config/mattecast"
if [ ! -e "$CONFIG_DIR" ] && [ -d "$LEGACY_CONFIG_DIR" ] && [ ! -L "$LEGACY_CONFIG_DIR" ] && [ -O "$LEGACY_CONFIG_DIR" ]; then
    mv -- "$LEGACY_CONFIG_DIR" "$CONFIG_DIR"
    log "Migrated user configuration from BluCast to MatteCast"
elif [ -e "$LEGACY_CONFIG_DIR" ] && [ -e "$CONFIG_DIR" ]; then
    warn "Both legacy BluCast and MatteCast user configuration exist; left the legacy directory untouched."
fi

echo -e "${BLUE}[4/5]${NC} Building patched local container image..."
cd "$SCRIPT_DIR"
if [ "$CONTAINER_CMD" = "podman" ]; then
    "$CONTAINER_CMD" build --pull=missing -t "$IMAGE_NAME" -f Containerfile . \
        || die "Container build failed."
else
    "$CONTAINER_CMD" build --pull -t "$IMAGE_NAME" -f Containerfile . \
        || die "Container build failed."
fi
log "Container image built locally as $IMAGE_NAME"

echo -e "${BLUE}[5/5]${NC} Creating desktop entry..."
chmod +x "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/scripts/fetch-rvm-model.sh" "$SCRIPT_DIR/scripts/vcam_watcher.sh" "$SCRIPT_DIR/scripts/uninstall.sh"
DESKTOP_FILE="$HOME/.local/share/applications/mattecast.desktop"
LEGACY_DESKTOP_FILE="$HOME/.local/share/applications/blucast.desktop"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Name=MatteCast
Comment=AI-Powered Virtual Camera (hardened local build)
Exec=$SCRIPT_DIR/run.sh
Icon=$SCRIPT_DIR/assets/logo.png
Terminal=false
Type=Application
Categories=Video;AudioVideo;
StartupWMClass=mattecast
DESKTOP
if [ -f "$LEGACY_DESKTOP_FILE" ] && [ ! -L "$LEGACY_DESKTOP_FILE" ] && [ -O "$LEGACY_DESKTOP_FILE" ]; then
    if grep -Fqx 'Name=BluCast' "$LEGACY_DESKTOP_FILE" 2>/dev/null && \
       grep -Fqx 'StartupWMClass=blucast' "$LEGACY_DESKTOP_FILE" 2>/dev/null; then
        rm -f -- "$LEGACY_DESKTOP_FILE"
        log "Removed legacy BluCast desktop entry"
    else
        warn "Left modified legacy desktop entry untouched: $LEGACY_DESKTOP_FILE"
    fi
fi
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
log "Desktop entry installed"

echo -e "\n${GREEN}Installation complete.${NC}"
if [ "$REBOOT_REQUIRED" = "1" ]; then
    echo -e "  ${YELLOW}Reboot required once before launching MatteCast.${NC}"
fi
echo -e "  Launch:    ${BLUE}$SCRIPT_DIR/run.sh${NC}"
echo -e "  Uninstall: ${BLUE}$SCRIPT_DIR/scripts/uninstall.sh${NC}"
