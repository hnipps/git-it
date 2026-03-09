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

enum RepoMode: String, CaseIterable, Codable, Equatable {
    case legacyProvider
    case logseqFolder
}

/// Persisted application configuration that is shared between the main app and the File Provider extension.
struct AppConfig: Equatable {
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

    var repoMode: RepoMode
    var repoFolderBookmarkData: Data?
    var repoFolderDisplayName: String?

    // MARK: - Defaults

    init(
        remoteURL: String,
        authMethod: AuthMethod = .https,
        branch: String = "main",
        graphName: String = "",
        commitMessageTemplate: String = "Auto-sync from {{device}} at {{timestamp}}",
        lastPull: Date? = nil,
        lastPush: Date? = nil,
        repoMode: RepoMode = .legacyProvider,
        repoFolderBookmarkData: Data? = nil,
        repoFolderDisplayName: String? = nil
    ) {
        self.remoteURL = remoteURL
        self.authMethod = authMethod
        self.branch = branch
        self.graphName = graphName
        self.commitMessageTemplate = commitMessageTemplate
        self.lastPull = lastPull
        self.lastPush = lastPush
        self.repoMode = repoMode
        self.repoFolderBookmarkData = repoFolderBookmarkData
        self.repoFolderDisplayName = repoFolderDisplayName
    }
}

extension AppConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case remoteURL
        case authMethod
        case branch
        case graphName
        case commitMessageTemplate
        case lastPull
        case lastPush
        case repoMode
        case repoFolderBookmarkData
        case repoFolderDisplayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteURL = try container.decode(String.self, forKey: .remoteURL)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        graphName = try container.decodeIfPresent(String.self, forKey: .graphName) ?? ""
        commitMessageTemplate = try container.decodeIfPresent(String.self, forKey: .commitMessageTemplate)
            ?? "Auto-sync from {{device}} at {{timestamp}}"
        lastPull = try container.decodeIfPresent(Date.self, forKey: .lastPull)
        lastPush = try container.decodeIfPresent(Date.self, forKey: .lastPush)
        repoMode = try container.decodeIfPresent(RepoMode.self, forKey: .repoMode) ?? .legacyProvider
        repoFolderBookmarkData = try container.decodeIfPresent(Data.self, forKey: .repoFolderBookmarkData)
        repoFolderDisplayName = try container.decodeIfPresent(String.self, forKey: .repoFolderDisplayName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteURL, forKey: .remoteURL)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(branch, forKey: .branch)
        try container.encode(graphName, forKey: .graphName)
        try container.encode(commitMessageTemplate, forKey: .commitMessageTemplate)
        try container.encodeIfPresent(lastPull, forKey: .lastPull)
        try container.encodeIfPresent(lastPush, forKey: .lastPush)
        try container.encode(repoMode, forKey: .repoMode)
        try container.encodeIfPresent(repoFolderBookmarkData, forKey: .repoFolderBookmarkData)
        try container.encodeIfPresent(repoFolderDisplayName, forKey: .repoFolderDisplayName)
    }
}
