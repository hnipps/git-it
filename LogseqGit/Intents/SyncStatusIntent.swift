import AppIntents

struct SyncStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Logseq Sync Status"
    static var description = IntentDescription("Check the current sync status of your Logseq graph")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let gitService = GitService()
        let status = try await gitService.getStatus()
        let config = await ConfigService.shared.loadConfig()

        var parts: [String] = []

        if !status.isEmpty {
            parts.append("\(status.count) local changes")
        } else {
            parts.append("No local changes")
        }

        if let lastPull = config?.lastPull {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Last pull: \(formatter.localizedString(for: lastPull, relativeTo: Date()))")
        }

        if let lastPush = config?.lastPush {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Last push: \(formatter.localizedString(for: lastPush, relativeTo: Date()))")
        }

        let message = parts.joined(separator: ". ")
        return .result(value: message)
    }
}
