#!/usr/bin/env bash
# Kodi updater for RGB-Pi
# Downloads kodi.deb from GitHub release and installs it with ASCII progress.

set -u

###############################################################################
# USER CONFIG
###############################################################################
KODI_DEB_URL="https://github.com/joeblack2k/kodi-rgbpi/releases/download/latest/kodi.deb"
DOWNLOAD_DIR="/home/pi/ports/debs"
DEB_PATH="${DOWNLOAD_DIR}/kodi.deb"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi.log"
AUTO_FIX_BROKEN="YES"   # YES/NO
DRY_RUN="NO"            # YES/NO
###############################################################################

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

log() {
  local ts
  ts="$(date '+%F %T')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
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

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")" "$DOWNLOAD_DIR"
  touch "$LOG_FILE"

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
  [[ -n "$ver" ]] && log "$ver"
  line "Update complete."
}

main "$@"
