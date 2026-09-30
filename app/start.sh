#!/bin/bash
set -euo pipefail

cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "${MATTECAST_CONFIG_DIR:-/config}" "${MATTECAST_SHARED_DIR:-/run/mattecast}" \
         "${HOME:-/tmp/mattecast-home}" "${XDG_CACHE_HOME:-/tmp/mattecast-cache}"

echo "Starting MatteCast RVM server..."
/app/mattecast_server &
SERVER_PID=$!

for _ in $(seq 1 30); do
    [ -p "${MATTECAST_SHARED_DIR:-/run/mattecast}/cmd.pipe" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "MatteCast server exited during startup" >&2; exit 1; }
    sleep 0.5
done
[ -p "${MATTECAST_SHARED_DIR:-/run/mattecast}/cmd.pipe" ] || { echo "MatteCast command pipe was not created" >&2; exit 1; }

echo "Starting MatteCast GUI..."
python3 /app/control_panel.py
