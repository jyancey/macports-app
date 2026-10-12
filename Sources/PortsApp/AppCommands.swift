// AppCommands.swift - Menu bar commands for finding, switching tabs, the Activity log, and MacPorts maintenance.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import AppKit
import SwiftUI

/// What the menu bar can do in the frontmost window. `ContentView` publishes
/// it with `focusedSceneValue`, so the commands act on the key window and are
/// disabled when no window is open.
struct WindowActions {
  var mode: BrowseMode
  var showMode: (BrowseMode) -> Void
  var isSidebarVisible: Bool
  var toggleSidebar: () -> Void
  var isActivityVisible: Bool
  var toggleActivity: () -> Void
  var canRefresh: Bool
  var refresh: () -> Void
  /// Whether the current tab has a search or filter field.
  var canSearch: Bool
  var focusSearch: () -> Void
}

extension FocusedValues {
  @Entry var windowActions: WindowActions?
}

/// Menu bar commands: Find; View menu items for the sidebar, the Activity
/// log, the tabs, Refresh and stopping the running command; and a MacPorts
/// menu for updating MacPorts.
struct AppCommands: Commands {
  @FocusedValue(\.windowActions) private var window
  /// App-wide, so Stop works whichever window is in front.
  let activity: ActivityLog
  /// Reread after Self-update or Sync.
  let configuration: ConfigurationModel

  var body: some Commands {
    // Replaces the standard Find submenu so that Find (⌘F) also reaches the
    // toolbar search field; in the Activity log or a file list it still opens
    // that text's find bar.
    CommandGroup(replacing: .textEditing) {
      Menu("Find") {
        Button("Find…") {
          if !TextFinderCommand.perform(.showFindInterface) { window?.focusSearch() }
        }
        .keyboardShortcut("f")
        Button("Find Next") { TextFinderCommand.perform(.nextMatch) }
          .keyboardShortcut("g")
        Button("Find Previous") { TextFinderCommand.perform(.previousMatch) }
          .keyboardShortcut("g", modifiers: [.command, .shift])
        Button("Use Selection for Find") { TextFinderCommand.perform(.setSearchString) }
          .keyboardShortcut("e")
      }
    }
    CommandGroup(before: .toolbar) {
      Button(window?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
        window?.toggleSidebar()
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(window == nil)
      Button(window?.isActivityVisible == true ? "Hide Activity Log" : "Show Activity Log") {
        window?.toggleActivity()
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
      .disabled(window == nil)
      Divider()
      ForEach(Array(BrowseMode.allCases.enumerated()), id: \.element) { index, mode in
        Toggle(mode.rawValue, isOn: tabBinding(mode))
          .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
          .disabled(window == nil)
      }
      Divider()
      Button("Refresh") { window?.refresh() }
        .keyboardShortcut("r")
        .disabled(window?.canRefresh != true)
      Button("Stop Command") { activity.requestStop() }
        .keyboardShortcut(".")
        .disabled(!activity.canStop)
      Divider()
    }
    CommandMenu("MacPorts") {
      ForEach(MacPortsMaintenance.allCases, id: \.self) { task in
        Button(task.title) { task.run(activity: activity, configuration: configuration) }
          .disabled(activity.isRunning)
      }
    }
  }

  /// Checked for the current tab; choosing it switches to that tab.
  private func tabBinding(_ mode: BrowseMode) -> Binding<Bool> {
    Binding(
      get: { window?.mode == mode },
      set: { _ in window?.showMode(mode) })
  }
}

/// Sends find commands to the focused read-only text view (the Activity log
/// or a port's installed files), the way the standard Find menu would.
@MainActor
enum TextFinderCommand {
  /// The focused text view that has a find bar. Text fields (including the
  /// toolbar search field) use a field editor and are left out.
  static var focusedTextView: NSTextView? {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
      !textView.isFieldEditor, textView.usesFindBar
    else { return nil }
    return textView
  }

  /// Returns false when no such text view has focus.
  @discardableResult
  static func perform(_ action: NSTextFinder.Action) -> Bool {
    guard let textView = focusedTextView else { return false }
    // `performTextFinderAction` reads the action from the sender's tag.
    let sender = NSMenuItem()
    sender.tag = action.rawValue
    textView.performTextFinderAction(sender)
    return true
  }
}
