#!/usr/bin/env bash
# Build + package + install Kodi for RGB-Pi (Pi4)
# Includes ASCII progress, backup, and recovery.

set -u

###############################################################################
# USER CONFIG
###############################################################################
KODI_SRC_DIR="/home/pi/src/kodi"
PACKAGES_DIR="/home/pi/src/kodi/build/packages"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi_build_install.log"
AUTO_FIX_BROKEN="YES"   # YES/NO
DRY_RUN="NO"            # YES/NO
JOBS="4"
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
log() { local ts; ts="$(date '+%F %T')"; echo "[$ts] $*" | tee -a "$LOG_FILE"; }

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

pick_latest() { ls -1t $1 2>/dev/null | head -n 1; }

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"

  bar 3 "Pre-flight checks"
  [[ -d "$KODI_SRC_DIR" ]] || { line; log "ERROR: missing $KODI_SRC_DIR"; exit 1; }

  bar 8 "Install build/runtime deps"
  run "apt-get update -y >/dev/null"
  run "apt-get install -y mesa-utils gzip >/dev/null"

  bar 15 "Patch CPack DEB script for empty changelog safety"
  run "sed -i '126c\\    string(REPLACE \"\\\\\"\" \"\" CHANGELOG \"\")' '$KODI_SRC_DIR/cmake/cpack/CPackConfigDEB.cmake'"

  bar 22 "Configure (DEB arm64)"
  run "cd '$KODI_SRC_DIR' && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCORE_PLATFORM_NAME=gbm -DAPP_RENDER_SYSTEM=gles -DENABLE_INTERNAL_FMT=ON -DENABLE_INTERNAL_SPDLOG=ON -DENABLE_VAAPI=OFF -DENABLE_PIPEWIRE=OFF -DENABLE_DBUS=OFF -DENABLE_AVAHI=OFF -DENABLE_UPNP=OFF -DENABLE_AIRPLAY=OFF -DENABLE_AIRTUNES=OFF -DENABLE_WEBSERVER=OFF -DENABLE_NFS=OFF -DENABLE_SMBCLIENT=OFF -DENABLE_PULSEAUDIO=OFF -DENABLE_BLUETOOTH=OFF -DCPACK_GENERATOR=DEB -DCPACK_SYSTEM_NAME=arm64 -DCPACK_DEBIAN_PACKAGE_ARCHITECTURE=arm64 > /home/pi/build-logs/kodi-cpack-configure.log 2>&1"

  bar 35 "Build Kodi"
  run "cd '$KODI_SRC_DIR' && cmake --build build -j$JOBS > /home/pi/build-logs/kodi-build.log 2>&1"

  bar 55 "Package DEBs"
  run "cd '$KODI_SRC_DIR' && cpack --config build/CPackConfig.cmake > /home/pi/build-logs/kodi-cpack.log 2>&1"

  bar 63 "Resolve latest package set"
  local kodi_bin kodi_all kodi_tex kodi_dev
  kodi_bin="$(pick_latest "$PACKAGES_DIR/kodi-bin_*_arm64.deb")"
  kodi_all="$(pick_latest "$PACKAGES_DIR/kodi_*_all.deb")"
  kodi_tex="$(pick_latest "$PACKAGES_DIR/kodi-tools-texturepacker_*_arm64.deb")"
  kodi_dev="$(pick_latest "$PACKAGES_DIR/kodi-addon-dev_*_all.deb")"

  if [[ -z "$kodi_bin" || -z "$kodi_all" || -z "$kodi_tex" || -z "$kodi_dev" ]]; then
    line; log "ERROR: package resolution failed in $PACKAGES_DIR"; exit 1
  fi

  bar 70 "Validate package architecture"
  [[ "$(dpkg-deb -f "$kodi_bin" Architecture)" == "arm64" ]] || { line; log "ERROR: bad arch kodi-bin"; exit 1; }
  [[ "$(dpkg-deb -f "$kodi_all" Architecture)" == "all" ]] || { line; log "ERROR: bad arch kodi"; exit 1; }
  [[ "$(dpkg-deb -f "$kodi_tex" Architecture)" == "arm64" ]] || { line; log "ERROR: bad arch texturepacker"; exit 1; }
  [[ "$(dpkg-deb -f "$kodi_dev" Architecture)" == "all" ]] || { line; log "ERROR: bad arch addon-dev"; exit 1; }

  bar 76 "Create rollback backup"
  local ts backup
  ts="$(date +%F_%H%M%S)"; backup="$BACKUP_ROOT/$ts"
  run "mkdir -p '$backup'"
  for f in /usr/local/bin/kodi /usr/local/bin/kodi-TexturePacker /usr/local/bin/kodi-standalone /usr/local/lib/aarch64-linux-gnu/kodi; do
    if [[ -e "$f" ]]; then run "cp -a '$f' '$backup/'"; fi
  done
  log "backup=$backup"

  bar 86 "Install new packages"
  run "dpkg -i '$kodi_bin' '$kodi_all' '$kodi_tex' '$kodi_dev'"

  bar 92 "Repair package state if needed"
  if [[ "$AUTO_FIX_BROKEN" == "YES" ]]; then run "apt-get -y --fix-broken install >/dev/null"; fi

  bar 97 "Verify installation"
  local v
  v="$(/usr/local/bin/kodi --version 2>/dev/null | head -n 1 || true)"
  run "dpkg -l | egrep '^ii\\s+kodi' | tee -a '$LOG_FILE'"

  bar 100 "Complete"
  line
  log "Build+install finished"
  log "Installed: $(basename "$kodi_bin"), $(basename "$kodi_all"), $(basename "$kodi_tex"), $(basename "$kodi_dev")"
  [[ -n "$v" ]] && log "$v"
  line "Done."
}

main "$@"
