#!/usr/bin/env bash
# Manifest-driven RetroArch updater for RGB-Pi.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

DOWNLOAD_DIR="/home/pi/ports/debs"
ARCHIVE_PATH="${DOWNLOAD_DIR}/retroarch-rgbpi.tar.gz"
BACKUP_ROOT="/opt/backups/agents/retroarch"
LOG_FILE="/var/log/retroarch-update.log"
LOG_DIR="/var/log/retroarch-updater"
INSTALL_ROOT="/opt/retroarch"
TARGET_BIN="${INSTALL_ROOT}/retroarch"
VERSION_FILE="${INSTALL_ROOT}/.rgbpi-retroarch-version"
DRY_RUN="NO"
MODE="update"

parse_args() {
  case "${1:-}" in
    --status) MODE="status" ;;
    --update|"") MODE="update" ;;
    *) echo "Usage: sudo bash $0 [--status|--update]"; exit 1 ;;
  esac
}

main() {
  parse_args "${1:-}"
  require_root
  mkdir -p "$DOWNLOAD_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  set_run_log "$LOG_DIR"

  bar 5 "Preparing RetroArch updater"
  ensure_tooling "$LOG_FILE" "$DRY_RUN"
  bar 15 "Fetching manifest"
  if ! fetch_manifest "$LOG_FILE" "$DRY_RUN"; then
    line
    log "$LOG_FILE" "Available version : unknown"
    emit_status_lines "$(installed_version)" "unknown" "NO"
    exit 1
  fi

  local available url checksum binary_checksum installed update_flag local_sha fallback_detected
  available="$(manifest_field retroarch version)"
  url="$(manifest_field retroarch url)"
  checksum="$(manifest_field retroarch sha256)"
  binary_checksum="$(manifest_field retroarch binary_sha256)"
  installed="unknown"
  fallback_detected="NO"

  if [[ -f "$VERSION_FILE" ]]; then
    installed="$(cat "$VERSION_FILE")"
  elif [[ -x "$TARGET_BIN" && -n "$binary_checksum" ]]; then
    local_sha="$(sha256_file "$TARGET_BIN")"
    if [[ "$local_sha" == "$binary_checksum" ]]; then
      installed="$available"
      fallback_detected="YES"
    fi
  fi

  if compare_pkg_update "$installed" "$available" 2>/dev/null || [[ "$installed" == "unknown" && "$available" != "unknown" ]]; then
    update_flag="YES"
  elif [[ "$installed" != "$available" ]]; then
    update_flag="YES"
  else
    update_flag="NO"
  fi

  log "$LOG_FILE" "Installed version : $installed"
  log "$LOG_FILE" "Available version : $available"
  log "$LOG_FILE" "Asset URL          : $url"
  [[ "$fallback_detected" == "YES" ]] && log "$LOG_FILE" "Detected installed RetroArch via binary checksum"

  if [[ "$MODE" == "status" ]]; then
    bar 100 "Status ready"
    line
    emit_status_lines "$installed" "$available" "$update_flag"
    exit 0
  fi

  if [[ "$update_flag" != "YES" ]]; then
    bar 100 "No update needed"
    line
    log "$LOG_FILE" "No RetroArch update performed."
    exit 0
  fi

  bar 30 "Downloading RetroArch package"
  run_cmd "$LOG_FILE" "$DRY_RUN" "curl -fL --retry 3 --connect-timeout 15 '$url' -o '$ARCHIVE_PATH'"

  if [[ -n "$checksum" && "$checksum" != "unknown" ]]; then
    local actual
    actual="$(sha256_file "$ARCHIVE_PATH")"
    if [[ "$actual" != "$checksum" ]]; then
      line
      log "$LOG_FILE" "ERROR: checksum mismatch for RetroArch asset"
      exit 1
    fi
  fi

  local ts backup tmpdir
  ts="$(date +%F_%H%M%S)"
  backup="${BACKUP_ROOT}/${ts}"
  tmpdir="$(mktemp -d)"

  bar 48 "Creating rollback backup"
  run_cmd "$LOG_FILE" "$DRY_RUN" "mkdir -p '$backup'"
  [[ -e "$TARGET_BIN" ]] && run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$TARGET_BIN' '$backup/'"
  [[ -f "$VERSION_FILE" ]] && run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$VERSION_FILE' '$backup/'"
  log "$LOG_FILE" "backup=$backup"

  bar 62 "Extracting RetroArch package"
  run_cmd "$LOG_FILE" "$DRY_RUN" "tar -xzf '$ARCHIVE_PATH' -C '$tmpdir'"

  if [[ ! -f "$tmpdir/retroarch/retroarch" ]]; then
    line
    log "$LOG_FILE" "ERROR: package missing retroarch/retroarch"
    rm -rf "$tmpdir"
    exit 1
  fi

  bar 82 "Installing RetroArch"
  run_cmd "$LOG_FILE" "$DRY_RUN" "install -m 0755 '$tmpdir/retroarch/retroarch' '$TARGET_BIN'"
  run_cmd "$LOG_FILE" "$DRY_RUN" "printf '%s\n' '$available' > '$VERSION_FILE'"

  bar 94 "Validating binary"
  if [[ ! -x "$TARGET_BIN" ]]; then
    line
    log "$LOG_FILE" "ERROR: installed RetroArch binary is not executable"
    [[ -f "$backup/retroarch" ]] && cp -a "$backup/retroarch" "$TARGET_BIN"
    rm -rf "$tmpdir"
    exit 1
  fi

  rm -rf "$tmpdir"
  bar 100 "RetroArch update complete"
  line
  log "$LOG_FILE" "RetroArch update finished"
  emit_status_lines "$(cat "$VERSION_FILE")" "$available" "NO"
}

main "$@"
