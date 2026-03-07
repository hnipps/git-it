import SwiftUI

// MARK: - SettingsViewModel

final class SettingsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var remoteURL: String = ""
    @Published var branch: String = ""
    @Published var graphName: String = ""
    @Published var authMethod: AuthMethod = .ssh
    @Published var commitMessageTemplate: String = ""

    @Published var hasUnsavedChanges: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?

    // MARK: - Sheet State

    @Published var showSSHKeySheet: Bool = false
    @Published var showPATSheet: Bool = false
    @Published var showClearLogsConfirmation: Bool = false
    @Published var showResetConfirmation: Bool = false
    @Published var showExportSheet: Bool = false

    @Published var newSSHKey: String = ""
    @Published var newPAT: String = ""

    // MARK: - Dependencies

    private let configService: ConfigService
    private let keychainService: KeychainService
    private let logger = SyncLogger.shared

    // MARK: - Init

    init(
        configService: ConfigService = .shared,
        keychainService: KeychainService = .shared
    ) {
        self.configService = configService
        self.keychainService = keychainService
    }

    // MARK: - Load

    @MainActor
    func loadConfig() async {
        guard let config = await configService.loadConfig() else { return }
        remoteURL = config.remoteURL
        branch = config.branch
        graphName = config.graphName
        authMethod = config.authMethod
        commitMessageTemplate = config.commitMessageTemplate
        hasUnsavedChanges = false
    }

    // MARK: - Save

    @MainActor
    func save() async {
        isSaving = true
        errorMessage = nil

        do {
            var config = await configService.loadConfig() ?? AppConfig(
                remoteURL: remoteURL,
                authMethod: authMethod
            )
            config.remoteURL = remoteURL
            config.branch = branch
            config.graphName = graphName
            config.commitMessageTemplate = commitMessageTemplate
            try await configService.saveConfig(config)
            hasUnsavedChanges = false
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }

    func markChanged() {
        hasUnsavedChanges = true
    }

    // MARK: - Auth Actions

    @MainActor
    func saveSSHKey() async {
        errorMessage = nil
        do {
            try keychainService.importSSHKey(fromText: newSSHKey)
            newSSHKey = ""
            showSSHKeySheet = false
        } catch {
            errorMessage = "Failed to import SSH key: \(error.localizedDescription)"
        }
    }

    @MainActor
    func savePAT() async {
        errorMessage = nil
        do {
            try keychainService.storePAT(newPAT)
            newPAT = ""
            showPATSheet = false
        } catch {
            errorMessage = "Failed to store token: \(error.localizedDescription)"
        }
    }

    // MARK: - Log Actions

    func exportLogText() -> String {
        let entries = logger.getRecentEntries(limit: 100)
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            "[\(formatter.string(from: entry.date))] [\(entry.action)] \(entry.message)"
        }.joined(separator: "\n")
    }

    func clearLogs() {
        logger.clearLog()
    }

    // MARK: - Reset

    @MainActor
    func resetAndReclone() async {
        errorMessage = nil
        do {
            guard let config = configService.loadConfig() else {
                errorMessage = "No configuration found to re-clone."
                return
            }

            let gitService = GitService(keychainService: keychainService, configService: configService)
            try await gitService.clone(remoteURL: config.remoteURL, branch: config.branch)
            logger.log(SyncLogEntry(action: "commit", message: "Repository reset and re-cloned"))
        } catch {
            errorMessage = "Reset failed: \(error.localizedDescription)"
            logger.log(SyncLogEntry(action: "error", message: "Reset failed: \(error.localizedDescription)"))
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showError = false

    var body: some View {
        Form {
            repositorySection
            authenticationSection
            syncSection
            logsSection
            dangerZoneSection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    Task { await viewModel.save() }
                }
                .disabled(!viewModel.hasUnsavedChanges || viewModel.isSaving)
            }
        }
        .task {
            await viewModel.loadConfig()
        }
        .onChange(of: viewModel.errorMessage) { newValue in
            showError = newValue != nil
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "An unknown error occurred.")
        }
    }

    // MARK: - Repository Section

    private var repositorySection: some View {
        Section {
            TextField("Remote URL", text: $viewModel.remoteURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { viewModel.markChanged() }
                .onChange(of: viewModel.remoteURL) { _ in viewModel.markChanged() }

            TextField("Branch", text: $viewModel.branch)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { viewModel.markChanged() }
                .onChange(of: viewModel.branch) { _ in viewModel.markChanged() }

            TextField("Graph name", text: $viewModel.graphName)
                .autocorrectionDisabled()
                .onSubmit { viewModel.markChanged() }
                .onChange(of: viewModel.graphName) { _ in viewModel.markChanged() }
        } header: {
            Text("Repository")
        }
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        Section {
            LabeledContent("Method", value: viewModel.authMethod == .ssh ? "SSH" : "HTTPS")

            if viewModel.authMethod == .ssh {
                Button("Change SSH Key") {
                    viewModel.showSSHKeySheet = true
                }
                .sheet(isPresented: $viewModel.showSSHKeySheet) {
                    sshKeySheet
                }
            } else {
                Button("Change Token") {
                    viewModel.showPATSheet = true
                }
                .sheet(isPresented: $viewModel.showPATSheet) {
                    patSheet
                }
            }
        } header: {
            Text("Authentication")
        }
    }

    private var sshKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $viewModel.newSSHKey)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Paste your SSH private key")
                } footer: {
                    Text("The key should begin with -----BEGIN OPENSSH PRIVATE KEY----- or similar.")
                }
            }
            .navigationTitle("SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.newSSHKey = ""
                        viewModel.showSSHKeySheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await viewModel.saveSSHKey() }
                    }
                    .disabled(viewModel.newSSHKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var patSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Personal Access Token", text: $viewModel.newPAT)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Generate a token with repo permissions from your Git provider.")
                }
            }
            .navigationTitle("Access Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.newPAT = ""
                        viewModel.showPATSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await viewModel.savePAT() }
                    }
                    .disabled(viewModel.newPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        Section {
            TextField("Commit message template", text: $viewModel.commitMessageTemplate)
                .autocorrectionDisabled()
                .onSubmit { viewModel.markChanged() }
                .onChange(of: viewModel.commitMessageTemplate) { _ in viewModel.markChanged() }
        } header: {
            Text("Sync")
        } footer: {
            Text("Placeholders: {{device}} (device name), {{timestamp}} (ISO 8601 date)")
        }
    }

    // MARK: - Logs Section

    private var logsSection: some View {
        Section {
            Button("Export Logs") {
                viewModel.showExportSheet = true
            }
            .sheet(isPresented: $viewModel.showExportSheet) {
                let logText = viewModel.exportLogText()
                ActivityView(activityItems: [logText])
            }

            Button("Clear Logs", role: .destructive) {
                viewModel.showClearLogsConfirmation = true
            }
            .confirmationDialog(
                "Clear all sync logs?",
                isPresented: $viewModel.showClearLogsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Logs", role: .destructive) {
                    viewModel.clearLogs()
                }
            } message: {
                Text("This action cannot be undone.")
            }
        } header: {
            Text("Logs")
        }
    }

    // MARK: - Danger Zone Section

    private var dangerZoneSection: some View {
        Section {
            Button("Reset & Re-clone", role: .destructive) {
                viewModel.showResetConfirmation = true
            }
            .confirmationDialog(
                "Reset & Re-clone?",
                isPresented: $viewModel.showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset & Re-clone", role: .destructive) {
                    Task { await viewModel.resetAndReclone() }
                }
            } message: {
                Text("This will delete the local repository and re-clone from the remote. Any uncommitted local changes will be lost.")
            }
        } header: {
            Text("Danger Zone")
        }
    }
}

// MARK: - ActivityView (UIKit Share Sheet)

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
