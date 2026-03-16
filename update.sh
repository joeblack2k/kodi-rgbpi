#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${APP_DIR}/data"
LOG_DIR="${APP_DIR}/logs"
LOG_FILE="${LOG_DIR}/launcher.log"
REPO_OWNER="${REPO_OWNER:-joeblack2k}"
REPO_NAME="${REPO_NAME:-kodi-rgbpi}"
UPDATE_BRANCH="${UPDATE_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${UPDATE_BRANCH}}"
ACTIVE_TTY="${ACTIVE_TTY:-$(cat /sys/class/tty/tty0/active 2>/dev/null | tr -d '[:space:]')}"
ACTIVE_TTY="${ACTIVE_TTY:-tty1}"

RUNTIME_FILES=(
  common.sh
  update_kodi.sh
  update_retroarch.sh
  update_cores.sh
  update_timings.sh
  bootstrap_local_metadata.sh
  mount_all.sh
  rgbpi_update_menu.py
  make_pi_root.sh
  ensure_pi_sudo.sh
)

mkdir -p "$LOG_DIR"

bundled_mode_ready() {
  [[ -f "$DATA_DIR/manifest.json" && -f "$DATA_DIR/kodi.deb" && -f "$DATA_DIR/kodi-omega-peripheral-joystick.tar.gz" ]]
}

export_runtime_env() {
  export APP_ROOT="$APP_DIR"
  export DATA_ROOT="$DATA_DIR"
  export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-alsa}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
  export PYTHONUNBUFFERED=1
  export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-fbcon}"
  export SDL_FBDEV="${SDL_FBDEV:-/dev/fb0}"
  export SDL_NOMOUSE="${SDL_NOMOUSE:-1}"
  if bundled_mode_ready; then
    export FORCE_BUNDLED_MANIFEST=YES
  fi
}

runtime_complete() {
  local file
  for file in "${RUNTIME_FILES[@]}"; do
    [[ -f "$DATA_DIR/$file" ]] || return 1
  done
  [[ -f "$DATA_DIR/manifest.json" ]]
}

bootstrap_runtime() {
  mkdir -p "$DATA_DIR"
  local file url tmp
  for file in manifest.json; do
    url="${RAW_BASE}/${file}"
    tmp="${DATA_DIR}/.${file}.tmp"
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$tmp"
    mv "$tmp" "${DATA_DIR}/${file}"
  done
  for file in "${RUNTIME_FILES[@]}"; do
    url="${RAW_BASE}/data/${file}"
    tmp="${DATA_DIR}/.${file}.tmp"
    curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$tmp"
    mv "$tmp" "${DATA_DIR}/${file}"
  done
  chmod +x "$DATA_DIR"/*.sh
}

ensure_runtime() {
  runtime_complete && return 0
  echo "Bootstrapping updater runtime into $DATA_DIR" >>"$LOG_FILE"
  bootstrap_runtime
}

sudo_exec_script() {
  local script="$1"
  shift || true
  ensure_runtime
  export_runtime_env
  exec sudo /usr/bin/env \
    APP_ROOT="$APP_ROOT" \
    DATA_ROOT="$DATA_ROOT" \
    FORCE_BUNDLED_MANIFEST="${FORCE_BUNDLED_MANIFEST:-NO}" \
    SDL_AUDIODRIVER="$SDL_AUDIODRIVER" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    PYTHONUNBUFFERED="$PYTHONUNBUFFERED" \
    SDL_VIDEODRIVER="$SDL_VIDEODRIVER" \
    SDL_FBDEV="$SDL_FBDEV" \
    SDL_NOMOUSE="$SDL_NOMOUSE" \
    bash "$script" "$@"
}

launch_menu() {
  ensure_runtime
  export_runtime_env
  CURRENT_TTY="$(readlink -f /proc/self/fd/0 2>/dev/null || true)"
  if [[ "$EUID" -ne 0 || "$CURRENT_TTY" != "/dev/${ACTIVE_TTY}" ]]; then
    exec sudo /usr/bin/env \
      ACTIVE_TTY="$ACTIVE_TTY" \
      APP_ROOT="$APP_ROOT" \
      DATA_ROOT="$DATA_ROOT" \
      FORCE_BUNDLED_MANIFEST="${FORCE_BUNDLED_MANIFEST:-NO}" \
      SDL_AUDIODRIVER="$SDL_AUDIODRIVER" \
      XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
      PYTHONUNBUFFERED="$PYTHONUNBUFFERED" \
      SDL_VIDEODRIVER="$SDL_VIDEODRIVER" \
      SDL_FBDEV="$SDL_FBDEV" \
      SDL_NOMOUSE="$SDL_NOMOUSE" \
      bash -lc 'exec </dev/"$ACTIVE_TTY" >/dev/"$ACTIVE_TTY" 2>&1; exec "$0" __menu_internal "$@"' \
      "$APP_DIR/update.sh" "$@"
  fi

  cd "$APP_DIR"
  exec python3 "$DATA_DIR/rgbpi_update_menu.py" "$@" >>"$LOG_FILE" 2>&1
}

case "${1:-}" in
  __menu_internal)
    shift
    launch_menu "$@"
    ;;
  --bootstrap-runtime)
    bootstrap_runtime
    ;;
  --dump-status|--terminal)
    ensure_runtime
    export_runtime_env
    exec python3 "$DATA_DIR/rgbpi_update_menu.py" "$@"
    ;;
  kodi)
    shift
    sudo_exec_script "$DATA_DIR/update_kodi.sh" "${1:---update}"
    ;;
  retroarch)
    shift
    sudo_exec_script "$DATA_DIR/update_retroarch.sh" "${1:---update}"
    ;;
  cores)
    shift
    sudo_exec_script "$DATA_DIR/update_cores.sh" "${1:---update}"
    ;;
  timings)
    shift
    sudo_exec_script "$DATA_DIR/update_timings.sh" "${1:---update}"
    ;;
  root|make-root|pi-root)
    shift
    sudo_exec_script "$DATA_DIR/make_pi_root.sh" "$@"
    ;;
  bootstrap)
    shift
    sudo_exec_script "$DATA_DIR/bootstrap_local_metadata.sh" "$@"
    ;;
  mount)
    shift
    sudo_exec_script "$DATA_DIR/mount_all.sh" "$@"
    ;;
  "")
    launch_menu
    ;;
  *)
    cat <<USAGE
Usage:
  ./update.sh                     Launch RGB-Pi updater menu
  ./update.sh kodi [--status|--update]
  ./update.sh retroarch [--status|--update]
  ./update.sh cores [--status|--update]
  ./update.sh timings [--status|--update]
  ./update.sh root               Install passwordless sudo for pi
  ./update.sh bootstrap          Seed local version markers
  ./update.sh mount [args...]    Run NAS mount helper
  ./update.sh --dump-status      Print updater status summary
  ./update.sh --bootstrap-runtime Download the data/ runtime from GitHub
USAGE
    exit 1
    ;;
esac
