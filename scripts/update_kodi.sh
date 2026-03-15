#!/usr/bin/env bash
# Kodi updater for RGB-Pi
# Downloads kodi.deb from GitHub release and installs it with ASCII progress.
#
# Extra behavior:
# - Logs every run to /var/log/update_kodi.log and timestamped run logs.
# - Shows currently installed Kodi version and available version in kodi.deb.
# - Supports "status only" check for menu wrappers.

set -u

###############################################################################
# USER CONFIG
###############################################################################
KODI_DEB_URL="https://github.com/joeblack2k/kodi-rgbpi/releases/download/latest/kodi.deb"
DOWNLOAD_DIR="/home/pi/ports/debs"
DEB_PATH="${DOWNLOAD_DIR}/kodi.deb"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi.log"
LOG_DIR="/var/log/kodi-updater"
AUTO_FIX_BROKEN="YES"   # YES/NO
DRY_RUN="NO"            # YES/NO
###############################################################################

MODE="update" # update|status

bar() {
  local pct="${1:-0}" msg="${2:-}"
  local width=40 fill empty
  fill=$((pct * width / 100)); empty=$((width - fill))
  printf "\r[%3d%%] [" "$pct"
  if ((fill > 0)); then printf "%0.s#" $(seq 1 "$fill"); fi
  if ((empty > 0)); then printf "%0.s-" $(seq 1 "$empty"); fi
  printf "] %s" "$msg"
}

line() { printf "\n%s\n" "$*"; }

set_run_log() {
  local ts
  ts="$(date +%F_%H%M%S)"
  mkdir -p "$LOG_DIR"
  RUN_LOG="${LOG_DIR}/run_${ts}.log"
  LATEST_LOG="${LOG_DIR}/latest.log"
}

log() {
  local ts
  ts="$(date '+%F %T')"
  echo "[$ts] $*" | tee -a "$LOG_FILE" "$RUN_LOG"
}

run() {
  local cmd="$1"
  if [[ "$DRY_RUN" == "YES" ]]; then
    log "DRY-RUN: $cmd"
    return 0
  fi
  eval "$cmd"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
  fi
}

installed_kodi_version() {
  if dpkg-query -W -f='${Version}\n' kodi >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' kodi
    return 0
  fi

  if dpkg-query -W -f='${Version}\n' kodi-bin >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}\n' kodi-bin
    return 0
  fi

  echo "not-installed"
}

available_kodi_version() {
  dpkg-deb -f "$DEB_PATH" Version 2>/dev/null || echo "unknown"
}

is_update_available() {
  local installed="$1" available="$2"

  if [[ "$installed" == "not-installed" ]]; then
    return 0
  fi

  if dpkg --compare-versions "$available" gt "$installed"; then
    return 0
  fi

  return 1
}

print_status_summary() {
  local installed="$1" available="$2"
  log "Installed version : $installed"
  log "Available version : $available"

  if is_update_available "$installed" "$available"; then
    log "Update available  : YES"
  else
    log "Update available  : NO"
  fi
}

parse_args() {
  case "${1:-}" in
    --status)
      MODE="status"
      ;;
    --update|"")
      MODE="update"
      ;;
    *)
      echo "Usage: sudo bash $0 [--status|--update]"
      exit 1
      ;;
  esac
}

main() {
  parse_args "${1:-}"
  require_root
  set_run_log
  mkdir -p "$(dirname "$LOG_FILE")" "$DOWNLOAD_DIR"
  touch "$LOG_FILE"

  # Keep latest pointer for easy troubleshooting.
  ln -sfn "$RUN_LOG" "$LATEST_LOG"

  bar 5 "Installing prerequisites"
  run "apt-get update -y >/dev/null"
  run "apt-get install -y curl >/dev/null"

  bar 20 "Downloading kodi.deb"
  run "curl -fL --retry 3 --connect-timeout 15 '$KODI_DEB_URL' -o '$DEB_PATH'"

  bar 30 "Validating downloaded package"
  local arch pkg
  arch="$(dpkg-deb -f "$DEB_PATH" Architecture 2>/dev/null || echo bad)"
  pkg="$(dpkg-deb -f "$DEB_PATH" Package 2>/dev/null || echo bad)"
  if [[ "$arch" != "arm64" || "$pkg" != "kodi" ]]; then
    line
    log "ERROR: downloaded file is not valid kodi arm64 package (pkg=$pkg arch=$arch)"
    exit 1
  fi

  local installed available
  installed="$(installed_kodi_version)"
  available="$(available_kodi_version)"

  bar 36 "Comparing versions"
  print_status_summary "$installed" "$available"

  if [[ "$MODE" == "status" ]]; then
    bar 100 "Status ready"
    line
    if is_update_available "$installed" "$available"; then
      echo "UPDATE_AVAILABLE=YES"
      exit 0
    else
      echo "UPDATE_AVAILABLE=NO"
      exit 0
    fi
  fi

  if ! is_update_available "$installed" "$available"; then
    bar 100 "No update needed"
    line
    log "No update performed (already up to date)."
    line "Kodi is already up to date."
    exit 0
  fi

  bar 42 "Creating rollback backup"
  local ts backup
  ts="$(date +%F_%H%M%S)"
  backup="$BACKUP_ROOT/$ts"
  run "mkdir -p '$backup'"
  for f in /usr/local/bin/kodi /usr/local/bin/kodi-TexturePacker /usr/local/bin/kodi-standalone /usr/local/lib/aarch64-linux-gnu/kodi /usr/share/kodi /usr/local/share/kodi; do
    if [[ -e "$f" ]]; then
      run "cp -a '$f' '$backup/'"
    fi
  done
  log "backup=$backup"

  bar 65 "Installing kodi.deb"
  run "dpkg -i '$DEB_PATH'"

  bar 82 "Fixing dependencies if needed"
  if [[ "$AUTO_FIX_BROKEN" == "YES" ]]; then
    run "apt-get -y --fix-broken install >/dev/null"
  fi

  bar 94 "Verifying installation"
  local ver
  ver="$(/usr/local/bin/kodi --version 2>/dev/null | head -n1 || true)"
  run "dpkg -l | egrep '^ii\\s+kodi' | tee -a '$LOG_FILE'"

  bar 100 "Done"
  line
  log "Kodi update finished"
  print_status_summary "$(installed_kodi_version)" "$available"
  [[ -n "$ver" ]] && log "$ver"
  line "Update complete."
}

main "$@"
