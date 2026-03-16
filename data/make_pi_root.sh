#!/usr/bin/env bash
set -euo pipefail

TARGET="/etc/sudoers.d/010_pi-nopasswd"
TMP="$(mktemp)"

cat > "$TMP" <<'RULE'
pi ALL=(ALL) NOPASSWD:ALL
RULE

install -m 0440 "$TMP" "$TARGET"
visudo -cf "$TARGET"
rm -f "$TMP"
echo "Installed sudoers drop-in: $TARGET"
