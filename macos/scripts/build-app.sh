#!/bin/bash
# Builds zitto.app in macos/build. Needs the Xcode command line tools (xcode-select --install).
#
#   macos/scripts/build-app.sh            for this Mac
#   macos/scripts/build-app.sh universal  for Apple silicon and Intel (needs the full Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' ../zitto/__init__.py)
if [ "${1:-}" = "universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    binary=.build/apple/Products/Release/Zitto
else
    swift build -c release
    binary="$(swift build -c release --show-bin-path)/Zitto"
fi

app=build/zitto.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Zitto"
sed "s/__VERSION__/$version/g" Resources/Info.plist > "$app/Contents/Info.plist"
cp ../LICENSE.md ../NOTICE.md "$app/Contents/Resources/"
# The icon, from Resources/AppIcon.png (drawn by scripts/make_icon.py).
icons=build/AppIcon.iconset
rm -rf "$icons" && mkdir -p "$icons"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$icons/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$icons/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icons" -o "$app/Contents/Resources/AppIcon.icns"
# Signed for this Mac only. To give it to others: a Developer ID and notarization.
codesign --force --sign - "$app"
echo "Ready: macos/$app"
echo "Run it with: open macos/$app"
