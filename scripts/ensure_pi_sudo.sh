#!/usr/bin/env bash
# Ensure the RGB-Pi "pi" user keeps passwordless sudo via a dedicated drop-in.

set -euo pipefail

TARGET="/etc/sudoers.d/010_pi-nopasswd"
TMP="$(mktemp)"

cat > "$TMP" <<'EOF'
pi ALL=(ALL) NOPASSWD:ALL
EOF

install -m 0440 "$TMP" "$TARGET"
visudo -cf "$TARGET"
rm -f "$TMP"
echo "Installed sudoers drop-in: $TARGET"
