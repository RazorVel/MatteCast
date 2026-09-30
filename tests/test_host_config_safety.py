#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
install = (ROOT / "install.sh").read_text()
uninstall = (ROOT / "scripts/uninstall.sh").read_text()
run = (ROOT / "run.sh").read_text()
watcher = (ROOT / "scripts/vcam_watcher.sh").read_text()

# Fail before privileged host configuration when the model is absent/invalid.
assert install.index("[2/5]") < install.index("[3/5]")
assert install.index("RVM model missing") < install.index("Setting up virtual camera")

# MatteCast owns namespaced system files rather than clobbering generic ones.
assert "/etc/modules-load.d/83-mattecast-v4l2loopback.conf" in install
assert "/etc/modprobe.d/83-mattecast-v4l2loopback.conf" in install
assert "/etc/udev/rules.d/83-mattecast-vcam.rules" in install
assert 'tee /etc/modules-load.d/v4l2loopback.conf' not in install
assert 'tee /etc/modprobe.d/v4l2loopback.conf' not in install
assert "Existing v4l2loopback options found" in install
assert "Refusing to overwrite/compete" in install
assert "already exists with unexpected contents; refusing to overwrite it" in install

# Existing /dev/videoN must actually be the MatteCast device.
assert "video_name" in install
assert "is already used by" in install
assert "is not the MatteCast virtual camera" in install
assert "validate_virtual_camera" in run
assert "is not the MatteCast virtual camera" in run

# Legacy BluCast/generic config is touched only after exact-content/ownership checks.
assert "exact_file" in install and "exact_file" in uninstall
assert "legacy_named_owned=0" in uninstall
assert "legacy_generic_owned=0" in uninstall
assert "legacy_blucast_named_owned=0" in install
assert "legacy_blucast_generic_owned=0" in install
assert "Generic v4l2loopback configuration was left untouched" in uninstall
assert "/etc/modules-load.d/83-blucast-v4l2loopback.conf" in install
assert "/etc/modprobe.d/83-blucast-v4l2loopback.conf" in install
assert "/etc/udev/rules.d/83-blucast-vcam.rules" in install
assert "legacy BluCast virtual camera, but its host configuration ownership cannot be verified" in install
assert 'sudo rm -f /etc/modules-load.d/v4l2loopback.conf' not in uninstall
assert 'sudo rm -f /etc/modprobe.d/v4l2loopback.conf' not in uninstall
assert 'LEGACY_SUDOERS_LINE=' in install and 'LEGACY_SUDOERS_LINE=' in uninstall
assert 'sudo grep -Fqx -- "$LEGACY_SUDOERS_LINE"' in install
assert 'sudo grep -Fqx -- "$LEGACY_SUDOERS_LINE"' in uninstall

# Runtime/config directories reject symlink substitution.
assert 'runtime directory must not be a symlink' in run
assert 'configuration directory must not be a symlink' in run
assert 'Refusing symlink runtime directory' in watcher

print("host configuration safety tests passed")
