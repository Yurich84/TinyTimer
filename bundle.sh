#!/bin/zsh
# Builds TT.app from the SwiftPM package (works with Command Line Tools only, no Xcode).
# Usage: ./bundle.sh [--install] [--open]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native

APP=build/TT.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --build-system native --show-bin-path)/TT" "$APP/Contents/MacOS/TT"

# App icon: Resources/AppIcon.png (1024x1024) -> AppIcon.icns
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.tt.TimeTracker</string>
    <key>CFBundleName</key><string>TT</string>
    <key>CFBundleDisplayName</key><string>TT</string>
    <key>CFBundleExecutable</key><string>TT</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
    pkill -x TT 2>/dev/null || true
    rm -rf /Applications/TT.app
    cp -R "$APP" /Applications/
    APP=/Applications/TT.app
    echo "Installed $APP"
fi

if [[ " $* " == *" --open "* ]]; then
    open "$APP"
fi
