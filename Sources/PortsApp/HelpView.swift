import SwiftUI

struct HelpView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("\(AppInfo.name) Help").font(.largeTitle.bold())
        section(
          "Browsing",
          [
            "Installed, Outdated and Inactive list what is on your system; Available searches the whole ports tree (press Return to search). The search field filters the other lists as you type.",
            "Select a port to see its details, variants and dependencies. Drag the divider between the list and the details to resize them.",
            "Right-click a port for Copy Name, Copy Install Command and the actions for that tab. ⌘C copies the selected port names.",
            "Click a dependency or a \"Required by\" name to jump to that port.",
            "Expand \"Full dependency tree\" to see everything a port needs, recursively.",
          ])
        section(
          "Installing",
          [
            "Choose variants in the detail pane before installing. A package icon marks ports that have a pre-built binary for your platform. In search results, the Pre-built column shows a green seal for ports with a binary for this Mac (first 100 results), and the toolbar's \"Pre-built only\" toggle filters to them.",
            "Status in the Available table updates live (Downloading…, Building…, Installing…).",
          ])
        section(
          "Health",
          [
            "The Health tab runs `port diagnose` and lists any warnings. Reclaim in Terminal opens Terminal running `sudo port reclaim`, which asks before removing anything."
          ])
        section(
          "Selections",
          [
            "The Selections tab lists `port select` groups (clang, python, gcc…) and which version each uses. Pick a version from the menu in the Selected column, or choose a group to Select a version or Unset it (uses macOS administrator authorization)."
          ])
        section(
          "Upgrading and cleanup",
          [
            "Outdated lists ports with newer versions (the Pre-built column shows whether the update has a binary for this Mac, and the toolbar toggle filters to those); Upgrade All runs `port upgrade outdated`. While an upgrade runs, the Status column shows what each port is doing.",
            "On Installed, an arrow next to the version marks a port with an update; its detail pane offers Upgrade.",
            "Inactive lists old versions. Remove one to reclaim space, or Activate it to go back to that version (the active version is deactivated and stays installed).",
            "On Outdated and Inactive, select several rows (⌘-click or ⇧-click) to upgrade or remove them with one authorization prompt.",
          ])
        section(
          "Activity pane",
          [
            "Shows the output of every port command. Drag the divider to resize it.",
            "If a command finishes or fails while you are in another app, the Dock icon bounces.",
            "Stop (⌘.) interrupts the running command and everything it started. A partly built port is kept, so installing it again resumes the build.",
            "The header shows the running command and how long it has run, or that the last command failed. A failed command always opens the pane, and the toolbar's Activity Log icon pulses while a command runs and turns into a red warning after a failure.",
          ])
        section(
          "Keyboard shortcuts",
          [
            "⌘F: search or filter ports (in the Activity log or a file list: find in that text).",
            "⌘1 to ⌘7: switch tabs. ⌘R: refresh. ⇧⌘L: show or hide the Activity log. ⌃⌘S: show or hide the sidebar.",
          ])
        section(
          "Configuration",
          [
            "Verbose output shows full port output but is slower.",
            "Self-update and Sync refresh MacPorts and the ports tree.",
            "Commands that change your system use macOS administrator authorization.",
          ])
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 480, minHeight: 420)
  }

  private func section(_ title: String, _ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.title3.bold())
      ForEach(items, id: \.self) { Text("• " + $0).fixedSize(horizontal: false, vertical: true) }
    }
  }
}
