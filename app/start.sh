#!/bin/bash
set -euo pipefail

terminate_child() {
    local pid="$1" name="$2" watchdog_pid
    [ -n "$pid" ] || return 0

    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        (
            sleep 3
            if kill -0 "$pid" 2>/dev/null; then
                echo "$name did not stop after SIGTERM; forcing shutdown." >&2
                kill -KILL "$pid" 2>/dev/null || true
            fi
        ) &
        watchdog_pid=$!
    else
        watchdog_pid=""
    fi

    wait "$pid" 2>/dev/null || true
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
}

stop_server() {
    [ -n "${SERVER_PID:-}" ] || return 0
    terminate_child "$SERVER_PID" "MatteCast server"
    SERVER_PID=""
}

stop_gui() {
    [ -n "${GUI_PID:-}" ] || return 0
    terminate_child "$GUI_PID" "MatteCast GUI"
    GUI_PID=""
}

cleanup() {
    stop_gui
    stop_server
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
python3 /app/control_panel.py &
GUI_PID=$!

# Whichever side exits first owns the shutdown path. Normally the GUI exits
# first and the server follows its QUIT command. If the server exits first
# (including the observed X11/Qt shutdown edge case), do not leave the GUI or
# container attached forever.
set +e
FIRST_PID=""
wait -n -p FIRST_PID "$SERVER_PID" "$GUI_PID"
FIRST_RC=$?
set -e

if [ "$FIRST_PID" = "$GUI_PID" ]; then
    GUI_PID=""
    stop_server
    SERVER_PID=""
    trap - EXIT
    exit "$FIRST_RC"
fi

SERVER_PID=""
if [ "$FIRST_RC" -ne 0 ]; then
    echo "MatteCast server exited unexpectedly (status $FIRST_RC)." >&2
fi

# Give Qt a brief chance to finish naturally after the server has shut down.
# If it is stuck in X11/tray teardown, bound the wait and terminate it.
GUI_WATCHDOG_PID=""
if kill -0 "$GUI_PID" 2>/dev/null; then
    (
        sleep 2
        if kill -0 "$GUI_PID" 2>/dev/null; then
            echo "MatteCast GUI did not exit after server shutdown; terminating it." >&2
            kill "$GUI_PID" 2>/dev/null || true
            sleep 1
            if kill -0 "$GUI_PID" 2>/dev/null; then
                echo "MatteCast GUI did not stop after SIGTERM; forcing shutdown." >&2
                kill -KILL "$GUI_PID" 2>/dev/null || true
            fi
        fi
    ) &
    GUI_WATCHDOG_PID=$!
fi

set +e
wait "$GUI_PID" 2>/dev/null
GUI_RC=$?
set -e
GUI_PID=""
if [ -n "$GUI_WATCHDOG_PID" ]; then
    kill "$GUI_WATCHDOG_PID" 2>/dev/null || true
    wait "$GUI_WATCHDOG_PID" 2>/dev/null || true
fi

trap - EXIT
if [ "$FIRST_RC" -ne 0 ]; then
    exit "$FIRST_RC"
fi
# A clean server exit is authoritative for the user-initiated Quit path. The
# GUI may have required watchdog termination only because its Qt/X11 teardown
# was stuck after the server already closed cleanly.
exit 0
