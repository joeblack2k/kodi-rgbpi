#!/usr/bin/env bash
set -euo pipefail

PORTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${PORTS_DIR}/RGB-PI Updater"

exec "${APP_DIR}/update.sh" "$@"
