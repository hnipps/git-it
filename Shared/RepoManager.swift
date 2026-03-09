import Foundation

final class RepoManager {
    static let shared = RepoManager()

    private let repoRootResolver: RepoRootResolving

    // MARK: - Exclusion Patterns

    /// File and directory patterns that should be excluded from sync operations.
    static let exclusionPatterns: [String] = [
        "logseq/bak/",
        "logseq/.recycle/",
        ".git/",
        ".DS_Store",
        ".Trash/",
        "node_modules/",
        ".logseq/",
    ]

    // MARK: - Properties

    var repoURL: URL {
        (try? repoRootResolver.resolveRepoRootURL()) ?? Constants.repoPath
    }

    var repoPath: String {
        repoURL.path
    }

    // MARK: - Init

    init(repoRootResolver: RepoRootResolving = RepoRootResolver.shared) {
        self.repoRootResolver = repoRootResolver
    }

    // MARK: - Repo State

    /// Returns `true` if the repository directory exists and contains a `.git` subdirectory.
    var isCloned: Bool {
        let gitDir = repoURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Path Exclusion

    /// Checks whether a relative path matches any of the exclusion patterns.
    ///
    /// - Parameter relativePath: A path relative to the repository root.
    /// - Returns: `true` if the path should be excluded from sync.
    func shouldExclude(relativePath: String) -> Bool {
        for pattern in Self.exclusionPatterns {
            if pattern.hasSuffix("/") {
                // Directory pattern — match if the path starts with the pattern
                // or contains it as a path component prefix.
                let dirName = String(pattern.dropLast())
                if relativePath.hasPrefix(pattern)
                    || relativePath.hasPrefix(dirName)
                    || relativePath.contains("/\(dirName)/")
                {
                    return true
                }
            } else {
                // File pattern — match the last path component.
                let fileName = (relativePath as NSString).lastPathComponent
                if fileName == pattern {
                    return true
                }
            }
        }
        return false
    }
}
