#!/usr/bin/env bash
# Build AppIcon.appiconset from Icon/AppIcon.svg.
#
# Pipeline: SVG → 1024px PNG (ImageMagick) → all required sizes (sips) →
# AppIcon.appiconset with Contents.json.
#
# Requires: ImageMagick (`brew install imagemagick`), sips (built-in on macOS).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Icon/AppIcon.svg"
OUT="$ROOT/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"

if [ ! -f "$SVG" ]; then
  echo "error: SVG source not found at $SVG" >&2
  exit 1
fi

echo "→ Rendering $SVG to 1024×1024 PNG…"
# Prefer rsvg-convert (Cairo-backed, full SVG 1.1 support including gradients
# and filters). Fall back to ImageMagick, which silently drops feGaussianBlur
# and mishandles gradients in transformed groups.
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/icon_1024.png"
else
  echo "  (rsvg-convert not found, falling back to ImageMagick — gradients/filters may not render correctly)"
  magick -background none -density 384 "$SVG" -resize 1024x1024 "$TMP/icon_1024.png"
fi

echo "→ Downscaling to all macOS icon sizes…"
declare -a sizes=(16 32 64 128 256 512 1024)
for s in "${sizes[@]}"; do
  sips -z "$s" "$s" "$TMP/icon_1024.png" --out "$TMP/icon_${s}.png" >/dev/null
done

echo "→ Assembling AppIcon.appiconset at $OUT…"
mkdir -p "$OUT"
# macOS app icons map: filename = base@scale
# 16, 16@2x=32, 32, 32@2x=64, 128, 128@2x=256, 256, 256@2x=512, 512, 512@2x=1024
cp "$TMP/icon_16.png"   "$OUT/icon_16x16.png"
cp "$TMP/icon_32.png"   "$OUT/icon_16x16@2x.png"
cp "$TMP/icon_32.png"   "$OUT/icon_32x32.png"
cp "$TMP/icon_64.png"   "$OUT/icon_32x32@2x.png"
cp "$TMP/icon_128.png"  "$OUT/icon_128x128.png"
cp "$TMP/icon_256.png"  "$OUT/icon_128x128@2x.png"
cp "$TMP/icon_256.png"  "$OUT/icon_256x256.png"
cp "$TMP/icon_512.png"  "$OUT/icon_256x256@2x.png"
cp "$TMP/icon_512.png"  "$OUT/icon_512x512.png"
cp "$TMP/icon_1024.png" "$OUT/icon_512x512@2x.png"

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16.png",     "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "icon_16x16@2x.png",  "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32.png",     "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "icon_32x32@2x.png",  "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128.png",   "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "icon_128x128@2x.png","scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256.png",   "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "icon_256x256@2x.png","scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512.png",   "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "icon_512x512@2x.png","scale" : "2x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

# Root Assets.xcassets Contents.json (minimal)
cat > "$ROOT/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

rm -rf "$TMP"
echo "✓ AppIcon.appiconset written to $OUT"
