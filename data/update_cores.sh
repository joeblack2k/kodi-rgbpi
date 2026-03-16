#!/usr/bin/env bash
# Manifest-driven core bundle updater for RGB-Pi.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
APP_ROOT="${APP_ROOT:-$(cd -- "${DATA_ROOT}/.." && pwd)}"
. "${DATA_ROOT}/common.sh"

DOWNLOAD_DIR="${DATA_ROOT}/debs"
ARCHIVE_PATH="${DOWNLOAD_DIR}/cores.tar.gz"
BACKUP_ROOT="/opt/backups/agents/retroarch-cores"
LOG_FILE="/var/log/retroarch-cores-update.log"
LOG_DIR="/var/log/retroarch-cores-updater"
CORES_DIR="/opt/retroarch/cores"
VERSION_FILE="${CORES_DIR}/.rgbpi-cores-version"
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

  bar 5 "Preparing cores updater"
  ensure_tooling "$LOG_FILE" "$DRY_RUN"
  bar 15 "Fetching manifest"
  if ! fetch_manifest "$LOG_FILE" "$DRY_RUN"; then
    line
    log "$LOG_FILE" "Available version : unknown"
    emit_status_lines "$(installed_version)" "unknown" "NO"
    exit 1
  fi

  local available filename url checksum installed update_flag
  available="$(manifest_field cores version)"
  filename="$(manifest_field cores filename)"
  url="$(manifest_field cores url)"
  checksum="$(manifest_field cores sha256)"
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
    log "$LOG_FILE" "No core update performed."
    exit 0
  fi

  local ts backup tmpdir
  ts="$(date +%F_%H%M%S)"
  backup="${BACKUP_ROOT}/${ts}"
  tmpdir="$(mktemp -d)"

  bar 28 "Downloading core bundle"
  if [[ -n "$filename" && -f "${ASSET_ROOT}/${filename}" ]]; then
    run_cmd "$LOG_FILE" "$DRY_RUN" "cp '${ASSET_ROOT}/${filename}' '$ARCHIVE_PATH'"
  else
    run_cmd "$LOG_FILE" "$DRY_RUN" "curl -fL --retry 3 --connect-timeout 15 '$url' -o '$ARCHIVE_PATH'"
  fi
  if [[ -n "$checksum" && "$checksum" != "unknown" ]]; then
    local actual
    actual="$(sha256_file "$ARCHIVE_PATH")"
    [[ "$actual" == "$checksum" ]] || { line; log "$LOG_FILE" "ERROR: checksum mismatch for core bundle"; exit 1; }
  fi

  bar 45 "Creating rollback backup"
  run_cmd "$LOG_FILE" "$DRY_RUN" "mkdir -p '$backup'"
  run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$CORES_DIR' '$backup/'"
  log "$LOG_FILE" "backup=$backup"

  bar 65 "Extracting core bundle"
  run_cmd "$LOG_FILE" "$DRY_RUN" "tar -xzf '$ARCHIVE_PATH' -C '$tmpdir'"
  if [[ ! -d "$tmpdir/cores" ]]; then
    line
    log "$LOG_FILE" "ERROR: bundle missing cores directory"
    rm -rf "$tmpdir"
    exit 1
  fi

  bar 82 "Installing managed cores"
  run_cmd "$LOG_FILE" "$DRY_RUN" "cp -a '$tmpdir/cores/.' '$CORES_DIR/'"
  run_cmd "$LOG_FILE" "$DRY_RUN" "printf '%s\n' '$available' > '$VERSION_FILE'"

  bar 94 "Validating core directory"
  if [[ ! -f "$CORES_DIR/fbneo_libretro.so" ]]; then
    line
    log "$LOG_FILE" "ERROR: validation failed, restoring backup"
    rm -rf "$CORES_DIR"
    cp -a "$backup/cores" "$CORES_DIR"
    rm -rf "$tmpdir"
    exit 1
  fi

  rm -rf "$tmpdir"
  bar 100 "Core bundle update complete"
  line
  log "$LOG_FILE" "Core bundle update finished"
  emit_status_lines "$(installed_version)" "$available" "NO"
}

main "$@"
