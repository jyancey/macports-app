#!/bin/bash
# Builds a release MacPorts.app and a zip of it in dist/.
# Usage: scripts/package.sh [version]   (defaults to the latest git tag, or 0.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
APP="dist/MacPorts.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PortsApp" "$APP/Contents/MacOS/PortsApp"
cp -R "$BIN_DIR"/*.bundle "$APP/Contents/Resources/"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacPorts</string>
    <key>CFBundleDisplayName</key><string>MacPorts</string>
    <key>CFBundleIdentifier</key><string>com.example.ports</string>
    <key>CFBundleExecutable</key><string>PortsApp</string>
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

ditto -c -k --keepParent "$APP" "dist/MacPorts-${VERSION}.zip"
# Installer package: installs MacPorts.app into /Applications (unsigned; sign with a Developer ID Installer cert for distribution).
pkgbuild --component "$APP" --install-location /Applications \
    --identifier com.example.ports --version "$VERSION" "dist/MacPorts-${VERSION}.pkg"

echo "Built $APP, dist/MacPorts-${VERSION}.zip and dist/MacPorts-${VERSION}.pkg"
