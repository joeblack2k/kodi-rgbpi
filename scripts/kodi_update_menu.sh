#!/usr/bin/env bash
# Compatibility wrapper that launches the full Python updater menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/rgbpi_update_menu.py"
