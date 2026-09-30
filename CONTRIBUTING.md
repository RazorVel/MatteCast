# Contributing to MatteCast

## Bug reports

Include:

- clear reproduction steps;
- expected vs actual behavior;
- Linux distribution/kernel;
- GPU and NVIDIA driver version;
- Docker/Podman version;
- camera model and relevant `v4l2-ctl` output;
- terminal logs with secrets/personal paths removed when appropriate.

## Pull requests

1. Branch from the current source tree.
2. Preserve the hardened runtime boundary unless the change explicitly requires
   broader access and documents why.
3. Keep network/model/dependency downloads content-pinned.
4. Add or update tests for behavior/security changes.
5. Run `./tests/run_tests.sh` before submitting.
6. Update documentation when interfaces or installation behavior changes.

## Development setup

Requirements:

- Linux x86_64;
- C++17 compiler and CMake;
- Python 3.8+ for GUI/test tooling;
- Docker/Podman + NVIDIA container integration for full GPU testing;
- NVIDIA GPU/driver for hardware validation;
- v4l2loopback and v4l-utils for virtual-camera testing.

Setup:

```bash
git clone <your-fork>
cd mattecast
./scripts/fetch-rvm-model.sh
./tests/run_tests.sh
./install.sh
```

## Code structure

```text
mattecast/
├── app/
│   ├── control_panel.py
│   ├── command_parser.h
│   ├── rvm_math.h
│   ├── rvm_processor.h
│   ├── rvm_processor.cpp
│   ├── server.cpp
│   ├── gui-requirements.txt
│   └── CMakeLists.txt
├── models/
│   └── README.md
├── scripts/
│   ├── fetch-rvm-model.sh
│   ├── vcam_watcher.sh
│   └── uninstall.sh
├── tests/
├── Containerfile
├── run.sh
└── install.sh
```

## Style

- Python: PEP 8 where practical; type hints for non-trivial interfaces.
- C++: C++17, warnings clean under the project test flags.
- Shell: `set -euo pipefail`, quote expansions, avoid `eval`, avoid mutable
  remote execution patterns.

## Security-sensitive changes

Changes involving any of the following require explicit regression tests:

- `sudo`/system files;
- container privileges, mounts, IPC or networking;
- X11/D-Bus/device exposure;
- model/dependency downloads;
- command FIFO/runtime paths;
- image/model parsing;
- custom container images.

## License

Contributions to MatteCast source code are submitted under the project's MIT
license. Third-party models/libraries retain their own licenses.
