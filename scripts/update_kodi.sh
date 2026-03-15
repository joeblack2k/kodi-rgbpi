#!/usr/bin/env bash
# Manifest-driven Kodi updater for RGB-Pi.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

DOWNLOAD_DIR="/home/pi/ports/debs"
DEB_PATH="${DOWNLOAD_DIR}/kodi.deb"
BACKUP_ROOT="/opt/backups/agents/kodi"
LOG_FILE="/var/log/update_kodi.log"
LOG_DIR="/var/log/kodi-updater"
AUTO_FIX_BROKEN="YES"
DRY_RUN="NO"
MODE="update"

parse_args() {
  case "${1:-}" in
    --status) MODE="status" ;;
    --update|"") MODE="update" ;;
    *) echo "Usage: sudo bash $0 [--status|--update]"; exit 1 ;;
  esac
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

main() {
  parse_args "${1:-}"
  require_root
  mkdir -p "$DOWNLOAD_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  set_run_log "$LOG_DIR"

  bar 5 "Preparing Kodi updater"
  ensure_tooling "$LOG_FILE" "$DRY_RUN"
  bar 15 "Fetching manifest"
  if ! fetch_manifest "$LOG_FILE" "$DRY_RUN"; then
    line
    log "$LOG_FILE" "Available version : unknown"
    emit_status_lines "$(installed_kodi_version)" "unknown" "NO"
    exit 1
  fi

  local available url checksum installed update_flag
  available="$(manifest_field kodi version)"
  url="$(manifest_field kodi url)"
  checksum="$(manifest_field kodi sha256)"
  installed="$(installed_kodi_version)"

  if compare_pkg_update "$installed" "$available"; then update_flag="YES"; else update_flag="NO"; fi
  log "$LOG_FILE" "Installed version : $installed"
  log "$LOG_FILE" "Available version : $available"
  log "$LOG_FILE" "Asset URL          : $url"

  if [[ "$MODE" == "status" ]]; then
    bar 100 "Status ready"
    line
    emit_status_lines "$installed" "$available" "$update_flag"
    exit 0
  fi

  if [[ "$update_flag" != "YES" ]]; then
    bar 100 "No update needed"
    line
    log "$LOG_FILE" "No update performed (already up to date)."
    exit 0
  fi

  bar 30 "Downloading kodi.deb"
  run_cmd "$LOG_FILE" "$DRY_RUN" "curl -fL --retry 3 --connect-timeout 15 '$url' -o '$DEB_PATH'"

  if [[ -n "$checksum" && "$checksum" != "unknown" ]]; then
    local actual
    actual="$(sha256_file "$DEB_PATH")"
    [[ "$actual" == "$checksum" ]] || { line; log "$LOG_FILE" "ERROR: checksum mismatch for kodi.deb"; exit 1; }
  fi

  bar 40 "Validating package"
  local arch pkg
  arch="$(dpkg-deb -f "$DEB_PATH" Architecture 2>/dev/null || echo bad)"
  pkg="$(dpkg-deb -f "$DEB_PATH" Package 2>/dev/null || echo bad)"
  log "$LOG_FILE" "Package validation : pkg=$pkg arch=$arch"
  if [[ "$arch" != "arm64" || "$pkg" != "kodi" ]]; then
    line
    log "$LOG_FILE" "ERROR: downloaded file is not valid kodi arm64 package"
    exit 1
  fi

  local ts backup
  ts="$(date +%F_%H%M%S)"
  backup="${BACKUP_ROOT}/${ts}"
  bar 52 "Creating rollback backup"
  run_cmd "$LOG_FILE" "$DRY_RUN" "mkdir -p '$backup'"
  for f in /usr/local/bin/kodi /usr/local/bin/kodi-TexturePacker /usr/local/bin/kodi-standalone /usr/local/lib/aarch64-linux-gnu/kodi /usr/share/kodi /usr/local/share/kodi; do
    if [[ -e "$f" ]]; then
      run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$f' '$backup/'"
    fi
  done
  log "$LOG_FILE" "backup=$backup"

  bar 72 "Installing kodi.deb"
  run_cmd "$LOG_FILE" "$DRY_RUN" "dpkg -i '$DEB_PATH'"

  if [[ "$AUTO_FIX_BROKEN" == "YES" ]]; then
    bar 86 "Fixing dependencies"
    run_cmd "$LOG_FILE" "$DRY_RUN" "apt-get -y --fix-broken install >/dev/null"
  fi

  bar 96 "Verifying installation"
  run_cmd "$LOG_FILE" "$DRY_RUN" "dpkg -l | egrep '^ii\\s+kodi' | tee -a '$LOG_FILE'"
  bar 100 "Kodi update complete"
  line
  log "$LOG_FILE" "Kodi update finished"
  emit_status_lines "$(installed_kodi_version)" "$available" "NO"
}

main "$@"
