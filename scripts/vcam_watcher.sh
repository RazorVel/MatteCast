#!/bin/bash
set -euo pipefail
umask 077

VCAM_DEVICE="${1:-/dev/video10}"
SHARED_DIR="${2:-${XDG_RUNTIME_DIR:-/tmp}/mattecast-${UID}}"
CONSUMERS_FILE="$SHARED_DIR/consumers"

if [ -L "$SHARED_DIR" ]; then
    echo "Refusing symlink runtime directory: $SHARED_DIR" >&2
    exit 1
fi
if [ -e "$SHARED_DIR" ]; then
    [ -d "$SHARED_DIR" ] || { echo "Refusing non-directory runtime path: $SHARED_DIR" >&2; exit 1; }
    [ -O "$SHARED_DIR" ] || { echo "Refusing unsafe runtime directory ownership: $SHARED_DIR" >&2; exit 1; }
fi
install -d -m 700 "$SHARED_DIR"
write_count() {
    local value="$1" tmp
    tmp=$(mktemp "$SHARED_DIR/.consumers.XXXXXX")
    chmod 600 "$tmp"
    printf '%s\n' "$value" > "$tmp"
    mv -fT -- "$tmp" "$CONSUMERS_FILE"
}
write_count 0

count_with_lsof() {
    { lsof "$VCAM_DEVICE" 2>/dev/null || true; } | awk '
        NR > 1 && $4 ~ /[0-9]+[ru]$/ { pids[$2] = 1 }
        END { print length(pids) }
    '
}

count_with_fuser() {
    local pids total n
    pids=$(fuser "$VCAM_DEVICE" 2>/dev/null) || true
    total=$(wc -w <<<"$pids")
    n=$((total - 1))
    [ "$n" -lt 0 ] && n=0
    echo "$n"
}

if command -v lsof &>/dev/null; then
    COUNT_FN="count_with_lsof"
elif command -v fuser &>/dev/null; then
    COUNT_FN="count_with_fuser"
else
    echo "Warning: neither lsof nor fuser available. Consumer detection disabled." >&2
    while true; do write_count 0; sleep 5; done
fi

while true; do
    if [ ! -e "$VCAM_DEVICE" ]; then
        write_count 0
        sleep 2
        continue
    fi

    n=$($COUNT_FN)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    write_count "$n"
    sleep 1
done
