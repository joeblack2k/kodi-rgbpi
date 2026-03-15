#!/usr/bin/env bash
# Kodi update helper for RGB-Pi style setups
# Installs latest locally built Kodi DEB packages with a readable ASCII progress bar.

set -u

###############################################################################
# USER CONFIG
###############################################################################
PACKAGES_DIR="/home/pi/src/kodi/build/packages"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi.log"
AUTO_FIX_BROKEN="YES"   # YES/NO
DRY_RUN="NO"
###############################################################################

bar() {
  local pct="${1:-0}"
  local msg="${2:-}"
  local width=40
  local fill=$((pct * width / 100))
  local empty=$((width - fill))

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

pick_latest() {
  local pattern="$1"
  ls -1t ${pattern} 2>/dev/null | head -n 1
}

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  bar 3 "Starting update checks"
  sleep 0.2

  if [[ ! -d "$PACKAGES_DIR" ]]; then
    line
    log "ERROR: packages dir not found: $PACKAGES_DIR"
    exit 1
  fi

  bar 10 "Finding latest arm64/all packages"
  local kodi_bin kodi_all kodi_tex kodi_dev
  kodi_bin="$(pick_latest "$PACKAGES_DIR/kodi-bin_*_arm64.deb")"
  kodi_all="$(pick_latest "$PACKAGES_DIR/kodi_*_all.deb")"
  kodi_tex="$(pick_latest "$PACKAGES_DIR/kodi-tools-texturepacker_*_arm64.deb")"
  kodi_dev="$(pick_latest "$PACKAGES_DIR/kodi-addon-dev_*_all.deb")"

  if [[ -z "$kodi_bin" || -z "$kodi_all" || -z "$kodi_tex" || -z "$kodi_dev" ]]; then
    line
    log "ERROR: missing required DEBs in $PACKAGES_DIR"
    log "Need: kodi-bin arm64, kodi all, kodi-tools-texturepacker arm64, kodi-addon-dev all"
    exit 1
  fi

  bar 20 "Validating package architectures"
  local a1 a2 a3 a4
  a1="$(dpkg-deb -f "$kodi_bin" Architecture 2>/dev/null || echo bad)"
  a2="$(dpkg-deb -f "$kodi_all" Architecture 2>/dev/null || echo bad)"
  a3="$(dpkg-deb -f "$kodi_tex" Architecture 2>/dev/null || echo bad)"
  a4="$(dpkg-deb -f "$kodi_dev" Architecture 2>/dev/null || echo bad)"

  if [[ "$a1" != "arm64" || "$a2" != "all" || "$a3" != "arm64" || "$a4" != "all" ]]; then
    line
    log "ERROR: bad package architecture(s):"
    log "  $(basename "$kodi_bin") -> $a1"
    log "  $(basename "$kodi_all") -> $a2"
    log "  $(basename "$kodi_tex") -> $a3"
    log "  $(basename "$kodi_dev") -> $a4"
    exit 1
  fi

  bar 30 "Creating rollback backup"
  local ts backup
  ts="$(date +%F_%H%M%S)"
  backup="$BACKUP_ROOT/$ts"
  run "mkdir -p '$backup'"
  for f in /usr/local/bin/kodi /usr/local/bin/kodi-TexturePacker /usr/local/bin/kodi-standalone /usr/local/lib/aarch64-linux-gnu/kodi; do
    if [[ -e "$f" ]]; then
      run "cp -a '$f' '$backup/'"
    fi
  done
  log "backup=$backup"

  bar 45 "Installing dependencies"
  run "apt-get update -y >/dev/null"
  run "apt-get install -y mesa-utils >/dev/null"

  bar 60 "Installing Kodi DEB packages"
  run "dpkg -i '$kodi_bin' '$kodi_all' '$kodi_tex' '$kodi_dev'"

  bar 78 "Repairing package state (if needed)"
  if [[ "$AUTO_FIX_BROKEN" == "YES" ]]; then
    run "apt-get -y --fix-broken install >/dev/null"
  fi

  bar 90 "Verifying installation"
  local kodi_ver
  kodi_ver="$(/usr/local/bin/kodi --version 2>/dev/null | head -n 1 || true)"
  run "dpkg -l | egrep '^ii\\s+kodi' | tee -a '$LOG_FILE'"

  bar 100 "Done"
  line
  log "Kodi update finished"
  log "Installed: $(basename "$kodi_bin"), $(basename "$kodi_all"), $(basename "$kodi_tex"), $(basename "$kodi_dev")"
  [[ -n "$kodi_ver" ]] && log "$kodi_ver"

  line "Update complete."
}

main "$@"
