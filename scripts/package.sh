#!/bin/bash
#
#------------------------------------------------------------------------------
# Builds an Apple Silicon (arm64) MacPortsApp.app plus zip, pkg and 
# dmg in dist/.
#
# Usage:
#  scripts/package.sh [version]
#
#  (defaults to the latest git tag, or 0.1.0)
#------------------------------------------------------------------------------
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
APP="dist/MacPortsApp.app"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacPortsApp" "$APP/Contents/MacOS/MacPortsApp"
cp -R "$BIN_DIR"/*.bundle "$APP/Contents/Resources/"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacPortsApp</string>
    <key>CFBundleDisplayName</key><string>MacPortsApp</string>
    <key>CFBundleIdentifier</key><string>com.example.ports</string>
    <key>CFBundleExecutable</key><string>MacPortsApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: runs locally; distribute widely only after signing with a Developer ID and notarizing.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "dist/MacPortsApp-${VERSION}.zip"

# Installer package: installs MacPortsApp.app into /Applications
# (unsigned; sign with a Developer ID Installer cert for distribution).
pkgbuild --component "$APP" --install-location /Applications \
    --identifier com.example.ports --version "$VERSION" "dist/MacPortsApp-${VERSION}.pkg"

# Disk image with the app and an /Applications shortcut for drag-and-drop install.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/MacPortsApp-${VERSION}.dmg"
# macOS 27 deprecates `hdiutil create` and it fails there ("Resource busy");
# `diskutil image create from` replaces it. Older systems lack the latter.
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --volumeName "MacPortsApp" --format UDZO "$STAGE" "$DMG" >/dev/null
else
    hdiutil create -quiet -volname "MacPortsApp" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi
rm -rf "$STAGE"

echo "Built $APP, dist/MacPortsApp-${VERSION}.zip, .pkg and .dmg"
