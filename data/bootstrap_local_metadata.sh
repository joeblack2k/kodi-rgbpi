#!/usr/bin/env bash
# Seed local version marker files on an existing RGB-Pi install.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
APP_ROOT="${APP_ROOT:-$(cd -- "${DATA_ROOT}/.." && pwd)}"
. "${DATA_ROOT}/common.sh"

LOG_FILE="/var/log/rgbpi-updater-bootstrap.log"
LOG_DIR="/var/log/rgbpi-updater-bootstrap"
DRY_RUN="NO"

RETROARCH_BIN="/opt/retroarch/retroarch"
RETROARCH_VERSION_FILE="/opt/retroarch/.rgbpi-retroarch-version"
CORES_DIR="/opt/retroarch/cores"
CORES_VERSION_FILE="${CORES_DIR}/.rgbpi-cores-version"
TIMINGS_FILE="/opt/rgbpi/ui/data/timings.dat"
TIMINGS_VERSION_FILE="/opt/rgbpi/ui/data/.timings-version"

require_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
set_run_log "$LOG_DIR"
ensure_tooling "$LOG_FILE" "$DRY_RUN"
fetch_manifest "$LOG_FILE" "$DRY_RUN"

retroarch_version="$(manifest_field retroarch version)"
retroarch_binary_sha="$(manifest_field retroarch binary_sha256)"
cores_version="$(manifest_field cores version)"
timings_version="$(manifest_field timings version)"
timings_sha="$(manifest_field timings sha256)"

if [[ -x "$RETROARCH_BIN" && -n "$retroarch_binary_sha" ]]; then
  if [[ "$(sha256_file "$RETROARCH_BIN")" == "$retroarch_binary_sha" ]]; then
    printf '%s\n' "$retroarch_version" > "$RETROARCH_VERSION_FILE"
    log "$LOG_FILE" "Seeded RetroArch version marker: $retroarch_version"
  fi
fi

if [[ -d "$CORES_DIR" && -f "$CORES_DIR/fbneo_libretro.so" ]]; then
  printf '%s\n' "$cores_version" > "$CORES_VERSION_FILE"
  log "$LOG_FILE" "Seeded cores version marker: $cores_version"
fi

if [[ -f "$TIMINGS_FILE" && -n "$timings_sha" ]]; then
  if [[ "$(sha256_file "$TIMINGS_FILE")" == "$timings_sha" ]]; then
    printf '%s\n' "$timings_version" > "$TIMINGS_VERSION_FILE"
    log "$LOG_FILE" "Seeded timings version marker: $timings_version"
  fi
fi

echo "Bootstrap complete."
