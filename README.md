# kodi-rgbpi

Kodi build/package/update scripts for RGB-Pi / Raspberry Pi 4 (CRT-focused GBM/GLES setup).

## Included
- `scripts/update_kodi.sh`
  - Installs latest already-built Kodi DEBs from `build/packages`
  - ASCII progress bar in `%`
  - backup + optional `apt --fix-broken`
- `scripts/update_kodi_build_and_install.sh`
  - End-to-end: configure -> build -> package -> install
  - Enforces DEB `arm64` packaging
  - ASCII progress bar in `%`
  - backup + optional `apt --fix-broken`
- `dependencies-bullseye.txt`
  - Reference dependency list for Debian Bullseye / Pi4

## Quick Use (on RGB-Pi)
```bash
sudo bash /home/pi/ports/update_kodi.sh
sudo bash /home/pi/ports/update_kodi_build_and_install.sh
```

## Notes
- Scripts are tuned for a Pi4 Linux GBM/GLES stack.
- Packaging is forced to Debian `arm64` (not `aarch64`) for `dpkg` compatibility.
- Rollback backups are stored under `/opt/backups/agents/kodi/<timestamp>/`.

## Copy to /ports/
```bash
scp scripts/update_kodi.sh pi@<rgbpi-ip>:/home/pi/ports/
scp scripts/update_kodi_build_and_install.sh pi@<rgbpi-ip>:/home/pi/ports/
ssh pi@<rgbpi-ip> "chmod +x /home/pi/ports/update_kodi*.sh"
```
