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
#
# Signing: by default the app is signed ad hoc, which runs anywhere but can't
# install the privileged helper (macOS only lets an app signed by the
# developer's team do that, and the helper only accepts such an app), so
# commands that need root use the macOS password prompt. To build the
# helper-capable app, name a signing identity from your keychain:
#
#  SIGN_IDENTITY="Developer ID Application: Your Name (8Z24F9PX5J)" scripts/package.sh
#
# (An "Apple Development" identity of the same team also works for testing.)
#------------------------------------------------------------------------------
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
APP="dist/MacPortsApp.app"
APP_ID="io.indegree.MacPortsApp"
HELPER_ID="io.indegree.MacPortsApp.helper"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacPortsApp" "$APP/Contents/MacOS/MacPortsApp"

# The privileged helper: a launchd daemon the app registers with SMAppService.
# Its plist goes in Contents/Library/LaunchDaemons; BundleProgram is relative
# to the app.
cp "$BIN_DIR/MacPortsHelper" "$APP/Contents/MacOS/MacPortsHelper"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cat > "$APP/Contents/Library/LaunchDaemons/${HELPER_ID}.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${HELPER_ID}</string>
    <key>BundleProgram</key><string>Contents/MacOS/MacPortsHelper</string>
    <key>MachServices</key>
    <dict>
        <key>${HELPER_ID}</key><true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>${APP_ID}</string>
    </array>
</dict>
</plist>
PLIST
cp -R "$BIN_DIR"/*.bundle "$APP/Contents/Resources/"
cp Design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacPortsApp</string>
    <key>CFBundleDisplayName</key><string>MacPortsApp</string>
    <key>CFBundleIdentifier</key><string>${APP_ID}</string>
    <key>CFBundleExecutable</key><string>MacPortsApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>MacPortsApp opens Terminal to run port reclaim.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Sign the helper first, under its own identifier (which the app's connection
# requirement names), then the app, which seals the helper inside it. Neither is
# signed with --deep: that would give the helper the wrong identifier.
# With a real identity the hardened runtime is on, as notarization requires;
# the app then needs the Apple Events entitlement to open Terminal for reclaim.
# Ad hoc (the default) runs locally; distribute widely only after signing with a
# Developer ID and notarizing.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$HELPER_ID" "$APP/Contents/MacOS/MacPortsHelper"
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
        --identifier "$HELPER_ID" "$APP/Contents/MacOS/MacPortsHelper"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
        --entitlements scripts/MacPortsApp.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Signed with: $([[ "$SIGN_IDENTITY" == "-" ]] && echo "ad hoc (no privileged helper)" || echo "$SIGN_IDENTITY")"

ditto -c -k --keepParent "$APP" "dist/MacPortsApp-${VERSION}.zip"

# Installer package: installs MacPortsApp.app into /Applications
# (unsigned; sign with a Developer ID Installer cert for distribution).
pkgbuild --component "$APP" --install-location /Applications \
    --identifier "$APP_ID" --version "$VERSION" "dist/MacPortsApp-${VERSION}.pkg"

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
