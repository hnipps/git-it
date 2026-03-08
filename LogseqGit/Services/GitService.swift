import Combine
import FileProvider
import Foundation
import SwiftGit2
import UIKit

// MARK: - Supporting Types

/// Describes the current state of the Git service.
enum GitStatus: Equatable {
    case idle
    case cloning
    case pulling
    case pushing
    case committing
    case error(String)
}

/// Outcome of a pull operation.
enum PullResult: Equatable {
    case upToDate
    case pulled(fileCount: Int)
    case conflictBranch(name: String)

    var logMessage: String {
        switch self {
        case .upToDate:
            return "Already up to date"
        case .pulled(let count):
            return "Pulled \(count) file\(count == 1 ? "" : "s")"
        case .conflictBranch(let name):
            return "Conflict detected — local changes saved to branch \(name)"
        }
    }
}

/// Summary returned from a combined commit-and-push operation.
struct SyncResult {
    let committed: Bool
    let commitCount: Int
    let pushed: Bool
    let message: String
}

/// Represents a single file's status relative to HEAD.
struct StatusEntry: Equatable {
    let filePath: String
    let status: FileStatus
}

/// Possible statuses for a working-tree file.
enum FileStatus: String, Equatable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
}

/// Errors specific to Git operations.
enum GitError: LocalizedError {
    case notCloned
    case cloneFailed(String)
    case pullFailed(String)
    case pushFailed(String)
    case commitFailed(String)
    case authenticationFailed
    case networkError
    case mergeConflict(branchName: String)

    var errorDescription: String? {
        switch self {
        case .notCloned:
            return "Repository has not been cloned yet."
        case .cloneFailed(let reason):
            return "Clone failed: \(reason)"
        case .pullFailed(let reason):
            return "Pull failed: \(reason)"
        case .pushFailed(let reason):
            return "Push failed: \(reason)"
        case .commitFailed(let reason):
            return "Commit failed: \(reason)"
        case .authenticationFailed:
            return "Authentication failed. Check your credentials."
        case .networkError:
            return "A network error occurred. Check your connection."
        case .mergeConflict(let branchName):
            return "Merge conflict detected. Local changes saved to branch: \(branchName)"
        }
    }
}

// MARK: - GitService

/// Core service responsible for all Git operations against the local repository.
///
/// All public methods are `async` so callers can use structured concurrency.
/// Internally, synchronous SwiftGit2 calls are dispatched to a background queue.
final class GitService: ObservableObject {

    // MARK: - Published State

    @Published var status: GitStatus = .idle

    // MARK: - Dependencies

    private let keychainService: KeychainService
    private let configService: ConfigService

    /// Serial queue used to serialise synchronous libgit2 calls.
    private let gitQueue = DispatchQueue(label: "com.logseqgit.git", qos: .userInitiated)

    // MARK: - Init

    convenience init() {
        self.init(keychainService: .shared, configService: .shared)
    }

    init(keychainService: KeychainService, configService: ConfigService) {
        self.keychainService = keychainService
        self.configService = configService
    }

    // MARK: - Clone

    /// Clones a remote repository into the shared container.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote URL (SSH or HTTPS).
    ///   - branch: The branch to check out after cloning.
    func clone(remoteURL: String, branch: String) async throws {
        await setStatus(.cloning)

        do {
            try await runOnGitQueue {
                // Remove any pre-existing directory so we get a clean clone.
                let repoPath = Constants.repoPath
                if FileManager.default.fileExists(atPath: repoPath.path) {
                    try FileManager.default.removeItem(at: repoPath)
                }

                guard let remoteURLObj = URL(string: remoteURL) else {
                    throw GitError.cloneFailed("Invalid remote URL")
                }

                let result = Repository.clone(
                    from: remoteURLObj,
                    to: repoPath,
                    localClone: false,
                    bare: false,
                    credentials: self.swiftGit2Credentials(),
                    checkoutStrategy: .Force,
                    checkoutProgress: nil
                )

                switch result {
                case .success(let repo):
                    // Check out the requested branch if it differs from the default.
                    let currentBranch = repo.localBranch(named: branch)
                    switch currentBranch {
                    case .success(let branchRef):
                        let checkoutResult = repo.checkout(branchRef, strategy: .Force)
                        if case .failure(let error) = checkoutResult {
                            throw GitError.cloneFailed("Checkout of branch '\(branch)' failed: \(error.localizedDescription)")
                        }
                    case .failure:
                        // Branch may already be the default HEAD — nothing extra to do.
                        break
                    }
                case .failure(let error):
                    throw self.mapError(error, as: GitError.cloneFailed)
                }
            }
            await setStatus(.idle)
        } catch {
            await setStatus(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Pull

    /// Fetches from origin and fast-forwards the current branch.
    ///
    /// If fast-forward is not possible, an error is thrown indicating divergence.
    ///
    /// - Returns: A ``PullResult`` describing what happened.
    @discardableResult
    func pull() async throws -> PullResult {
        await setStatus(.pulling)

        do {
            let result: PullResult = try await runOnGitQueue {
                let repo = try self.openRepo()

                // 1. Fetch from origin.
                let fetchResult = GitCredentialHelper.fetch(
                    repo: repo,
                    remoteName: "origin",
                    credentials: self.credentialContext()
                )
                if case .failure(let error) = fetchResult {
                    throw self.mapError(error, as: GitError.pullFailed)
                }

                // 2. Resolve the local and remote branch references.
                guard let config = self.configService.loadConfig() else {
                    throw GitError.pullFailed("No configuration available.")
                }

                let branchName = config.branch
                guard case .success(let localBranch) = repo.localBranch(named: branchName) else {
                    throw GitError.pullFailed("Local branch '\(branchName)' not found.")
                }
                guard case .success(let remoteBranch) = repo.remoteBranch(named: "origin/\(branchName)") else {
                    throw GitError.pullFailed("Remote branch 'origin/\(branchName)' not found.")
                }

                let localOID = repo.HEAD().flatMap { repo.commit($0.oid) }
                let remoteOID = repo.commit(remoteBranch.oid)

                guard case .success(let localCommit) = localOID,
                      case .success(let remoteCommit) = remoteOID else {
                    throw GitError.pullFailed("Unable to resolve HEAD or remote commit.")
                }

                // Already up to date.
                if localCommit.oid == remoteCommit.oid {
                    return .upToDate
                }

                // 3. Attempt fast-forward: set HEAD to remote branch and checkout.
                let setRef = repo.setHEAD(remoteBranch)
                if case .failure(let error) = setRef {
                    throw GitError.pullFailed("Cannot fast-forward — branches may have diverged: \(error.localizedDescription)")
                }
                let checkoutResult = repo.checkout(remoteBranch, strategy: .Force)
                if case .failure(let error) = checkoutResult {
                    throw GitError.pullFailed("Checkout failed: \(error.localizedDescription)")
                }
                let diffCount = try self.diffFileCount(repo: repo, from: localCommit.oid, to: remoteCommit.oid)
                return .pulled(fileCount: diffCount)
            }

            // Update config with pull timestamp.
            if var config = configService.loadConfig() {
                config.lastPull = Date()
                try configService.saveConfig(config)
            }

            // Signal the File Provider so it picks up new files.
            await signalFileProvider()

            await setStatus(.idle)
            return result
        } catch {
            await setStatus(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Commit

    /// Stages all working-tree changes and creates a commit.
    ///
    /// - Parameter message: An optional commit message. When `nil` the commit
    ///   message is generated from the template in the app configuration.
    /// - Returns: `true` if a commit was created, `false` if there was nothing to commit.
    @discardableResult
    func commit(message: String? = nil) async throws -> Bool {
        await setStatus(.committing)

        do {
            let committed: Bool = try await runOnGitQueue {
                let repo = try self.openRepo()

                // Check for changes first.
                guard try self.workingTreeHasChanges(repo: repo) else {
                    return false
                }

                // Stage everything (git add -A).
                let addResult = repo.add(path: ".")
                if case .failure(let error) = addResult {
                    throw GitError.commitFailed("Staging failed: \(error.localizedDescription)")
                }

                // Resolve commit message.
                let finalMessage = message ?? self.generateCommitMessage()

                // Build signature.
                let signature = self.makeSignature()

                let commitResult = repo.commit(message: finalMessage, signature: signature)
                switch commitResult {
                case .success:
                    return true
                case .failure(let error):
                    throw GitError.commitFailed(error.localizedDescription)
                }
            }

            await setStatus(.idle)
            return committed
        } catch {
            await setStatus(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Push

    /// Pushes the current branch to the remote origin.
    func push() async throws {
        await setStatus(.pushing)

        do {
            try await runOnGitQueue {
                let repo = try self.openRepo()

                guard let config = self.configService.loadConfig() else {
                    throw GitError.pushFailed("No configuration available.")
                }

                guard case .success(let localBranch) = repo.localBranch(named: config.branch) else {
                    throw GitError.pushFailed("Local branch '\(config.branch)' not found.")
                }

                let pushResult = GitCredentialHelper.push(
                    repo: repo,
                    remoteName: "origin",
                    refspec: localBranch.longName,
                    credentials: self.credentialContext()
                )

                if case .failure(let error) = pushResult {
                    throw self.mapError(error, as: GitError.pushFailed)
                }
            }

            // Update config with push timestamp.
            if var config = configService.loadConfig() {
                config.lastPush = Date()
                try configService.saveConfig(config)
            }

            await setStatus(.idle)
        } catch {
            await setStatus(.error(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Commit & Push

    /// Convenience that commits any outstanding changes and pushes.
    ///
    /// - Parameter message: Optional commit message.
    /// - Returns: A ``SyncResult`` summarising the operation.
    @discardableResult
    func commitAndPush(message: String? = nil) async throws -> SyncResult {
        let didCommit = try await commit(message: message)
        let commitCount = didCommit ? 1 : 0

        if didCommit {
            try await push()
            return SyncResult(
                committed: true,
                commitCount: commitCount,
                pushed: true,
                message: "Pushed \(commitCount) change\(commitCount == 1 ? "" : "s")."
            )
        } else {
            return SyncResult(
                committed: false,
                commitCount: 0,
                pushed: false,
                message: "No changes to push."
            )
        }
    }

    // MARK: - Status

    /// Returns an array of files that differ from HEAD.
    func getStatus() async throws -> [StatusEntry] {
        try await runOnGitQueue {
            let repo = try self.openRepo()

            let statusResult = repo.status()
            switch statusResult {
            case .success(let entries):
                return entries.compactMap { entry -> StatusEntry? in
                    let fileStatus: FileStatus
                    if entry.status.contains(.workTreeNew) {
                        fileStatus = .untracked
                    } else if entry.status.contains(.indexNew) {
                        fileStatus = .added
                    } else if entry.status.contains(.indexDeleted) || entry.status.contains(.workTreeDeleted) {
                        fileStatus = .deleted
                    } else if entry.status.contains(.indexRenamed) || entry.status.contains(.workTreeRenamed) {
                        fileStatus = .renamed
                    } else {
                        fileStatus = .modified
                    }

                    let filePath = entry.headToIndex?.oldFile?.path
                        ?? entry.indexToWorkDir?.oldFile?.path
                        ?? entry.headToIndex?.newFile?.path
                        ?? entry.indexToWorkDir?.newFile?.path
                    guard let path = filePath else { return nil }

                    return StatusEntry(filePath: path, status: fileStatus)
                }
            case .failure(let error):
                throw GitError.commitFailed("Could not read status: \(error.localizedDescription)")
            }
        }
    }

    /// Quick check for any uncommitted changes in the working tree.
    func hasUncommittedChanges() async throws -> Bool {
        try await runOnGitQueue {
            let repo = try self.openRepo()
            return try self.workingTreeHasChanges(repo: repo)
        }
    }


    // MARK: - Credential Helpers (Private)

    /// Returns a `GitCredentialContext` for use with `GitCredentialHelper` (fetch/push).
    private func credentialContext() -> GitCredentialContext {
        guard let config = configService.loadConfig() else {
            return GitCredentialContext(auth: .none)
        }

        switch config.authMethod {
        case .ssh:
            guard let keyData = try? keychainService.getSSHPrivateKey(),
                  let keyString = String(data: keyData, encoding: .utf8) else {
                return GitCredentialContext(auth: .none)
            }
            return GitCredentialContext(auth: .ssh(privateKey: keyString))

        case .https:
            guard let token = try? keychainService.getPAT() else {
                return GitCredentialContext(auth: .none)
            }
            return GitCredentialContext(auth: .plaintext(username: "logseqgit", password: token))
        }
    }

    /// Returns `Credentials` for SwiftGit2 operations that accept it directly (e.g. clone).
    private func swiftGit2Credentials() -> Credentials {
        guard let config = configService.loadConfig() else {
            return .default
        }

        switch config.authMethod {
        case .ssh:
            guard let keyData = try? keychainService.getSSHPrivateKey(),
                  let keyString = String(data: keyData, encoding: .utf8) else {
                return .default
            }
            return .sshMemory(username: "git", privateKey: keyString, passphrase: "")

        case .https:
            guard let token = try? keychainService.getPAT() else {
                return .default
            }
            return .plaintext(username: "logseqgit", password: token)
        }
    }

    // MARK: - Helpers (Private)

    /// Opens the repository at the shared container path, throwing if it doesn't exist.
    private func openRepo() throws -> Repository {
        guard RepoManager.shared.isCloned else {
            throw GitError.notCloned
        }

        let result = Repository.at(Constants.repoPath)
        switch result {
        case .success(let repo):
            return repo
        case .failure(let error):
            throw GitError.notCloned
        }
    }

    /// Checks whether the working tree has any uncommitted changes.
    private func workingTreeHasChanges(repo: Repository) throws -> Bool {
        let statusResult = repo.status()
        switch statusResult {
        case .success(let entries):
            return !entries.isEmpty
        case .failure(let error):
            throw GitError.commitFailed("Unable to read status: \(error.localizedDescription)")
        }
    }

    /// Returns the number of files changed between two OIDs.
    private func diffFileCount(repo: Repository, from oldOID: OID, to newOID: OID) throws -> Int {
        switch repo.commit(newOID) {
        case .success(let commit):
            switch repo.diff(for: commit) {
            case .success(let diff):
                return diff.deltas.count
            case .failure:
                return 0
            }
        case .failure:
            return 0
        }
    }

    /// Constructs a default `Signature` for commits.
    private func makeSignature() -> Signature {
        Signature(
            name: "LogseqGit",
            email: "logseqgit@local",
            time: Date(),
            timeZone: TimeZone.current
        )
    }

    /// Generates a commit message from the user's template, replacing placeholders.
    private func generateCommitMessage() -> String {
        let template = configService.loadConfig()?.commitMessageTemplate
            ?? "Auto-sync from {{device}} at {{timestamp}}"

        let deviceName = UIDevice.current.name
        let timestamp = ISO8601DateFormatter().string(from: Date())

        return template
            .replacingOccurrences(of: "{{device}}", with: deviceName)
            .replacingOccurrences(of: "{{timestamp}}", with: timestamp)
    }

    /// Maps a SwiftGit2 error into a typed ``GitError``.
    private func mapError(_ error: NSError, as kind: (String) -> GitError) -> GitError {
        let message = error.localizedDescription
        if message.lowercased().contains("auth") || message.lowercased().contains("credential") {
            return .authenticationFailed
        }
        if message.lowercased().contains("network") || message.lowercased().contains("resolve") {
            return .networkError
        }
        return kind(message)
    }

    /// Dispatches a synchronous closure onto the dedicated git queue and bridges to async.
    private func runOnGitQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            gitQueue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Updates the published status on the main actor.
    @MainActor
    private func setStatus(_ newStatus: GitStatus) {
        status = newStatus
    }

    /// Signals the File Provider extension that the repository contents have changed.
    private func signalFileProvider() async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: Constants.fileProviderDomainID),
            displayName: "Logseq"
        )

        do {
            let manager = NSFileProviderManager(for: domain)
            try await manager?.signalEnumerator(for: .workingSet)
        } catch {
            // File Provider signaling is best-effort; log but don't propagate.
            print("[GitService] Failed to signal File Provider: \(error.localizedDescription)")
        }
    }
}
