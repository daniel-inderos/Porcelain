#!/usr/bin/env bash
# Regenerates Assets/AppIcon.icns and the README icon from the Swift generator.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift scripts/generate_app_icon.swift

ICONSET="$ROOT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
sips -z 256 256 Assets/icon-1024.png --out Assets/icon-256.png >/dev/null

echo "Wrote Assets/AppIcon.icns and Assets/icon-256.png"
