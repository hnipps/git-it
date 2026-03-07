import AppIntents

struct CommitAndPushIntent: AppIntent {
    static var title: LocalizedStringResource = "Push Logseq Graph"
    static var description = IntentDescription("Commit all changes and push to the remote repository")

    @Parameter(title: "Commit Message")
    var commitMessage: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let gitService = GitService()
        let result = try await gitService.commitAndPush(message: commitMessage)

        SyncLogger.shared.log(SyncLogEntry(action: "push", message: result.message))
        return .result(value: result.message)
    }
}
