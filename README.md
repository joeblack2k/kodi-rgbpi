# kodi-rgbpi

Clean public updater repo for RGB-Pi.

This repo is intentionally small:
- `update.sh`
- `data/`
- `manifest.json`

Do not launch the individual files in `data/` directly.
`update.sh` is the only real entrypoint.

Current release note:
- the bundled `kodi.deb` is the RGB-Pi Pi4 `GBM + GLES + ALSA` build with `SMB` and `NFS` enabled

## What `update.sh` Does

- launches the RGB-Pi updater menu
- updates Kodi
- updates RetroArch
- updates the core bundle
- updates `timings.dat`
- shows a live 0-100 progress bar while updates run
- automatically enables passwordless sudo for `pi` on first run
- bootstraps the missing `data/` runtime from GitHub when only `update.sh` was copied

## Install On RGB-Pi

Preferred install:

Download `RGB-PI Updater.zip` from GitHub Releases and extract it directly into the RGB-Pi ports directory.

On the current OS4 image we tested, that directory is:

```bash
mkdir -p "/media/sd/roms/ports"
```

After extraction, the updater should live here:

```text
/media/sd/roms/ports/RGB-PI Updater/
```

This release zip is intended to be fully self-contained:
- `update.sh`
- `data/`
- `manifest.json`
- `kodi.deb`
- `kodi-omega-peripheral-joystick.tar.gz`
- `retroarch-rgbpi.tar.gz`
- `cores.tar.gz`
- `timings.dat`

That means the Pi does not need internet access just to run the updater.
It also means the included Kodi package and its required bundled runtime files stay in sync with the manifest inside the zip.

Manual install from the repo is still possible if needed.

If you already cloned this repo on the Pi:

```bash
mkdir -p "/media/sd/roms/ports/RGB-PI Updater"
cp "update.sh" "/media/sd/roms/ports/RGB-PI Updater/update.sh"
chmod +x "/media/sd/roms/ports/RGB-PI Updater/update.sh"
```

If you want to pull the minimal entrypoint straight from GitHub:

```bash
mkdir -p "/media/sd/roms/ports/RGB-PI Updater"
curl -fsSL "https://raw.githubusercontent.com/joeblack2k/kodi-rgbpi/main/update.sh" -o "/media/sd/roms/ports/RGB-PI Updater/update.sh"
chmod +x "/media/sd/roms/ports/RGB-PI Updater/update.sh"
```

Minimal manual install still bootstraps the runtime from GitHub on first launch.

On a clean RGB-Pi OS4 image, the first launch also enables passwordless sudo for `pi`, tells you to reboot, and exits there on purpose.
After that reboot, launch the updater again and do the actual updates.

The automatic first-run sudo bootstrap assumes the stock `pi` password is `rgbpi`.
If you changed that password before first launch, run this once manually instead:

```bash
sudo bash "/media/sd/roms/ports/RGB-PI Updater/update.sh" root
```

## Optional Bundled Install

If you want the updater to run without downloading runtime files on first launch, also copy:

- `data/`
- `manifest.json`

If you want fully local payloads for update installs, download the latest release assets and place them in:

```text
/media/sd/roms/ports/RGB-PI Updater/data/
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
/media/sd/roms/ports/RGB-PI Updater/
```

Or from shell:

```bash
"/media/sd/roms/ports/RGB-PI Updater/update.sh"
```

Inside the RetroArch page in the menu, the updater now exposes one `Update All` action.
That single action runs the managed RetroArch frontend, core bundle, and `timings.dat` updates in sequence and writes a combined log.

Useful direct commands:

```bash
"/media/sd/roms/ports/RGB-PI Updater/update.sh" kodi --status
"/media/sd/roms/ports/RGB-PI Updater/update.sh" kodi --update
"/media/sd/roms/ports/RGB-PI Updater/update.sh" retroarch --update
"/media/sd/roms/ports/RGB-PI Updater/update.sh" cores --update
"/media/sd/roms/ports/RGB-PI Updater/update.sh" timings --update
"/media/sd/roms/ports/RGB-PI Updater/update.sh" root
"/media/sd/roms/ports/RGB-PI Updater/update.sh" bootstrap
"/media/sd/roms/ports/RGB-PI Updater/update.sh" --dump-status
```

## Repo Rules

- Public repo content should stay limited to the updater entrypoints, `data/`, and `manifest.json`.
- Release binaries belong in GitHub Releases, not in the main repo tree.
- If a future change needs another runtime file, add it because `update.sh` depends on it, not because of old wrapper habits.
