# Ports

A native macOS GUI for [MacPorts](https://www.macports.org). It sits on top of an existing MacPorts installation and drives the `port` command line tool.

## Status

Early development. Currently implemented:

- [x] List installed ports (name, version, revision, variants, active/inactive)
- [x] Port details (description, homepage, license, dependencies, dependents, installed files)
- [ ] Search available ports, install/uninstall/upgrade (planned)

## MacPorts logo

The app shows the MacPorts logo in the toolbar and the empty state. The official logo isn't bundled;
drop it in as `Sources/PortsApp/Resources/MacPortsLogo.svg` (or `.pdf` / `.png`) and rebuild.
Until then a placeholder symbol is shown.

## Requirements

- macOS 14 or later
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
