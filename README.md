# Ports

A native macOS GUI for [MacPorts](https://www.macports.org). It sits on top of an existing MacPorts installation and drives the `port` command line tool.

## Status

Early development. Currently implemented:

- [x] List installed ports (name, version, revision, variants, active/inactive)
- [x] Port details (description, homepage, license, dependencies, dependents, installed files)
- [x] Search available ports (Available tab: type a term, press Return)
- [x] Install an available port (asks for your administrator password)
- [x] Live activity log (bottom panel, toggle from the toolbar) streaming install output
- [x] Sidebar layout (Installed / Available), ready for more tabs
- [x] Uninstall an installed port (with confirmation)
- [x] Outdated tab: list outdated ports, upgrade one or all (asks for your administrator password)
- [x] Inactive tab: list old versions left behind by upgrades; remove one or all (asks for your administrator password)
- [x] Variant selection on install (Install opens a sheet listing the port's variants)
- [x] Pre-built binary indicator (detail pane and install sheet; warns that non-default variants build from source)
- [x] Live install status in the Available table (Downloading…, Building…, dependencies included)
- [x] Self-update and Sync buttons in the Configuration tab (ask for your administrator password)
- [x] Configuration tab with a verbose output setting (off by default)
- [x] Resizable Activity pane (height is remembered)
- [x] MacPorts info in the Configuration tab (version, prefix, paths, installed count, sources)
- [x] Diagnose button (`port diagnose`) in the Configuration tab
- [x] Custom `port` executable path in the Configuration tab (for MacPorts installed outside /opt/local)
- [x] Add and remove ports sources (sources.conf) from the Configuration tab
- [x] Help menu with a quick guide and MacPorts links

## MacPorts logo

The app shows the MacPorts logo in the About panel and the empty state, loaded from
`Sources/PortsApp/Resources/MacPortsLogo.svg` (`.pdf` / `.png` also work).

## Requirements

- macOS 26 (Tahoe) or later
- MacPorts installed at `/opt/local` (`/opt/local/bin/port`)
- Xcode / Swift 6 toolchain

## Build and run

```sh
swift run PortsApp
swift test
```

Or open `Package.swift` in Xcode and run the `PortsApp` scheme.

## Layout

- `Sources/PortsKit`: UI-independent library. Wraps the `port` CLI and parses its output.
- `Sources/PortsApp`: SwiftUI application.
- `Tests/PortsKitTests`: unit tests for the parser.

## Development

This repo uses git flow (`main`, `develop`, `feature/*`, ...). Start work with `git flow feature start <name>`.

## Release package

`scripts/package.sh [version]` builds a universal release `dist/Ports.app` (ad-hoc signed) and
`dist/Ports-<version>.zip`. To distribute beyond your own machines, sign with a Developer ID and notarize.
