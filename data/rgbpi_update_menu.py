#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

DATA_DIR = Path(os.environ.get("DATA_ROOT", Path(__file__).resolve().parent))
APP_ROOT = Path(os.environ.get("APP_ROOT", DATA_DIR.parent))
KODI_SCRIPT = DATA_DIR / "update_kodi.sh"
RETROARCH_SCRIPT = DATA_DIR / "update_retroarch.sh"
CORES_SCRIPT = DATA_DIR / "update_cores.sh"
TIMINGS_SCRIPT = DATA_DIR / "update_timings.sh"
ROOT_SCRIPT = DATA_DIR / "make_pi_root.sh"
BOOTSTRAP_SCRIPT = DATA_DIR / "bootstrap_local_metadata.sh"

KODI_LOG = Path("/var/log/kodi-updater/latest.log")
RETROARCH_LOG = Path("/var/log/retroarch-updater/latest.log")
BOOTSTRAP_LOG = Path("/var/log/rgbpi-updater-bootstrap/latest.log")
WINDOW_SIZE = (320, 240)
BUNDLED_ASSETS = [
    DATA_DIR / "manifest.json",
    DATA_DIR / "kodi.deb",
    DATA_DIR / "kodi-omega-peripheral-joystick.tar.gz",
]
FPS = 30
BTN_BACK = 6
BTN_START = 7
COMBO_WINDOW_SECONDS = 0.35


@dataclass
class Status:
    installed: str = "unknown"
    available: str = "unknown"
    update_available: bool = False
    reachable: bool = True


@dataclass
class MenuEntry:
    label: str
    action: Optional[Callable[[], int]] = None
    kind: str = "info"


@dataclass
class MenuState:
    name: str
    title: str
    subtitle: str
    entries: list[MenuEntry]


def _extract(text: str, pattern: str) -> Optional[str]:
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1).strip() if match else None


def use_bundled_manifest() -> bool:
    return os.environ.get("FORCE_BUNDLED_MANIFEST") == "YES" or all(path.exists() for path in BUNDLED_ASSETS)


def sudo_script_command(script: Path, mode: str) -> list[str]:
    command = ["sudo", "env", f"APP_ROOT={APP_ROOT}", f"DATA_ROOT={DATA_DIR}"]
    if use_bundled_manifest():
        command.append("FORCE_BUNDLED_MANIFEST=YES")
    command.extend(["bash", str(script), mode])
    return command


def run_status(script: Path) -> Status:
    try:
        proc = subprocess.run(
            sudo_script_command(script, "--status"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=90,
            check=False,
        )
    except Exception:
        return Status(reachable=False)

    text = proc.stdout
    installed = _extract(text, r"^INSTALLED_VERSION=(.*)$") or _extract(text, r"Installed version\s*:\s*(.*)")
    available = _extract(text, r"^AVAILABLE_VERSION=(.*)$") or _extract(text, r"Available version\s*:\s*(.*)")
    update = (_extract(text, r"^UPDATE_AVAILABLE=(YES|NO)$") or "NO") == "YES"
    return Status(
        installed=installed or "unknown",
        available=available or "unknown",
        update_available=update,
        reachable=proc.returncode == 0,
    )


def run_action(script: Path) -> int:
    return subprocess.call(sudo_script_command(script, "--update"))


def run_script(script: Path, *args: str) -> int:
    command = ["sudo", "env", f"APP_ROOT={APP_ROOT}", f"DATA_ROOT={DATA_DIR}"]
    if use_bundled_manifest():
        command.append("FORCE_BUNDLED_MANIFEST=YES")
    command.extend(["bash", str(script), *args])
    return subprocess.call(command)


def read_log_tail(path: Path, max_lines: int = 11) -> list[str]:
    if not path.exists():
        return ["Log not found."]
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception as exc:
        return [f"Could not read log: {exc}"]
    tail = lines[-max_lines:]
    return tail or ["Log is empty."]


def pi_root_enabled() -> bool:
    return Path("/etc/sudoers.d/010_pi-nopasswd").exists()


def ensure_runtime_env() -> None:
    os.environ.setdefault("SDL_VIDEODRIVER", "fbcon")
    os.environ.setdefault("SDL_FBDEV", "/dev/fb0")
    os.environ.setdefault("SDL_NOMOUSE", "1")
    os.environ.setdefault("SDL_AUDIODRIVER", "alsa")
    os.environ.setdefault("XDG_RUNTIME_DIR", "/tmp")


def candidate_devices():
    try:
        from evdev import InputDevice, ecodes, list_devices
    except Exception:
        return []

    devices = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities(verbose=False)
            keys = caps.get(ecodes.EV_KEY, [])
            abs_caps = caps.get(ecodes.EV_ABS, [])
            if ecodes.BTN_SOUTH in keys or ecodes.BTN_A in keys or ecodes.ABS_HAT0X in abs_caps:
                try:
                    dev.grab()
                except OSError:
                    pass
                try:
                    os.set_blocking(dev.fd, False)
                except OSError:
                    pass
                devices.append(dev)
        except OSError:
            continue
    return devices


class MenuApp:
    def __init__(self) -> None:
        ensure_runtime_env()

        import pygame

        pygame.init()
        pygame.font.init()
        self.pygame = pygame
        self.screen = pygame.display.set_mode(WINDOW_SIZE, pygame.FULLSCREEN)
        pygame.display.set_caption("RGB-Pi Updater")
        pygame.mouse.set_visible(False)

        self.clock = pygame.time.Clock()
        self.title_font = pygame.font.Font(None, 26)
        self.body_font = pygame.font.Font(None, 18)
        self.small_font = pygame.font.Font(None, 14)
        self.tiny_font = pygame.font.Font(None, 12)

        self.kodi = Status()
        self.retroarch = Status()
        self.cores = Status()
        self.timings = Status()
        self.state = "main"
        self.index = 0
        self.notice = ""
        self.notice_until = 0.0
        self.log_title = ""
        self.log_lines: list[str] = []
        self.controller_devices = []
        self.last_controller_scan = 0.0
        self.last_back_press = 0.0
        self.last_start_press = 0.0
        self.refresh()

    def refresh(self) -> None:
        self.kodi = run_status(KODI_SCRIPT)
        self.retroarch = run_status(RETROARCH_SCRIPT)
        self.cores = run_status(CORES_SCRIPT)
        self.timings = run_status(TIMINGS_SCRIPT)

    def set_notice(self, message: str, seconds: float = 2.0) -> None:
        self.notice = message
        self.notice_until = time.monotonic() + seconds

    def build_state(self) -> MenuState:
        if self.state == "main":
            return MenuState(
                name="main",
                title="RGB-PI UPDATER",
                subtitle="KODI / RETROARCH / SYSTEM",
                entries=[
                    MenuEntry("Kodi", lambda: self.open_state("kodi"), "action"),
                    MenuEntry("RetroArch", lambda: self.open_state("retroarch"), "action"),
                    MenuEntry("System", lambda: self.open_state("system"), "action"),
                    MenuEntry("Return", self.exit_app, "action"),
                ],
            )
        if self.state == "kodi":
            entries = [
                MenuEntry(f"Installed: {self.kodi.installed}"),
                MenuEntry(f"Available: {self.kodi.available}"),
            ]
            if self.kodi.update_available:
                entries.append(MenuEntry(f"Update Kodi {self.kodi.available}", lambda: self.run_and_refresh(KODI_SCRIPT), "action"))
            entries.extend([
                MenuEntry("View Kodi log", lambda: self.open_log("Kodi Log", KODI_LOG), "action"),
                MenuEntry("Back", lambda: self.open_state("main"), "action"),
            ])
            return MenuState("kodi", "KODI", "SYSTEM UPDATE", entries)
        if self.state == "retroarch":
            entries = [
                MenuEntry(f"RetroArch: {self.retroarch.installed}"),
                MenuEntry(f"Available: {self.retroarch.available}"),
            ]
            if self.retroarch.update_available:
                entries.append(MenuEntry(f"Update RetroArch {self.retroarch.available}", lambda: self.run_and_refresh(RETROARCH_SCRIPT), "action"))
            entries.extend([
                MenuEntry(f"Cores: {self.cores.installed}"),
                MenuEntry(f"Available: {self.cores.available}"),
            ])
            if self.cores.update_available:
                entries.append(MenuEntry(f"Update Cores {self.cores.available}", lambda: self.run_and_refresh(CORES_SCRIPT), "action"))
            entries.extend([
                MenuEntry(f"Timings: {self.timings.installed}"),
                MenuEntry(f"Available: {self.timings.available}"),
            ])
            if self.timings.update_available:
                entries.append(MenuEntry(f"Update Timings {self.timings.available}", lambda: self.run_and_refresh(TIMINGS_SCRIPT), "action"))
            entries.extend([
                MenuEntry("View RetroArch log", lambda: self.open_log("RetroArch Log", RETROARCH_LOG), "action"),
                MenuEntry("Back", lambda: self.open_state("main"), "action"),
            ])
            return MenuState("retroarch", "RETROARCH", "UPDATES / LOGS", entries)
        if self.state == "system":
            entries = [
                MenuEntry(f"Pi Root: {'ENABLED' if pi_root_enabled() else 'OFF'}"),
                MenuEntry("Make user Pi Root", lambda: self.run_system_action(ROOT_SCRIPT, "Pi root ready"), "action"),
                MenuEntry("Bootstrap Metadata", lambda: self.run_system_action(BOOTSTRAP_SCRIPT, "Metadata refreshed"), "action"),
                MenuEntry("View Bootstrap log", lambda: self.open_log("Bootstrap Log", BOOTSTRAP_LOG), "action"),
                MenuEntry("Back", lambda: self.open_state("main"), "action"),
            ]
            return MenuState("system", "SYSTEM", "PI / METADATA", entries)
        return MenuState("log", self.log_title, "B TO GO BACK", [MenuEntry(line) for line in self.log_lines] + [MenuEntry("Back", lambda: self.open_state("main"), "action")])

    def open_state(self, name: str) -> int:
        self.state = name
        self.index = 0
        if name != "log":
            self.refresh()
        return 0

    def open_log(self, title: str, path: Path) -> int:
        self.log_title = title
        self.log_lines = read_log_tail(path)
        self.state = "log"
        self.index = max(0, len(self.log_lines))
        return 0

    def run_and_refresh(self, script: Path) -> int:
        self.draw_loading("Running update...")
        rc = run_action(script)
        self.refresh()
        self.set_notice("Update complete" if rc == 0 else f"Update failed ({rc})", 2.5)
        return rc

    def run_system_action(self, script: Path, success_notice: str) -> int:
        self.draw_loading("Applying system change...")
        rc = run_script(script)
        self.refresh()
        self.set_notice(success_notice if rc == 0 else f"Action failed ({rc})", 2.5)
        return rc

    def exit_app(self) -> int:
        raise SystemExit(0)

    def ensure_controller_devices(self) -> None:
        if self.controller_devices:
            return
        now = time.monotonic()
        if now - self.last_controller_scan < 1.0:
            return
        self.last_controller_scan = now
        self.controller_devices = candidate_devices()

    def handle_controller_events(self) -> None:
        try:
            from evdev import ecodes
        except Exception:
            return

        active = []
        for dev in list(self.controller_devices):
            try:
                for event in dev.read():
                    if event.type == ecodes.EV_KEY and event.value == 1:
                        self.on_evdev_button(event.code, ecodes)
                    elif event.type == ecodes.EV_ABS:
                        self.on_evdev_axis(event.code, event.value, ecodes)
            except BlockingIOError:
                pass
            except OSError:
                continue
            active.append(dev)
        self.controller_devices = active

    def on_evdev_button(self, code: int, ecodes) -> None:
        now = time.monotonic()
        if code == ecodes.BTN_START:
            self.last_start_press = now
            if now - self.last_back_press <= COMBO_WINDOW_SECONDS:
                raise SystemExit(0)
            self.on_select()
            return
        if code in (ecodes.BTN_SELECT, ecodes.BTN_MODE):
            self.last_back_press = now
            if now - self.last_start_press <= COMBO_WINDOW_SECONDS:
                raise SystemExit(0)
            self.on_back()
            return
        if code in (ecodes.BTN_SOUTH, ecodes.BTN_A):
            self.on_select()
        elif code in (ecodes.BTN_EAST, ecodes.BTN_B):
            self.on_back()

    def on_evdev_axis(self, code: int, value: int, ecodes) -> None:
        if code == ecodes.ABS_HAT0Y:
            if value == -1:
                self.move(-1)
            elif value == 1:
                self.move(1)
        elif code == ecodes.ABS_HAT0X:
            if value == -1:
                self.on_back()
            elif value == 1:
                self.on_select()

    def handle_events(self) -> None:
        self.ensure_controller_devices()
        self.handle_controller_events()
        for event in self.pygame.event.get():
            if event.type == self.pygame.QUIT:
                raise SystemExit(0)
            if event.type == self.pygame.KEYDOWN:
                if event.key in (self.pygame.K_DOWN, self.pygame.K_s):
                    self.move(1)
                elif event.key in (self.pygame.K_UP, self.pygame.K_w):
                    self.move(-1)
                elif event.key in (self.pygame.K_RETURN, self.pygame.K_SPACE):
                    self.on_select()
                elif event.key in (self.pygame.K_ESCAPE, self.pygame.K_BACKSPACE):
                    self.on_back()

    def selectable_indexes(self, entries: list[MenuEntry]) -> list[int]:
        return [i for i, entry in enumerate(entries) if entry.action is not None]

    def move(self, delta: int) -> None:
        state = self.build_state()
        choices = self.selectable_indexes(state.entries)
        if not choices:
            return
        if self.index not in choices:
            self.index = choices[0]
            return
        pos = choices.index(self.index)
        self.index = choices[(pos + delta) % len(choices)]

    def on_select(self) -> None:
        state = self.build_state()
        if 0 <= self.index < len(state.entries):
            action = state.entries[self.index].action
            if action is not None:
                action()

    def on_back(self) -> None:
        if self.state == "main":
            raise SystemExit(0)
        self.open_state("main")

    def ellipsize(self, font, text: str, width: int) -> str:
        if font.size(text)[0] <= width:
            return text
        trimmed = text
        while trimmed and font.size(trimmed + "...")[0] > width:
            trimmed = trimmed[:-1]
        return (trimmed + "...") if trimmed else "..."

    def draw_loading(self, message: str) -> None:
        self.screen.fill((6, 10, 22))
        self.blit(self.title_font, "PLEASE WAIT", (88, 84), (236, 246, 255))
        self.blit(self.body_font, message, (68, 116), (176, 220, 255))
        self.pygame.display.flip()

    def draw(self) -> None:
        now = time.monotonic()
        if self.notice and now > self.notice_until:
            self.notice = ""

        state = self.build_state()
        entries = state.entries
        choices = self.selectable_indexes(entries)
        if choices and self.index not in choices:
            self.index = choices[0]

        self.screen.fill((5, 10, 22))
        header = self.pygame.Rect(8, 8, 304, 28)
        self.pygame.draw.rect(self.screen, (12, 26, 60), header)
        self.pygame.draw.rect(self.screen, (154, 210, 255), header, 1)
        self.blit(self.title_font, state.title, (16, 13), (240, 246, 255))
        self.blit(self.tiny_font, state.subtitle, (16, 38), (160, 208, 246))

        top = 58
        visible = 8 if state.name != "log" else 10
        offset = 0
        if self.index >= visible:
            offset = self.index - visible + 1

        for row in range(visible):
            idx = offset + row
            if idx >= len(entries):
                break
            entry = entries[idx]
            y = top + row * 20
            rect = self.pygame.Rect(8, y, 304, 18)
            selected = idx == self.index and entry.action is not None
            if selected:
                self.pygame.draw.rect(self.screen, (224, 242, 255), rect)
                self.pygame.draw.rect(self.screen, (18, 86, 160), rect, 1)
                color = (12, 54, 106)
            else:
                self.pygame.draw.rect(self.screen, (16, 34, 74), rect)
                self.pygame.draw.rect(self.screen, (58, 108, 170), rect, 1)
                color = (206, 232, 255) if entry.action else (142, 178, 214)
            label = entry.label
            if state.name != "log":
                label = self.ellipsize(self.small_font, label, 286)
            self.blit(self.small_font, label, (14, y + 3), color)

        footer = self.pygame.Rect(8, 224, 304, 10)
        self.pygame.draw.rect(self.screen, (12, 26, 60), footer)
        self.pygame.draw.rect(self.screen, (92, 144, 206), footer, 1)
        footer_text = self.notice or "D-PAD MOVE   A SELECT   B BACK   START+SELECT EXIT"
        self.blit(self.tiny_font, self.ellipsize(self.tiny_font, footer_text, 292), (14, 224), (176, 220, 255))
        self.pygame.display.flip()

    def blit(self, font, text: str, pos: tuple[int, int], color: tuple[int, int, int]) -> None:
        self.screen.blit(font.render(text, True, color), pos)

    def run(self) -> int:
        while True:
            self.handle_events()
            self.draw()
            self.clock.tick(FPS)


def main() -> int:
    if "--dump-status" in sys.argv:
        kodi = run_status(KODI_SCRIPT)
        retroarch = run_status(RETROARCH_SCRIPT)
        cores = run_status(CORES_SCRIPT)
        timings = run_status(TIMINGS_SCRIPT)
        print(f"KODI_INSTALLED={kodi.installed}")
        print(f"KODI_AVAILABLE={kodi.available}")
        print(f"KODI_UPDATE={'YES' if kodi.update_available else 'NO'}")
        print(f"RETROARCH_INSTALLED={retroarch.installed}")
        print(f"RETROARCH_AVAILABLE={retroarch.available}")
        print(f"RETROARCH_UPDATE={'YES' if retroarch.update_available else 'NO'}")
        print(f"CORES_INSTALLED={cores.installed}")
        print(f"CORES_AVAILABLE={cores.available}")
        print(f"CORES_UPDATE={'YES' if cores.update_available else 'NO'}")
        print(f"TIMINGS_INSTALLED={timings.installed}")
        print(f"TIMINGS_AVAILABLE={timings.available}")
        print(f"TIMINGS_UPDATE={'YES' if timings.update_available else 'NO'}")
        return 0

    if "--terminal" in sys.argv:
        print("Terminal mode is no longer the preferred RGB-Pi path.")
        return 1

    try:
        return MenuApp().run()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"rgbpi_update_menu.py failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
