# kodi-rgbpi

Clean public updater repo for RGB-Pi.

This repo is intentionally small:
- `RGB-PI Updater.sh`
- `update.sh`
- `data/`
- `manifest.json`

Do not launch the individual files in `data/` directly.
`update.sh` is the only real entrypoint.

## What `update.sh` Does

- launches the RGB-Pi updater menu
- updates Kodi
- updates RetroArch
- updates the core bundle
- updates `timings.dat`
- can make user `pi` passwordless sudo from the menu
- bootstraps the missing `data/` runtime from GitHub when only `update.sh` was copied

## Install On RGB-Pi

Create the port folder:

```bash
mkdir -p "/sd/roms/ports/RGB-PI Updater"
```

Copy these two files into `/sd/roms/ports`:

- `RGB-PI Updater.sh`
- `RGB-PI Updater/update.sh`

If you already cloned this repo on the Pi:

```bash
cp "RGB-PI Updater.sh" "/sd/roms/ports/RGB-PI Updater.sh"
cp "update.sh" "/sd/roms/ports/RGB-PI Updater/update.sh"
chmod +x "/sd/roms/ports/RGB-PI Updater.sh" "/sd/roms/ports/RGB-PI Updater/update.sh"
```

If you want to pull the two files straight from GitHub:

```bash
curl -fsSL "https://raw.githubusercontent.com/joeblack2k/kodi-rgbpi/main/RGB-PI%20Updater.sh" -o "/sd/roms/ports/RGB-PI Updater.sh"
curl -fsSL "https://raw.githubusercontent.com/joeblack2k/kodi-rgbpi/main/update.sh" -o "/sd/roms/ports/RGB-PI Updater/update.sh"
chmod +x "/sd/roms/ports/RGB-PI Updater.sh" "/sd/roms/ports/RGB-PI Updater/update.sh"
```

First launch will create `/sd/roms/ports/RGB-PI Updater/data/` automatically by downloading the runtime from GitHub.

## Optional Bundled Install

If you want the updater to run without downloading runtime files on first launch, also copy:

- `data/`
- `manifest.json`

If you want fully local payloads for update installs, download the latest release assets and place them in:

```text
/sd/roms/ports/RGB-PI Updater/data/
```

Supported local payload files:

- `kodi.deb`
- `kodi-omega-peripheral-joystick.tar.gz`
- `retroarch-rgbpi.tar.gz`
- `cores.tar.gz`
- `timings.dat`

When those files are present locally, `update.sh` and the component scripts use them instead of downloading them from the release URLs in `manifest.json`.

## Run

From the RGB-Pi menu, launch:

```text
RGB-PI Updater
```

Or from shell:

```bash
"/sd/roms/ports/RGB-PI Updater.sh"
```

Useful direct commands:

```bash
"/sd/roms/ports/RGB-PI Updater/update.sh" kodi --status
"/sd/roms/ports/RGB-PI Updater/update.sh" kodi --update
"/sd/roms/ports/RGB-PI Updater/update.sh" retroarch --update
"/sd/roms/ports/RGB-PI Updater/update.sh" cores --update
"/sd/roms/ports/RGB-PI Updater/update.sh" timings --update
"/sd/roms/ports/RGB-PI Updater/update.sh" root
"/sd/roms/ports/RGB-PI Updater/update.sh" bootstrap
"/sd/roms/ports/RGB-PI Updater/update.sh" --dump-status
```

## Repo Rules

- Public repo content should stay limited to the updater entrypoints, `data/`, and `manifest.json`.
- Release binaries belong in GitHub Releases, not in the main repo tree.
- If a future change needs another runtime file, add it because `update.sh` depends on it, not because of old wrapper habits.
