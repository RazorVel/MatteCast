#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/mattecast-tests-$UID"
trap 'rm -rf "$BUILD_DIR"' EXIT
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

scripts=("$ROOT/install.sh" "$ROOT/run.sh" "$ROOT/app/start.sh" "$ROOT/scripts/"*.sh)

echo "[1/12] Shell syntax + watcher zero-consumer regression"
for script in "${scripts[@]}"; do bash -n "$script"; done

# lsof returns status 1 when nobody has the device open. The watcher must
# remain alive and report zero rather than terminate under pipefail/set -e.
WATCHER_TEST="$BUILD_DIR/watcher-zero"
mkdir -p "$WATCHER_TEST/bin" "$WATCHER_TEST/shared"
touch "$WATCHER_TEST/video10"

cat > "$WATCHER_TEST/bin/lsof" <<'SH'
#!/bin/sh
exit 1
SH
chmod 0755 "$WATCHER_TEST/bin/lsof"

watcher_rc=0
PATH="$WATCHER_TEST/bin:/usr/bin:/bin" \
    timeout 2s bash "$ROOT/scripts/vcam_watcher.sh" \
        "$WATCHER_TEST/video10" "$WATCHER_TEST/shared" || watcher_rc=$?

[ "$watcher_rc" -eq 124 ] || {
    echo "vcam watcher exited during zero-consumer state" >&2
    exit 1
}
[ "$(cat "$WATCHER_TEST/shared/consumers")" = "0" ]
rm -rf "$WATCHER_TEST"

echo "[2/12] Python syntax"
python3 - "$ROOT/app/control_panel.py" \
    "$ROOT/tests/test_security.py" \
    "$ROOT/tests/test_control_security.py" \
    "$ROOT/tests/test_model_security.py" \
    "$ROOT/tests/test_host_config_safety.py" \
    "$ROOT/tests/test_source_tree.py" <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:]:
    source = Path(name).read_text(encoding="utf-8")
    compile(source, name, "exec")
PY

echo "[3/12] Command parser unit tests"
g++ -std=c++17 -Wall -Wextra -Werror \
    "$ROOT/tests/test_command_parser.cpp" -o "$BUILD_DIR/test_command_parser"
"$BUILD_DIR/test_command_parser"

echo "[4/12] Command parser deterministic fuzz test"
g++ -std=c++17 -Wall -Wextra -Werror \
    "$ROOT/tests/test_command_parser_fuzz.cpp" -o "$BUILD_DIR/test_command_parser_fuzz"
"$BUILD_DIR/test_command_parser_fuzz"

echo "[5/12] RVM math/compositing helpers"
g++ -std=c++17 -Wall -Wextra -Werror \
    "$ROOT/tests/test_rvm_math.cpp" -o "$BUILD_DIR/test_rvm_math"
"$BUILD_DIR/test_rvm_math"

echo "[6/12] RVM/server syntax with API stubs"
g++ -std=c++17 -Wall -Wextra -Werror -fsyntax-only \
    -I "$ROOT/tests/stubs/server" -I "$ROOT/app" \
    "$ROOT/app/rvm_processor.cpp" "$ROOT/app/server.cpp"

echo "[7/12] Control/settings security tests"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_control_security.py"

echo "[8/12] Model/dependency supply-chain tests"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_model_security.py"

echo "[9/12] Host configuration safety tests"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_host_config_safety.py"

echo "[10/12] Parser sanitizers"
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$ROOT/tests/test_command_parser_fuzz.cpp" -o "$BUILD_DIR/test_command_parser_fuzz_san"
"$BUILD_DIR/test_command_parser_fuzz_san"

echo "[11/12] Security regression tests"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_security.py"

echo "[12/12] Source tree hygiene"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test_source_tree.py"

echo "All non-hardware tests passed."
