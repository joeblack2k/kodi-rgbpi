#!/usr/bin/env bash
# Publish manifest and updater assets to GitHub release "latest".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TAG="${1:-latest}"

cd "$REPO_ROOT"

required=(
  manifest.json
  dist/kodi.deb
  dist/retroarch-rgbpi.tar.gz
  dist/cores.tar.gz
  dist/timings.dat
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "Missing required file: $path"; exit 1; }
done

gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --title "$TAG" --notes "RGB-Pi updater assets"
gh release upload "$TAG" \
  manifest.json \
  dist/kodi.deb#kodi.deb \
  dist/retroarch-rgbpi.tar.gz#retroarch-rgbpi.tar.gz \
  dist/cores.tar.gz#cores.tar.gz \
  dist/timings.dat#timings.dat \
  --clobber

echo "Release assets uploaded to tag: $TAG"
