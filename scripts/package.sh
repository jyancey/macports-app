#!/bin/bash
# Builds a release Ports.app and a zip of it in dist/.
# Usage: scripts/package.sh [version]   (defaults to the latest git tag, or 0.1.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
APP="dist/Ports.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PortsApp" "$APP/Contents/MacOS/PortsApp"
cp -R "$BIN_DIR"/*.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ports</string>
    <key>CFBundleDisplayName</key><string>Ports</string>
    <key>CFBundleIdentifier</key><string>com.example.ports</string>
    <key>CFBundleExecutable</key><string>PortsApp</string>
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

ditto -c -k --keepParent "$APP" "dist/Ports-${VERSION}.zip"
echo "Built $APP and dist/Ports-${VERSION}.zip"
