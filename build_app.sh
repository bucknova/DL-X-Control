#!/bin/zsh
# Builds "DL-X Control.app". The Command Line Tools are enough; Xcode isn't needed.
#
#   ./build_app.sh                 Apple Silicon (default)
#   ./build_app.sh universal       Apple Silicon and Intel
#   VERSION=1.2.0 ./build_app.sh   Sets the version shown by the app
set -e
cd "${0:A:h}"
ARCH="${1:-arm64}"
VERSION="${VERSION:-1.0}"
case "$ARCH" in
  arm64) ARCH_FLAGS=(--arch arm64) ;;
  universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
  *) echo "Unknown architecture: $ARCH (use arm64 or universal)"; exit 2 ;;
esac
swift build -c release --product DLXControl "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --product DLXControl "${ARCH_FLAGS[@]}" --show-bin-path)"
APP="build/DL-X Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DLXControl" "$APP/Contents/MacOS/DLXControl"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.bucknova.dlxcontrol</string>
<key>CFBundleName</key><string>DL-X Control</string>
<key>CFBundleDisplayName</key><string>DL-X Control</string>
<key>CFBundleExecutable</key><string>DLXControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>DL-X Control connects to your ATORCH DL24P load tester over Bluetooth.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP ($(lipo -archs "$APP/Contents/MacOS/DLXControl"))"
