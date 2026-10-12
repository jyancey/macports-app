# MacPorts

A native macOS GUI for [MacPorts](https://www.macports.org). It sits on top of an existing MacPorts installation and drives the `port` command line tool.

## How it works

MacPorts App is a native SwiftUI front end for an installed MacPorts environment. It uses the configured `port` executable for searches, installs, upgrades, removals, diagnostics, maintenance, and `port select` operations. Commands that modify the system request macOS administrator authorization, and their output is streamed to the Activity pane so long-running builds remain visible and can be stopped.

The main window is organized into tabs for installed, available, outdated and inactive ports, along with `port select` selections. App preferences, MacPorts configuration, and health checks live in the Settings window (⌘,). Selecting a port opens details such as its description, variants, dependencies, dependents, and installed files. Installed-port and file information is read directly from the MacPorts registry when possible, while available-port searches use the ports tree.

Features include:

- Search available ports by name, description, exact match, or regular expression.
- Install ports with variant selection and pre-built binary hints.
- Upgrade outdated ports individually or in batches, and activate or remove inactive versions.
- View and change selected versions for groups such as Python, Clang, and GCC.
- Run `port diagnose`, check registry integrity, and launch `port reclaim` in Terminal.
- Configure the `port` executable path, verbosity, Activity-pane behavior, and ports sources in Settings (⌘,), and run Self-update or Sync from Settings or the MacPorts menu.
- Use keyboard shortcuts, context menus, resizable list/detail panes, and a persistent Activity log.

## Status

Early development.

## Architecture

How the main views fit together. `MacPortsApp` owns the app-wide models (`ActivityLog`, `ConfigurationModel`, `HealthModel`) and shares them between the main window and the Settings window.

```
MacPortsApp (App)
├─ WindowGroup
│  └─ ContentView
│     ├─ Environment: ActivityLog, PortDetailCache, PortActions
│     └─ NavigationSplitView
│        ├─ Sidebar (List of BrowseMode)
│        │   └─ Items: Installed, Available, Outdated, Inactive, Selections
│        ├─ Content (mainPane switch on BrowseMode)
│        │   ├─ Installed → InstalledListView
│        │   ├─ Available → SearchResultsView (Match picker in its header)
│        │   ├─ Outdated → OutdatedListView
│        │   ├─ Inactive → InactiveListView
│        │   └─ Selections → SelectionsListView (read-only table of groups)
│        └─ Detail (detailPane switch on selection + mode)
│            ├─ Available + selected result → PortDetailView(name:isInstalled:...)
│            ├─ Outdated + single selection → PortDetailView(canUpgrade: true)
│            ├─ Outdated + multi-selection → BatchSelectionView (Upgrade)
│            ├─ Inactive + single selection → PortDetailView(inactiveVersion: ...)
│            ├─ Inactive + multi-selection → BatchSelectionView (Remove)
│            ├─ Installed + selected row
│            │   ├─ Active → PortDetailView(canUpgrade: update != nil)
│            │   └─ Inactive → PortDetailView(inactiveVersion: ...)
│            ├─ Selections + selected group → SelectionDetailView (Select / Unset)
│            └─ No selection → ContentUnavailableView (prompt + AppIconImage)
│            + Activity Pane (ActivityPane) appended below detail when visible
├─ Settings (⌘,) → SettingsView
│  ├─ General → GeneralSettingsView (Activity options, port executable path)
│  ├─ MacPorts → MacPortsSettingsView (installation facts, Self-update/Sync, sources)
│  └─ Health → HealthView (port diagnose, registry integrity, port reclaim)
├─ Window "Help" → HelpView
└─ Commands → AppCommands (Find, View menu tabs/panes, MacPorts menu)

Toolbars (ContentView.toolbar)
├─ Activity toggle (ActivityToolbarIcon)
├─ Pre-built only toggles (Available/Outdated)
├─ Upgrade buttons (Outdated)
├─ Remove buttons (Inactive)
├─ Refresh
└─ Search/filter field (.searchable; Installed, Available, Outdated, Inactive)

Sheets & Dialogs (ContentView)
├─ .sheet → InstallOptionsView (on install request)
├─ .confirmationDialog → Uninstall confirmation
├─ .confirmationDialog → Activate confirmation
└─ .confirmationDialog → Remove All Inactive confirmation

PortDetailView (when shown)
├─ Header (icon, title, subtitle, action buttons, binary badge)
├─ Info Section
│   └─ Grid rows: categories, homepage, license, maintainers, variants, platforms, sub-ports, library/build/runtime deps (portLinks)
├─ Dependents Section
│   └─ portLinks (open other ports via onOpenPort)
├─ Dependency Tree Section
│   └─ DisclosureGroup → TreeRow (recursive)
└─ Files Section
    └─ DisclosureGroup → FileListView

InstallOptionsView (sheet)
├─ Variants list (Toggle per variant)
└─ Build notice (binary availability / customized variants)
```

## App icon

The About panel and the empty state show the app icon (`Resources/AppIcon.png`).

## Requirements

- macOS 26 (Tahoe) or later
- MacPorts, by default at `/opt/local` (`/opt/local/bin/port`); another location can be set in Settings → General
- Xcode 26 (Swift 6.2 or later)

## Build and run

```sh
swift run MacPortsApp
swift test
```

Or open `Package.swift` in Xcode and run the `MacPortsApp` scheme.

## Layout

- `Sources/PortsKit`: UI-independent library. Wraps the `port` CLI, reads the MacPorts registry, and parses `port` output.
- `Sources/PortsApp`: SwiftUI application.
- `Tests/PortsKitTests`: unit tests for PortsKit, plus live tests that run only when MacPorts is installed.
- `Tests/MacPortsAppTests`: unit tests for the app's models and actions.

## Development

This repo uses git flow (`main`, `develop`, `feature/*`, ...). Start work with `git flow feature start <name>`.

CI (`.github/workflows/ci.yml`) builds and tests every push and pull request to `main` and `develop`: on the GitHub-hosted `macos-26` runner on GitHub, and on the self-hosted `macos-arm64` runner on Gitea.

## Release package

`scripts/package.sh [version]` builds an Apple Silicon (arm64-only) release `dist/MacPortsApp.app` (ad-hoc signed), a zip
(`dist/MacPortsApp-<version>.zip`), a disk image (`dist/MacPortsApp-<version>.dmg`, drag to Applications) and an installer (`dist/MacPortsApp-<version>.pkg`, installs to /Applications). To distribute beyond your own machines, sign with a Developer ID and notarize.

### Publishing a release

Releases follow git flow, and `scripts/release.sh` does the whole sequence: it branches `release/<version>` from `develop`, bumps the fallback version in `Sources/PortsApp/PortsApp.swift`, runs the tests, merges into `main`, tags `main` with an annotated tag whose message holds the release notes, and merges `main` back into `develop`:

```sh
scripts/release.sh --dry-run 0.4.3          # show the notes and steps
scripts/release.sh 0.4.3                    # cut it locally
scripts/release.sh --notes notes.md --push 0.4.3   # own notes, push to every remote
```

Without `--notes`, the notes list the commit subjects on `develop` since the last release. The script refuses to run with uncommitted changes, an existing tag, a version that doesn't come after the current one, or a remote `main`/`develop` that has commits the local one lacks. If a step fails it stops and says which, leaving the repository as it is. Without `--push` it prints the push commands instead.

Pushing the tag runs the Release workflow (`.github/workflows/release.yml`). It checks that the tag matches the app's version (`scripts/release-notes.sh`), runs the tests, builds the zip, pkg and dmg with `scripts/package.sh`, and publishes a release with them attached. The tag message's body (or its subject, if there is no body) becomes the release notes. Tags containing a `-`, such as `0.5.0-rc.1`, are published as pre-releases. On GitHub the release is created with `gh`; on Gitea, `scripts/gitea-release.sh` uses the Gitea API. To rebuild an existing release, run the workflow by hand with the tag as input.

The app icon is generated by `python3 Design/make_icon.py` (needs Pillow) into `Design/AppIcon.icns`, which `package.sh` bundles.
