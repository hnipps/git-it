import AppIntents

struct PullIntent: AppIntent {
    static var title: LocalizedStringResource = "Pull Logseq Graph"
    static var description = IntentDescription("Fetch and pull latest changes from the remote git repository")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let gitService = GitService()
        let result = try await gitService.pull()
        SyncLogger.shared.log(SyncLogEntry(action: "pull", message: result.logMessage))
        return .result(value: result.logMessage)
    }
}
