#!/usr/bin/env python3
import importlib.util
import json
import os
import sys

# Prevent imports under test from polluting the source tree with bytecode.
sys.dont_write_bytecode = True
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Lightweight PySide stubs: security helpers/settings do not need a GUI.
class Dummy:
    def __init__(self, *args, **kwargs):
        pass

widgets = types.ModuleType("PySide6.QtWidgets")
for name in [
    "QApplication", "QMainWindow", "QWidget", "QVBoxLayout", "QHBoxLayout",
    "QPushButton", "QLabel", "QComboBox", "QSlider", "QFrame", "QFileDialog",
    "QGraphicsDropShadowEffect", "QScrollArea", "QSizePolicy", "QSystemTrayIcon",
    "QMenu", "QButtonGroup",
]:
    setattr(widgets, name, Dummy)
core = types.ModuleType("PySide6.QtCore")
core.Qt = Dummy
core.QTimer = Dummy
core.Signal = Dummy
gui = types.ModuleType("PySide6.QtGui")
for name in ["QColor", "QPalette", "QIcon", "QPixmap", "QPainter", "QAction", "QImage", "QFont"]:
    setattr(gui, name, Dummy)
svg = types.ModuleType("PySide6.QtSvg")
svg.QSvgRenderer = Dummy
pkg = types.ModuleType("PySide6")
sys.modules.update({
    "PySide6": pkg,
    "PySide6.QtWidgets": widgets,
    "PySide6.QtCore": core,
    "PySide6.QtGui": gui,
    "PySide6.QtSvg": svg,
})

spec = importlib.util.spec_from_file_location("mattecast_control", ROOT / "app/control_panel.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory(prefix="mattecast-control-test-") as td:
    base = Path(td)
    media = base / "media"
    config = base / "config"
    media.mkdir()
    config.mkdir()
    image = media / "bg.png"
    image.write_bytes(b"not decoded in this test")
    outside = base / "outside.png"
    outside.write_bytes(b"x")

    mod.MEDIA_DIR = media
    mod.CONFIG_DIR = config
    mod.CONFIG_FILE = config / "settings.json"
    assert mod.allowed_background_path(str(image))
    assert not mod.allowed_background_path(str(outside))
    assert not mod.allowed_background_path(str(media / "missing.png"))

    # Malformed/out-of-range config is reduced to safe defaults.
    mod.CONFIG_FILE.write_text(json.dumps({
        "effect_mode": "evil",
        "background_image": str(outside),
        "blur_strength": 999,
        "resolution": "99999x1",
        "fps": -1,
        "input_device": "/etc/passwd",
    }))
    settings = mod.Settings()
    assert settings.get("effect_mode") == "blur"
    assert settings.get("background_image") == ""
    assert settings.get("blur_strength") == 50
    assert settings.get("resolution") == "1280x720"
    assert settings.get("fps") == 30
    assert settings.get("input_device") == ""

    # Saving over a hostile symlink replaces the link, never its target.
    victim = base / "victim"
    victim.write_text("KEEP")
    mod.CONFIG_FILE.unlink()
    mod.CONFIG_FILE.symlink_to(victim)
    settings = mod.Settings()
    settings.set("blur_strength", 75)
    assert victim.read_text() == "KEEP"
    assert mod.CONFIG_FILE.is_file() and not mod.CONFIG_FILE.is_symlink()
    assert (mod.CONFIG_FILE.stat().st_mode & 0o777) == 0o600
    assert json.loads(mod.CONFIG_FILE.read_text())["blur_strength"] == 75

    # FIFO sender accepts an owned FIFO and rejects a regular file/symlink.
    fifo = base / "cmd.pipe"
    os.mkfifo(fifo, 0o600)
    mod.CMD_PIPE = str(fifo)
    reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    try:
        assert mod.send_command("MODE:4")
        assert os.read(reader, 1024) == b"MODE:4\n"
    finally:
        os.close(reader)

    regular = base / "not-a-fifo"
    regular.write_text("")
    mod.CMD_PIPE = str(regular)
    assert not mod.send_command("QUIT")

    fifo2 = base / "fifo2"
    os.mkfifo(fifo2, 0o600)
    link = base / "fifo-link"
    link.symlink_to(fifo2)
    mod.CMD_PIPE = str(link)
    assert not mod.send_command("QUIT")

    # Consumer-count reader accepts a regular owned file and rejects symlinks/malformed data.
    consumers = base / "consumers"
    consumers.write_text("2\n")
    mod.CONSUMERS_FILE = consumers
    assert mod.read_consumer_count() == 2
    consumers.write_text("not-a-count\n")
    assert mod.read_consumer_count() == 0
    consumers.unlink()
    target = base / "consumer-target"
    target.write_text("9\n")
    consumers.symlink_to(target)
    assert mod.read_consumer_count() == 0

print("control/settings security tests passed")
