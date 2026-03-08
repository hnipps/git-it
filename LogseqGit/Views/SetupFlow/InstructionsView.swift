import SwiftUI

struct InstructionsView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    /// Closure invoked when the user taps "Done" to dismiss the setup flow.
    var onDismiss: () -> Void

    var body: some View {
        List {
            logseqSection
            shortcutsSection
        }
        .navigationTitle("Get Started")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    onDismiss()
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier(AccessibilityID.instructionsDoneButton)
            }
        }
    }

    // MARK: - Logseq Setup

    @ViewBuilder
    private var logseqSection: some View {
        Section {
            instructionRow(
                step: 1,
                icon: "app.badge",
                text: "Open Logseq"
            )
            instructionRow(
                step: 2,
                icon: "gearshape",
                text: "Tap \"Add Graph\" or go to Settings \u{2192} Graph"
            )
            instructionRow(
                step: 3,
                icon: "folder",
                text: "Browse to \"\(viewModel.graphName)\" in the file picker"
            )
            instructionRow(
                step: 4,
                icon: "checkmark.circle",
                text: "Select the folder to open your graph"
            )
        } header: {
            Text("Configure Logseq")
        } footer: {
            Text("Point Logseq at the cloned repository so it can read and write your graph files.")
        }
    }

    // MARK: - Shortcuts Automation

    @ViewBuilder
    private var shortcutsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                automationRow(
                    icon: "arrow.down.circle",
                    title: "Pull on Open",
                    description: "When Logseq opens \u{2192} Run \"Pull Logseq Graph\""
                )
                Divider()
                automationRow(
                    icon: "arrow.up.circle",
                    title: "Push on Background",
                    description: "When Logseq closes \u{2192} Run \"Push Logseq Graph\""
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Shortcuts Automations")
        } footer: {
            Text("Set up these automations in the Shortcuts app to keep your graph in sync automatically.")
        }
    }

    // MARK: - Row Helpers

    @ViewBuilder
    private func instructionRow(step: Int, icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text("\(step)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
            }

            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func automationRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
