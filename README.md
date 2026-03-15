# kodi-rgbpi

Manifest-driven updater suite for RGB-Pi / Raspberry Pi 4.

This repo now covers:
- Kodi updates
- patched RetroArch updates
- managed core bundle updates
- `timings.dat` updates
- one Python controller-first updater menu for RGB-Pi

## Included
- `manifest.json`
  - source of truth for versions, asset URLs, and checksums
- `scripts/common.sh`
  - shared helper library for manifest fetch, logging, progress bars, and status output
- `scripts/update_kodi.sh`
  - downloads `kodi.deb` from manifest + GitHub release
  - ASCII progress bar in `%`
  - backup + optional `apt --fix-broken`
  - logs installed vs available version and package validation
- `scripts/update_retroarch.sh`
  - installs the managed patched RetroArch build into RGB-Pi paths
  - backup + executable validation + local version marker
- `scripts/update_cores.sh`
  - downloads and installs the managed Pi 4 core bundle
  - backup + bundle version marker + rollback validation
- `scripts/update_timings.sh`
  - downloads and installs `timings.dat`
  - backup + local timings version marker
- `scripts/ensure_pi_sudo.sh`
  - installs a dedicated passwordless sudoers drop-in for `pi`
- `scripts/bootstrap_local_metadata.sh`
  - seeds version marker files on an existing RGB-Pi install so the menu can show current versions immediately
- `scripts/mount_all.sh`
  - mounts NAS shares under `/mnt/nas`
  - optionally bind-maps ROM folders directly into RGB-Pi ROM paths
  - supports non-blocking boot integration via systemd
- `scripts/update_kodi_build_and_install.sh`
  - End-to-end: configure -> build -> package -> install
  - Enforces DEB `arm64` packaging
  - ASCII progress bar in `%`
  - backup + optional `apt --fix-broken`
- `scripts/rgbpi_update_menu.py`
  - Python controller-first updater UI
  - top-level `Kodi` and `Retroarch` menus
  - only shows update actions when a newer version exists
- `scripts/kodi_update_menu.sh`
  - compatibility wrapper that starts `rgbpi_update_menu.py`
- `dependencies-bullseye.txt`
  - Reference dependency list for Debian Bullseye / Pi4

## Quick Use (on RGB-Pi)
```bash
sudo bash /home/pi/ports/update_kodi.sh
sudo bash /home/pi/ports/update_retroarch.sh
sudo bash /home/pi/ports/update_cores.sh
sudo bash /home/pi/ports/update_timings.sh
sudo bash /home/pi/ports/ensure_pi_sudo.sh
sudo bash /home/pi/ports/bootstrap_local_metadata.sh
sudo bash /home/pi/ports/mount_all.sh --status
sudo bash /home/pi/ports/update_kodi_build_and_install.sh
python3 /home/pi/ports/rgbpi_update_menu.py
```

## Notes
- Scripts are tuned for a Pi4 Linux GBM/GLES stack and RGB-Pi file layout.
- Packaging is forced to Debian `arm64` (not `aarch64`) for `dpkg` compatibility.
- Rollback backups are stored under `/opt/backups/agents/<component>/<timestamp>/`.
- `pi` stays a normal user and is expected to have passwordless `sudo`.
- `manifest.json` is meant to be published as a release asset and kept in git for fallback reads.

## Copy to /ports/
```bash
scp manifest.json pi@<rgbpi-ip>:/home/pi/ports/
scp scripts/common.sh scripts/update_kodi.sh scripts/update_retroarch.sh scripts/update_cores.sh scripts/update_timings.sh scripts/ensure_pi_sudo.sh scripts/bootstrap_local_metadata.sh scripts/mount_all.sh scripts/update_kodi_build_and_install.sh scripts/kodi_update_menu.sh scripts/rgbpi_update_menu.py pi@<rgbpi-ip>:/home/pi/ports/
ssh pi@<rgbpi-ip> "chmod +x /home/pi/ports/update_*.sh /home/pi/ports/ensure_pi_sudo.sh /home/pi/ports/bootstrap_local_metadata.sh /home/pi/ports/mount_all.sh /home/pi/ports/kodi_update_menu.sh /home/pi/ports/rgbpi_update_menu.py"
```
