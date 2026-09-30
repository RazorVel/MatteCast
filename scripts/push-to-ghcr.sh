#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'MSG'
Remote image publishing is intentionally disabled by default.

Reason:
  Publishing a mutable `latest` tag would reintroduce the supply-chain ambiguity
  removed by the hardened launcher. Test the locally-built image first.

If you later publish a release image, use a versioned tag plus an immutable
content digest, sign that digest, and configure MATTECAST_IMAGE explicitly to the
resulting image@sha256:... reference.
MSG
exit 2
