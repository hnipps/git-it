import Foundation

/// Represents the authentication method used to communicate with the remote repository.
enum AuthMethod: String, CaseIterable {
    case https

    /// SSH was removed (GitHub rejects SHA-1 signatures from bundled libssh2).
    /// Existing configs that stored "ssh" are migrated to .https on decode.
    private static let legacyMappings: [String: AuthMethod] = ["ssh": .https]
}

extension AuthMethod: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = AuthMethod(rawValue: raw) {
            self = value
        } else if let mapped = AuthMethod.legacyMappings[raw] {
            self = mapped
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Cannot initialize AuthMethod from invalid String value \(raw)")
            )
        }
    }
}

/// Persisted application configuration that is shared between the main app and the File Provider extension.
struct AppConfig: Codable, Equatable {
    /// The remote Git repository URL (e.g. git@github.com:user/repo.git or https://...).
    var remoteURL: String

    /// The authentication method for the remote.
    var authMethod: AuthMethod

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
        authMethod: AuthMethod = .https,
        branch: String = "main",
        graphName: String = "",
        commitMessageTemplate: String = "Auto-sync from {{device}} at {{timestamp}}",
        lastPull: Date? = nil,
        lastPush: Date? = nil
    ) {
        self.remoteURL = remoteURL
        self.authMethod = authMethod
        self.branch = branch
        self.graphName = graphName
        self.commitMessageTemplate = commitMessageTemplate
        self.lastPull = lastPull
        self.lastPush = lastPush
    }
}
