import Foundation

/// Represents the authentication method used to communicate with the remote repository.
enum AuthMethod: String, Codable, CaseIterable {
    case ssh
    case https
}

/// Persisted application configuration that is shared between the main app and the File Provider extension.
struct AppConfig: Codable, Equatable {
    /// The remote Git repository URL (e.g. git@github.com:user/repo.git or https://...).
    var remoteURL: String

    /// The authentication method for the remote.
    var authMethod: AuthMethod

    /// An optional keychain reference for the SSH private key.
    var sshKeyRef: String?

    /// The branch to track and sync against.
    var branch: String

    /// A human-readable name for the Logseq graph.
    var graphName: String

    /// Template for auto-generated commit messages.
    /// Supported placeholders: `{{device}}`, `{{timestamp}}`.
    var commitMessageTemplate: String

    /// Timestamp of the last successful pull.
    var lastPull: Date?

    /// Timestamp of the last successful push.
    var lastPush: Date?

    // MARK: - Defaults

    init(
        remoteURL: String,
        authMethod: AuthMethod,
        sshKeyRef: String? = nil,
        branch: String = "main",
        graphName: String = "",
        commitMessageTemplate: String = "Auto-sync from {{device}} at {{timestamp}}",
        lastPull: Date? = nil,
        lastPush: Date? = nil
    ) {
        self.remoteURL = remoteURL
        self.authMethod = authMethod
        self.sshKeyRef = sshKeyRef
        self.branch = branch
        self.graphName = graphName
        self.commitMessageTemplate = commitMessageTemplate
        self.lastPull = lastPull
        self.lastPush = lastPush
    }
}
