#!/bin/zsh
# Builds and exports TinyTimer.app with Xcode (xcodegen + xcodebuild archive/export).
# Usage: ./xcode-export.sh [--install] [--open]
# Output: build/TinyTimer.xcarchive, build/export/TinyTimer.app
set -euo pipefail
cd "$(dirname "$0")"

# Use Xcode even if xcode-select points to Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
"$XCODEGEN" generate --quiet

ARCHIVE=build/TinyTimer.xcarchive
EXPORT=build/export
rm -rf "$ARCHIVE" "$EXPORT"

xcodebuild archive \
    -project TinyTimer.xcodeproj \
    -scheme TinyTimer \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build/DerivedData \
    -quiet

if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT" \
        -exportOptionsPlist ExportOptions.plist \
        -quiet; then
    echo "exportArchive failed (no team / signing); copying the app from the archive instead" >&2
    rm -rf "$EXPORT"; mkdir -p "$EXPORT"
    cp -R "$ARCHIVE/Products/Applications/TinyTimer.app" "$EXPORT/"
fi

APP=$EXPORT/TinyTimer.app
[[ -d "$APP" ]] || { echo "No $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "Exported $APP"

if [[ " $* " == *" --install "* ]]; then
    pkill -x TinyTimer 2>/dev/null || true
    pkill -x TT 2>/dev/null || true       # the app's old name
    rm -rf /Applications/TinyTimer.app /Applications/TT.app
    cp -R "$APP" /Applications/
    APP=/Applications/TinyTimer.app
    echo "Installed $APP"
fi

if [[ " $* " == *" --open "* ]]; then
    open "$APP"
fi
