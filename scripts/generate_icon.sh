#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PNG="${1:-$ROOT_DIR/assets/icon.png}"
OUT_ICNS="${2:-$ROOT_DIR/assets/AppIcon.icns}"
MIN_SIZE="${ICON_MIN_SIZE:-256}"

if [[ ! -f "$SRC_PNG" ]]; then
  echo "Icon source not found: $SRC_PNG" >&2
  exit 1
fi

if ! [[ "$MIN_SIZE" =~ ^[0-9]+$ ]]; then
  echo "ICON_MIN_SIZE must be an integer, got: $MIN_SIZE" >&2
  exit 1
fi

WIDTH="$(sips -g pixelWidth "$SRC_PNG" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$SRC_PNG" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"

if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
  echo "Failed to read image dimensions: $SRC_PNG" >&2
  exit 1
fi

if (( WIDTH < MIN_SIZE || HEIGHT < MIN_SIZE )); then
  echo "Icon is too small: ${WIDTH}x${HEIGHT}. Minimum required: ${MIN_SIZE}x${MIN_SIZE}" >&2
  exit 1
fi

if (( WIDTH < 1024 || HEIGHT < 1024 )); then
  echo "Warning: source icon is ${WIDTH}x${HEIGHT}. Recommended size is 1024x1024 for best quality." >&2
fi

OUT_DIR="$(dirname "$OUT_ICNS")"
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d "$ROOT_DIR/dist/iconset.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$SRC_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$SRC_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SRC_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$SRC_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SRC_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$SRC_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Generated icon: $OUT_ICNS"
