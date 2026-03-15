#!/usr/bin/env python3
"""
Controller-first RGB-Pi updater menu.

Uses pygame when available for TV/controller navigation and falls back to a
simple terminal menu if pygame is unavailable.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Callable, List, Optional

PORTS_DIR = "/home/pi/ports"
KODI_SCRIPT = os.path.join(PORTS_DIR, "update_kodi.sh")
RETROARCH_SCRIPT = os.path.join(PORTS_DIR, "update_retroarch.sh")
CORES_SCRIPT = os.path.join(PORTS_DIR, "update_cores.sh")
TIMINGS_SCRIPT = os.path.join(PORTS_DIR, "update_timings.sh")


@dataclass
class Status:
    installed: str = "unknown"
    available: str = "unknown"
    update_available: bool = False
    reachable: bool = True


def run_status(script: str) -> Status:
  try:
    proc = subprocess.run(
        ["sudo", "bash", script, "--status"],
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
  return Status(installed=installed or "unknown", available=available or "unknown", update_available=update, reachable=proc.returncode == 0)


def _extract(text: str, pattern: str) -> Optional[str]:
  match = re.search(pattern, text, re.MULTILINE)
  return match.group(1).strip() if match else None


def run_action(script: str) -> int:
  return subprocess.call(["sudo", "bash", script, "--update"])


def open_log(path: str) -> int:
  if os.path.exists(path):
    return subprocess.call(["sudo", "less", path])
  return 1


class MenuApp:
  def __init__(self) -> None:
    self.kodi = run_status(KODI_SCRIPT)
    self.retroarch = run_status(RETROARCH_SCRIPT)
    self.cores = run_status(CORES_SCRIPT)
    self.timings = run_status(TIMINGS_SCRIPT)

  def refresh(self) -> None:
    self.kodi = run_status(KODI_SCRIPT)
    self.retroarch = run_status(RETROARCH_SCRIPT)
    self.cores = run_status(CORES_SCRIPT)
    self.timings = run_status(TIMINGS_SCRIPT)

  def terminal_menu(self) -> int:
    while True:
      self.refresh()
      print("\nRGB-Pi Updater")
      print("1) Kodi")
      print("2) Retroarch")
      print("3) Exit")
      choice = input("Choice: ").strip()
      if choice == "1":
        self._terminal_kodi()
      elif choice == "2":
        self._terminal_retroarch()
      else:
        return 0

  def _terminal_kodi(self) -> None:
    print(f"\nCurrent Kodi version: {self.kodi.installed}")
    print(f"Available Kodi version: {self.kodi.available}")
    if self.kodi.update_available:
      print("1) Update to latest Kodi")
      print("2) View last Kodi log")
      print("3) Back")
      choice = input("Choice: ").strip()
      if choice == "1":
        run_action(KODI_SCRIPT)
      elif choice == "2":
        open_log("/var/log/kodi-updater/latest.log")
    else:
      print("1) View last Kodi log")
      print("2) Back")
      choice = input("Choice: ").strip()
      if choice == "1":
        open_log("/var/log/kodi-updater/latest.log")

  def _terminal_retroarch(self) -> None:
    print(f"\nCurrent RetroArch version: {self.retroarch.installed}")
    print(f"Available RetroArch version: {self.retroarch.available}")
    print(f"Current cores bundle: {self.cores.installed}")
    print(f"Available cores bundle: {self.cores.available}")
    print(f"Current timings.dat version: {self.timings.installed}")
    print(f"Available timings.dat version: {self.timings.available}")
    entries = []
    idx = 1
    if self.retroarch.update_available:
      print(f"{idx}) Update to RetroArch {self.retroarch.available}")
      entries.append(("retroarch", RETROARCH_SCRIPT))
      idx += 1
    if self.cores.update_available:
      print(f"{idx}) Update all cores to {self.cores.available}")
      entries.append(("cores", CORES_SCRIPT))
      idx += 1
    if self.timings.update_available:
      print(f"{idx}) Update timings.dat to {self.timings.available}")
      entries.append(("timings", TIMINGS_SCRIPT))
      idx += 1
    print(f"{idx}) View last RetroArch log")
    log_index = idx
    print(f"{idx + 1}) Back")
    choice = input("Choice: ").strip()
    if choice.isdigit():
      selected = int(choice)
      if 1 <= selected <= len(entries):
        run_action(entries[selected - 1][1])
      elif selected == log_index:
        open_log("/var/log/retroarch-updater/latest.log")


def run_pygame(app: MenuApp) -> int:
  import pygame

  os.environ.setdefault("SDL_VIDEODRIVER", "kmsdrm")
  os.environ.setdefault("SDL_AUDIODRIVER", "alsa")
  pygame.init()
  pygame.font.init()
  try:
    screen = pygame.display.set_mode((640, 480))
  except pygame.error:
    screen = pygame.display.set_mode((640, 480))
  pygame.display.set_caption("RGB-Pi Updater")
  clock = pygame.time.Clock()
  font = pygame.font.Font(None, 34)
  small = pygame.font.Font(None, 26)

  state = "main"
  index = 0

  def build_entries() -> List[tuple[str, Optional[Callable[[], int]]]]:
    if state == "main":
      return [("Kodi", None), ("Retroarch", None), ("Return", lambda: 0)]
    if state == "kodi":
      rows = [
        (f"Current Kodi version: {app.kodi.installed}", None),
        (f"Available Kodi version: {app.kodi.available}", None),
      ]
      if app.kodi.update_available:
        rows.append((f"Update to Kodi {app.kodi.available}", lambda: run_action(KODI_SCRIPT)))
      rows.extend([
        ("View last Kodi log", lambda: open_log("/var/log/kodi-updater/latest.log")),
        ("Back", None),
      ])
      return rows

    rows = [
      (f"Current RetroArch version: {app.retroarch.installed}", None),
      (f"Available RetroArch version: {app.retroarch.available}", None),
    ]
    if app.retroarch.update_available:
      rows.append((f"Update to RetroArch {app.retroarch.available}", lambda: run_action(RETROARCH_SCRIPT)))
    rows.extend([
      (f"Current cores bundle: {app.cores.installed}", None),
      (f"Available cores bundle: {app.cores.available}", None),
    ])
    if app.cores.update_available:
      rows.append((f"Update all cores to {app.cores.available}", lambda: run_action(CORES_SCRIPT)))
    rows.extend([
      (f"Current timings.dat version: {app.timings.installed}", None),
      (f"Available timings.dat version: {app.timings.available}", None),
    ])
    if app.timings.update_available:
      rows.append((f"Update timings.dat to {app.timings.available}", lambda: run_action(TIMINGS_SCRIPT)))
    rows.extend([
      ("View last RetroArch log", lambda: open_log("/var/log/retroarch-updater/latest.log")),
      ("Back", None),
    ])
    return rows

  while True:
    app.refresh()
    entries = build_entries()
    actionable = [i for i, (_, action) in enumerate(entries) if action is not None or (state == "main" and i < 2) or (state in {"kodi", "retroarch"} and entries[i][0] == "Back")]
    if index >= len(entries):
      index = 0

    for event in pygame.event.get():
      if event.type == pygame.QUIT:
        pygame.quit()
        return 0
      if event.type == pygame.KEYDOWN:
        if event.key in (pygame.K_DOWN, pygame.K_s):
          index = min(index + 1, len(entries) - 1)
        elif event.key in (pygame.K_UP, pygame.K_w):
          index = max(index - 1, 0)
        elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
          label, action = entries[index]
          if state == "main":
            if index == 0:
              state = "kodi"
              index = 0
            elif index == 1:
              state = "retroarch"
              index = 0
            else:
              pygame.quit()
              return 0
          else:
            if label == "Back":
              state = "main"
              index = 0
            elif action is not None:
              action()
              time.sleep(0.5)
              app.refresh()
        elif event.key == pygame.K_ESCAPE:
          if state == "main":
            pygame.quit()
            return 0
          state = "main"
          index = 0

    screen.fill((10, 10, 10))
    title = font.render("RGB-Pi Updater", True, (255, 210, 80))
    screen.blit(title, (40, 24))
    subtitle = small.render("Kodi / Retroarch / Cores / timings.dat", True, (180, 180, 180))
    screen.blit(subtitle, (40, 58))

    y = 110
    for i, (label, action) in enumerate(entries):
      color = (255, 255, 255)
      if action is None and not (state == "main" and i < 2) and label != "Back":
        color = (140, 140, 140)
      if i == index:
        pygame.draw.rect(screen, (35, 75, 140), pygame.Rect(28, y - 6, 584, 34), border_radius=6)
      text = small.render(label, True, color)
      screen.blit(text, (40, y))
      y += 36

    help_text = small.render("D-pad/arrow keys to move, A/Enter to select, B/Esc to go back", True, (150, 150, 150))
    screen.blit(help_text, (40, 440))
    pygame.display.flip()
    clock.tick(30)


def main() -> int:
  app = MenuApp()
  try:
    import pygame  # noqa: F401
  except Exception:
    return app.terminal_menu()
  return run_pygame(app)


if __name__ == "__main__":
  sys.exit(main())
