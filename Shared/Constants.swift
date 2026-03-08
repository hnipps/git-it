import Foundation

enum Constants {
    // MARK: - Identifiers

    static let appGroupID = "group.com.logseqgit"
static let fileProviderDomainID = "logseq-repo"
    static let bgTaskIdentifier = "com.logseqgit.sync"

    // MARK: - Shared Container Paths

    static let sharedContainerURL: URL = {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            fatalError("Shared container not available for app group: \(appGroupID)")
        }
        return url
    }()

    static let repoPath = sharedContainerURL.appendingPathComponent("repo", isDirectory: true)
    static let configFilePath = sharedContainerURL.appendingPathComponent("config.json")
    static let syncLogPath = sharedContainerURL.appendingPathComponent("sync.log")
    static let databasePath = sharedContainerURL.appendingPathComponent("logseqgit.sqlite")

    // MARK: - Darwin Notification Names

    enum DarwinNotification {
        static let syncDidComplete = "com.logseqgit.notification.syncDidComplete"
        static let configDidChange = "com.logseqgit.notification.configDidChange"
        static let fileProviderDidUpdate = "com.logseqgit.notification.fileProviderDidUpdate"
    }
}
