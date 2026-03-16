#!/usr/bin/env bash

set -u

REPO_OWNER="${REPO_OWNER:-joeblack2k}"
REPO_NAME="${REPO_NAME:-kodi-rgbpi}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
MANIFEST_URL_PRIMARY="${MANIFEST_URL_PRIMARY-https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/manifest.json}"
MANIFEST_URL_FALLBACK="${MANIFEST_URL_FALLBACK-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/manifest.json}"
FORCE_BUNDLED_MANIFEST="${FORCE_BUNDLED_MANIFEST:-NO}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR}"
APP_ROOT="${APP_ROOT:-$(cd -- "${DATA_ROOT}/.." && pwd)}"
WORK_ROOT="${WORK_ROOT:-${APP_ROOT}/.updater}"
MANIFEST_CACHE="${MANIFEST_CACHE:-${WORK_ROOT}/manifest.json}"
BUNDLED_MANIFEST="${BUNDLED_MANIFEST:-${DATA_ROOT}/manifest.json}"
ASSET_ROOT="${ASSET_ROOT:-${DATA_ROOT}}"
MANIFEST_CACHE_MAX_AGE="${MANIFEST_CACHE_MAX_AGE:-300}"

bar() {
  local pct="${1:-0}" msg="${2:-}"
  local width=40 fill empty
  fill=$((pct * width / 100))
  empty=$((width - fill))
  printf "\r[%3d%%] [" "$pct"
  if ((fill > 0)); then printf "%0.s#" $(seq 1 "$fill"); fi
  if ((empty > 0)); then printf "%0.s-" $(seq 1 "$empty"); fi
  printf "] %s" "$msg"
}

line() {
  printf "\n%s\n" "$*"
}

set_run_log() {
  local log_dir="$1" ts
  ts="$(date +%F_%H%M%S)"
  mkdir -p "$log_dir"
  RUN_LOG="${log_dir}/run_${ts}.log"
  LATEST_LOG="${log_dir}/latest.log"
  ln -sfn "$RUN_LOG" "$LATEST_LOG"
}

log() {
  local log_file="$1"
  local ts
  ts="$(date '+%F %T')"
  echo "[$ts] $*" | tee -a "$log_file" "$RUN_LOG"
}

run_cmd() {
  local log_file="$1" dry_run="$2" cmd="$3"
  if [[ "$dry_run" == "YES" ]]; then
    log "$log_file" "DRY-RUN: $cmd"
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

ensure_tooling() {
  local log_file="$1" dry_run="$2"
  local missing=()
  local cmd
  for cmd in curl python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  run_cmd "$log_file" "$dry_run" "apt-get update -y >/dev/null"
  run_cmd "$log_file" "$dry_run" "apt-get install -y ${missing[*]} ca-certificates >/dev/null"
}

fetch_manifest() {
  local log_file="$1" dry_run="$2"
  mkdir -p "$WORK_ROOT"
  if [[ "$dry_run" == "YES" ]]; then
    log "$log_file" "DRY-RUN: would fetch manifest to $MANIFEST_CACHE"
    cp "$BUNDLED_MANIFEST" "$MANIFEST_CACHE" 2>/dev/null || true
    return 0
  fi

  if [[ "$FORCE_BUNDLED_MANIFEST" == "YES" && -f "$BUNDLED_MANIFEST" ]]; then
    cp "$BUNDLED_MANIFEST" "$MANIFEST_CACHE"
    log "$log_file" "manifest_source=$BUNDLED_MANIFEST (forced)"
    return 0
  fi

  if [[ -f "$MANIFEST_CACHE" ]]; then
    local now cache_age
    now="$(date +%s)"
    cache_age=$((now - $(stat -c %Y "$MANIFEST_CACHE" 2>/dev/null || echo 0)))
    if ((cache_age >= 0 && cache_age < MANIFEST_CACHE_MAX_AGE)); then
      log "$log_file" "manifest_source=$MANIFEST_CACHE (cached ${cache_age}s)"
      return 0
    fi
  fi

  if [[ -n "$MANIFEST_URL_PRIMARY" ]] && curl -fsSL --retry 3 --connect-timeout 15 "$MANIFEST_URL_PRIMARY" -o "$MANIFEST_CACHE"; then
    log "$log_file" "manifest_source=$MANIFEST_URL_PRIMARY"
    return 0
  fi

  if [[ -n "$MANIFEST_URL_FALLBACK" ]] && curl -fsSL --retry 3 --connect-timeout 15 "$MANIFEST_URL_FALLBACK" -o "$MANIFEST_CACHE"; then
    log "$log_file" "manifest_source=$MANIFEST_URL_FALLBACK"
    return 0
  fi

  if [[ -f "$BUNDLED_MANIFEST" ]]; then
    cp "$BUNDLED_MANIFEST" "$MANIFEST_CACHE"
    log "$log_file" "manifest_source=$BUNDLED_MANIFEST"
    return 0
  fi

  log "$log_file" "ERROR: unable to fetch manifest"
  return 1
}

manifest_field() {
  local key="$1" field="$2"
  python3 - "$MANIFEST_CACHE" "$key" "$field" <<'PY'
import json, sys
path, key, field = sys.argv[1:]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
value = data["assets"][key].get(field, "")
print(value)
PY
}

emit_status_lines() {
  local installed="$1" available="$2" update_available="$3"
  echo "INSTALLED_VERSION=${installed}"
  echo "AVAILABLE_VERSION=${available}"
  echo "UPDATE_AVAILABLE=${update_available}"
}

sha256_file() {
  local path="$1"
  sha256sum "$path" | awk '{print $1}'
}

compare_exact_update() {
  local installed="$1" available="$2"
  [[ "$installed" != "$available" ]]
}

compare_pkg_update() {
  local installed="$1" available="$2"
  if [[ "$installed" == "not-installed" ]]; then
    return 0
  fi
  dpkg --compare-versions "$available" gt "$installed"
}
