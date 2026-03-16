#!/usr/bin/env bash
# Manifest-driven timings.dat updater for RGB-Pi.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
APP_ROOT="${APP_ROOT:-$(cd -- "${DATA_ROOT}/.." && pwd)}"
. "${DATA_ROOT}/common.sh"

DOWNLOAD_DIR="${DATA_ROOT}/debs"
TARGET_FILE="/opt/rgbpi/ui/data/timings.dat"
VERSION_FILE="/opt/rgbpi/ui/data/.timings-version"
TMP_FILE="${DOWNLOAD_DIR}/timings.dat"
BACKUP_ROOT="/opt/backups/agents/timings"
LOG_FILE="/var/log/timings-update.log"
LOG_DIR="/var/log/timings-updater"
DRY_RUN="NO"
MODE="update"

parse_args() {
  case "${1:-}" in
    --status) MODE="status" ;;
    --update|"") MODE="update" ;;
    *) echo "Usage: sudo bash $0 [--status|--update]"; exit 1 ;;
  esac
}

installed_version() {
  [[ -f "$VERSION_FILE" ]] && cat "$VERSION_FILE" || echo "unknown"
}

main() {
  parse_args "${1:-}"
  require_root
  mkdir -p "$DOWNLOAD_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  set_run_log "$LOG_DIR"

  bar 5 "Preparing timings updater"
  ensure_tooling "$LOG_FILE" "$DRY_RUN"
  bar 15 "Fetching manifest"
  if ! fetch_manifest "$LOG_FILE" "$DRY_RUN"; then
    line
    log "$LOG_FILE" "Available version : unknown"
    emit_status_lines "$(installed_version)" "unknown" "NO"
    exit 1
  fi

  local available filename url checksum installed update_flag
  available="$(manifest_field timings version)"
  filename="$(manifest_field timings filename)"
  url="$(manifest_field timings url)"
  checksum="$(manifest_field timings sha256)"
  installed="$(installed_version)"
  if compare_exact_update "$installed" "$available"; then update_flag="YES"; else update_flag="NO"; fi

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
    log "$LOG_FILE" "No timings update performed."
    exit 0
  fi

  local ts backup
  ts="$(date +%F_%H%M%S)"
  backup="${BACKUP_ROOT}/${ts}"

  bar 30 "Downloading timings.dat"
  if [[ -n "$filename" && -f "${ASSET_ROOT}/${filename}" ]]; then
    run_cmd "$LOG_FILE" "$DRY_RUN" "cp '${ASSET_ROOT}/${filename}' '$TMP_FILE'"
  else
    run_cmd "$LOG_FILE" "$DRY_RUN" "curl -fL --retry 3 --connect-timeout 15 '$url' -o '$TMP_FILE'"
  fi
  if [[ -n "$checksum" && "$checksum" != "unknown" ]]; then
    local actual
    actual="$(sha256_file "$TMP_FILE")"
    [[ "$actual" == "$checksum" ]] || { line; log "$LOG_FILE" "ERROR: checksum mismatch for timings.dat"; exit 1; }
  fi

  if [[ ! -s "$TMP_FILE" ]]; then
    line
    log "$LOG_FILE" "ERROR: timings.dat download is empty"
    exit 1
  fi

  bar 55 "Creating rollback backup"
  run_cmd "$LOG_FILE" "$DRY_RUN" "mkdir -p '$backup'"
  [[ -f "$TARGET_FILE" ]] && run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$TARGET_FILE' '$backup/'"
  [[ -f "$VERSION_FILE" ]] && run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$VERSION_FILE' '$backup/'"
  log "$LOG_FILE" "backup=$backup"

  bar 82 "Installing timings.dat"
  run_cmd "$LOG_FILE" "$DRY_RUN" "install -m 0666 '$TMP_FILE' '$TARGET_FILE'"
  run_cmd "$LOG_FILE" "$DRY_RUN" "printf '%s\n' '$available' > '$VERSION_FILE'"

  bar 100 "timings.dat update complete"
  line
  log "$LOG_FILE" "timings.dat update finished"
  emit_status_lines "$(installed_version)" "$available" "NO"
}

main "$@"
