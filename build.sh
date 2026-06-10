#!/bin/bash
# Собирает релизный бинарь и упаковывает в Movement_is_life.app (меню-бар, без Dock).
set -e
cd "$(dirname "$0")"

APP_NAME="Movement_is_life"
BUNDLE="$APP_NAME.app"

echo "→ swift build -c release"
swift build -c release

BIN=$(swift build -c release --show-bin-path)/MovementIsLife

echo "→ собираю $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Movement is life</string>
    <key>CFBundleIdentifier</key><string>local.movementislife</string>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "→ подпись (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "✓ готово: $BUNDLE"
echo "  запуск:  open \"$BUNDLE\""
