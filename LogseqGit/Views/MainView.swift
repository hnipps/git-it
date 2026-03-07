import SwiftUI

// MARK: - MainViewModel

final class MainViewModel: ObservableObject {

    // MARK: - Published State

    @Published var config: AppConfig?
    @Published var recentActivity: [SyncLogEntry] = []
    @Published var errorMessage: String?
    @Published var hasLocalChanges: Bool = false

    // MARK: - Dependencies

    let gitService: GitService

    private let configService: ConfigService
    private let logger = SyncLogger.shared

    // MARK: - Init

    init(gitService: GitService = GitService(), configService: ConfigService = .shared) {
        self.gitService = gitService
        self.configService = configService
    }

    // MARK: - Data Loading

    @MainActor
    func loadData() async {
        config = configService.loadConfig()
        recentActivity = logger.getRecentEntries(limit: 10)
        await checkForLocalChanges()
    }

    @MainActor
    func refresh() async {
        await loadData()
    }

    // MARK: - Sync Actions

    @MainActor
    func pull() async {
        errorMessage = nil
        do {
            let result = try await gitService.pull()
            logger.log(SyncLogEntry(action: "pull", message: result.logMessage))
            config = configService.loadConfig()
        } catch {
            errorMessage = error.localizedDescription
            logger.log(SyncLogEntry(action: "error", message: "Pull failed: \(error.localizedDescription)"))
        }
        recentActivity = logger.getRecentEntries(limit: 10)
        await checkForLocalChanges()
    }

    @MainActor
    func push() async {
        errorMessage = nil
        do {
            let result = try await gitService.commitAndPush()
            logger.log(SyncLogEntry(action: "push", message: result.message))
            config = configService.loadConfig()
        } catch {
            errorMessage = error.localizedDescription
            logger.log(SyncLogEntry(action: "error", message: "Push failed: \(error.localizedDescription)"))
        }
        recentActivity = logger.getRecentEntries(limit: 10)
        await checkForLocalChanges()
    }

    @MainActor
    func syncNow() async {
        errorMessage = nil
        do {
            let pullResult = try await gitService.pull()
            logger.log(SyncLogEntry(action: "pull", message: pullResult.logMessage))

            if case .conflictBranch = pullResult {
                recentActivity = logger.getRecentEntries(limit: 10)
                return
            }

            let pushResult = try await gitService.commitAndPush()
            if pushResult.committed {
                logger.log(SyncLogEntry(action: "push", message: pushResult.message))
            }
            config = configService.loadConfig()
        } catch {
            errorMessage = error.localizedDescription
            logger.log(SyncLogEntry(action: "error", message: "Sync failed: \(error.localizedDescription)"))
        }
        recentActivity = logger.getRecentEntries(limit: 10)
        await checkForLocalChanges()
    }

    // MARK: - Helpers

    @MainActor
    private func checkForLocalChanges() async {
        do {
            hasLocalChanges = try await gitService.hasUncommittedChanges()
        } catch {
            hasLocalChanges = false
        }
    }

    /// Whether any git operation is currently in progress.
    var isSyncing: Bool {
        switch gitService.status {
        case .idle, .error:
            return false
        case .pulling, .pushing, .cloning, .committing:
            return true
        }
    }
}

// MARK: - MainView

struct MainView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var showSettings = false
    @State private var showError = false

    var body: some View {
        NavigationStack {
            List {
                graphInfoSection
                syncStatusSection
                syncActionsSection
                recentActivitySection
            }
            .navigationTitle("LogseqGit")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.loadData()
            }
            .onChange(of: viewModel.errorMessage) { newValue in
                showError = newValue != nil
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred.")
            }
        }
    }

    // MARK: - Graph Info Section

    private var graphInfoSection: some View {
        Section {
            if let config = viewModel.config {
                LabeledContent("Graph", value: config.graphName.isEmpty ? "Unnamed" : config.graphName)
                LabeledContent("Remote", value: truncatedURL(config.remoteURL))
                LabeledContent("Branch", value: config.branch)
            } else {
                Text("No configuration found")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Repository")
        }
    }

    // MARK: - Sync Status Section

    private var syncStatusSection: some View {
        Section {
            HStack {
                statusDot
                Text(statusLabel)
            }

            if let config = viewModel.config {
                if let lastPull = config.lastPull {
                    LabeledContent("Last pull", value: relativeDate(lastPull))
                }
                if let lastPush = config.lastPush {
                    LabeledContent("Last push", value: relativeDate(lastPush))
                }
            }
        } header: {
            Text("Status")
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        if viewModel.isSyncing {
            return .blue
        }

        switch viewModel.gitService.status {
        case .error:
            return .red
        default:
            return viewModel.hasLocalChanges ? .yellow : .green
        }
    }

    private var statusLabel: String {
        if viewModel.isSyncing {
            switch viewModel.gitService.status {
            case .pulling: return "Pulling..."
            case .pushing: return "Pushing..."
            case .committing: return "Committing..."
            case .cloning: return "Cloning..."
            default: return "Syncing..."
            }
        }

        switch viewModel.gitService.status {
        case .error(let message):
            return "Error: \(message)"
        default:
            return viewModel.hasLocalChanges ? "Local changes" : "Up to date"
        }
    }

    // MARK: - Sync Actions Section

    private var syncActionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.pull() }
                } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSyncing)

                Button {
                    Task { await viewModel.push() }
                } label: {
                    Label("Push", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSyncing)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

            Button {
                Task { await viewModel.syncNow() }
            } label: {
                HStack {
                    Spacer()
                    if viewModel.isSyncing {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSyncing)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Recent Activity Section

    private var recentActivitySection: some View {
        Section {
            if viewModel.recentActivity.isEmpty {
                Text("No recent activity")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentActivity.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconForAction(entry.action))
                            .foregroundStyle(colorForAction(entry.action))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.subheadline)
                            Text(relativeDate(entry.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Recent Activity")
        }
    }

    // MARK: - Formatting Helpers

    private func truncatedURL(_ url: String) -> String {
        if url.count > 35 {
            return String(url.prefix(15)) + "..." + String(url.suffix(17))
        }
        return url
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func iconForAction(_ action: String) -> String {
        switch action {
        case "pull": return "arrow.down.circle.fill"
        case "push", "background-push": return "arrow.up.circle.fill"
        case "commit": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle.fill"
        }
    }

    private func colorForAction(_ action: String) -> Color {
        switch action {
        case "pull": return .blue
        case "push", "background-push": return .green
        case "commit": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}
