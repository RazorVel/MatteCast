#!/bin/bash
set -euo pipefail

cat >&2 <<'MSG'
MatteCast hardened build: remote prebuilt installation is intentionally disabled.

Reason:
  This source tree is built locally so the executable exactly matches the
  audited source. Running a mutable third-party prebuilt image would bypass
  those guarantees.

Use:
  1. Run ./scripts/fetch-rvm-model.sh to fetch the pinned official RVM model.
  2. Run ./install.sh from this project directory.

The local installer builds and launches only the patched local image.
MSG
exit 2
