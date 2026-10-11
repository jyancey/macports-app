import PortsKit
import SwiftUI

/// Shows one `port select` group and lets the user pick or unset its version.
struct SelectionDetailView: View {
  let group: PortSelectGroup
  let model: SelectionsModel
  @Environment(ActivityLog.self) private var activity

  var body: some View {
    Form {
      Section {
        LabeledContent("Currently selected", value: group.selected)
      } header: {
        Text(group.name).font(.title2.bold())
      }
      Section {
        ForEach(group.options.filter { $0 != "none" }, id: \.self) { option in
          HStack {
            Text(option)
            Spacer()
            if option == group.selected {
              StatusLabel("Selected", systemImage: "checkmark.circle.fill", color: .green)
            } else {
              Button("Select") { apply(option) }.disabled(activity.isRunning)
            }
          }
        }
        if group.isSet {
          Button("Unset", systemImage: "xmark.circle") { apply("none") }
            .disabled(activity.isRunning)
        }
      } header: {
        Text("Choose a version")
      } footer: {
        Text(
          "Selecting a version points the shared commands (such as \(group.name)) at it. "
            + "Changing it uses macOS administrator authorization.")
      }
    }
    .formStyle(.grouped)
  }

  private func apply(_ option: String) {
    Task { await model.select(option, in: group, activity: activity) }
  }
}
