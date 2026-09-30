#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "  ${BLUE}→${NC} $*"; }
done_msg() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }

MATTECAST_MODULES_CONF="/etc/modules-load.d/83-mattecast-v4l2loopback.conf"
MATTECAST_MODPROBE_CONF="/etc/modprobe.d/83-mattecast-v4l2loopback.conf"
MATTECAST_UDEV_RULE="/etc/udev/rules.d/83-mattecast-vcam.rules"
MATTECAST_OPTIONS_RE='^options v4l2loopback devices=1 video_nr=[0-9]+ card_label="MatteCast Virtual Camera" exclusive_caps=1 max_buffers=2 max_openers=10$'
MATTECAST_UDEV='SUBSYSTEM=="video4linux", ATTR{name}=="MatteCast Virtual Camera", GROUP="video", MODE="0660", TAG+="uaccess"'

# Legacy BluCast identifiers are retained only for exact-match cleanup.
LEGACY_BLUCAST_MODULES_CONF="/etc/modules-load.d/83-blucast-v4l2loopback.conf"
LEGACY_BLUCAST_MODPROBE_CONF="/etc/modprobe.d/83-blucast-v4l2loopback.conf"
LEGACY_BLUCAST_UDEV_RULE="/etc/udev/rules.d/83-blucast-vcam.rules"
LEGACY_BLUCAST_OPTIONS_RE='^options v4l2loopback devices=1 video_nr=[0-9]+ card_label="BluCast Virtual Camera" exclusive_caps=1 max_buffers=2 max_openers=10$'
LEGACY_BLUCAST_UDEV='SUBSYSTEM=="video4linux", ATTR{name}=="BluCast Virtual Camera", GROUP="video", MODE="0660", TAG+="uaccess"'
LEGACY_MODULES_CONF="/etc/modules-load.d/v4l2loopback.conf"
LEGACY_MODPROBE_CONF="/etc/modprobe.d/v4l2loopback.conf"
LEGACY_SUDOERS="/etc/sudoers.d/blucast-v4l2loopback"
CURRENT_USER="$(id -un)"
LEGACY_SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/modprobe v4l2loopback *"

exact_file() {
    local path="$1" expected="$2"
    [ -f "$path" ] && [ ! -L "$path" ] && [ "$(cat -- "$path" 2>/dev/null || true)" = "$expected" ]
}

remove_exact_module_file() {
    local path="$1"
    if exact_file "$path" "v4l2loopback"; then
        sudo rm -f -- "$path"
    elif [ -e "$path" ]; then
        warn "Left modified $path untouched."
    fi
}

remove_matching_options_file() {
    local path="$1" regex="$2"
    if [ -f "$path" ] && [ ! -L "$path" ] && grep -Eq "$regex" "$path" 2>/dev/null; then
        sudo rm -f -- "$path"
    elif [ -e "$path" ]; then
        warn "Left modified $path untouched."
    fi
}

echo -e "\n${YELLOW}MatteCast uninstaller${NC}\n"

step "Stopping MatteCast and legacy BluCast containers..."
for cmd in podman docker; do
    command -v "$cmd" &>/dev/null || continue
    for name in "mattecast-${UID}" "blucast-${UID}"; do
        ids=$($cmd ps -q --filter "name=$name" 2>/dev/null || true)
        [ -n "$ids" ] && $cmd stop $ids 2>/dev/null || true
    done
done
done_msg "Containers stopped"

step "Killing watcher processes..."
pkill -f "[v]cam_watcher.sh.*mattecast" 2>/dev/null || true
pkill -f "[v]cam_watcher.sh.*blucast" 2>/dev/null || true
done_msg "Watchers stopped"

step "Removing MatteCast-owned system configuration..."
remove_exact_module_file "$MATTECAST_MODULES_CONF"
remove_matching_options_file "$MATTECAST_MODPROBE_CONF" "$MATTECAST_OPTIONS_RE"
if exact_file "$MATTECAST_UDEV_RULE" "$MATTECAST_UDEV"; then
    sudo rm -f -- "$MATTECAST_UDEV_RULE"
elif [ -e "$MATTECAST_UDEV_RULE" ]; then
    warn "Left modified $MATTECAST_UDEV_RULE untouched."
fi

done_msg "MatteCast-specific system configuration removed"

step "Removing exact legacy BluCast configuration if present..."
legacy_named_owned=0
if exact_file "$LEGACY_BLUCAST_MODULES_CONF" "v4l2loopback" && \
   [ -f "$LEGACY_BLUCAST_MODPROBE_CONF" ] && [ ! -L "$LEGACY_BLUCAST_MODPROBE_CONF" ] && \
   grep -Eq "$LEGACY_BLUCAST_OPTIONS_RE" "$LEGACY_BLUCAST_MODPROBE_CONF" 2>/dev/null && \
   exact_file "$LEGACY_BLUCAST_UDEV_RULE" "$LEGACY_BLUCAST_UDEV"; then
    legacy_named_owned=1
fi

legacy_generic_owned=0
if exact_file "$LEGACY_MODULES_CONF" "v4l2loopback" && \
   [ -f "$LEGACY_MODPROBE_CONF" ] && [ ! -L "$LEGACY_MODPROBE_CONF" ] && \
   grep -Eq "$LEGACY_BLUCAST_OPTIONS_RE" "$LEGACY_MODPROBE_CONF" 2>/dev/null && \
   exact_file "$LEGACY_BLUCAST_UDEV_RULE" "$LEGACY_BLUCAST_UDEV"; then
    legacy_generic_owned=1
fi

if [ "$legacy_named_owned" = "1" ]; then
    sudo rm -f -- "$LEGACY_BLUCAST_MODULES_CONF" "$LEGACY_BLUCAST_MODPROBE_CONF" "$LEGACY_BLUCAST_UDEV_RULE"
    done_msg "Removed exact legacy BluCast namespaced configuration"
elif [ "$legacy_generic_owned" = "1" ]; then
    sudo rm -f -- "$LEGACY_MODULES_CONF" "$LEGACY_MODPROBE_CONF" "$LEGACY_BLUCAST_UDEV_RULE"
    done_msg "Removed exact legacy BluCast generic configuration"
else
    for path in "$LEGACY_BLUCAST_MODULES_CONF" "$LEGACY_BLUCAST_MODPROBE_CONF" "$LEGACY_BLUCAST_UDEV_RULE"; do
        [ -e "$path" ] && warn "Left legacy path untouched because exact ownership could not be proven: $path"
    done
    if [ -e "$LEGACY_MODPROBE_CONF" ] || [ -e "$LEGACY_MODULES_CONF" ]; then
        warn "Generic v4l2loopback configuration was left untouched because ownership cannot be proven."
    fi
fi

if [ -e "$LEGACY_SUDOERS" ]; then
    if sudo grep -Fqx -- "$LEGACY_SUDOERS_LINE" "$LEGACY_SUDOERS" 2>/dev/null; then
        sudo rm -f -- "$LEGACY_SUDOERS"
        done_msg "Removed exact legacy passwordless modprobe rule"
    else
        warn "Left $LEGACY_SUDOERS untouched because its contents do not match the known legacy BluCast rule."
    fi
fi

# Never unload the global module: another application may currently use it.
sudo udevadm control --reload-rules 2>/dev/null || true
done_msg "Loaded v4l2loopback remains until reboot/manual reload"

step "Removing user configuration and desktop entries..."
rm -rf -- "$HOME/.config/mattecast" "$HOME/.config/blucast"
rm -f -- "$HOME/.local/share/applications/mattecast.desktop" "$HOME/.local/share/applications/blucast.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
done_msg "User files removed"

step "Cleaning runtime files..."
for dir in \
    "${XDG_RUNTIME_DIR:-/tmp}/mattecast-${UID}" \
    "/tmp/mattecast-${UID}" "/tmp/mattecast" \
    "${XDG_RUNTIME_DIR:-/tmp}/blucast-${UID}" \
    "/tmp/blucast-${UID}" "/tmp/blucast"; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ]; then
        rm -f -- "$dir"
    elif [ -O "$dir" ]; then
        rm -rf -- "$dir"
    else
        warn "Skipped runtime directory not owned by current user: $dir"
    fi
done
done_msg "Runtime files cleaned"

step "Removing local images..."
for cmd in podman docker; do
    command -v "$cmd" &>/dev/null || continue
    for img in \
        "mattecast:hardened-local" "localhost/mattecast:hardened-local" \
        "blucast:hardened-local" "localhost/blucast:hardened-local"; do
        $cmd rmi "$img" 2>/dev/null || true
    done
done
done_msg "Local images removed"

echo -e "\n${GREEN}MatteCast uninstalled.${NC}\n"
