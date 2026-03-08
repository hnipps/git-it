import Clibgit2
import Foundation
import SwiftGit2

// MARK: - Credential Context

struct GitCredentialContext {
    enum AuthType {
        case plaintext(username: String, password: String)
        case none
    }

    var auth: AuthType
}

// MARK: - C-compatible credential callback

private func gitCredentialCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
    url: UnsafePointer<CChar>?,
    username: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    let urlStr = url.map { String(cString: $0) } ?? "nil"
    let userStr = username.map { String(cString: $0) } ?? "nil"
    print("[GitCredential] callback invoked — url: \(urlStr), username: \(userStr), allowedTypes: \(allowedTypes)")

    guard let payload = payload else {
        print("[GitCredential] ERROR: payload is nil")
        return -1
    }
    let ctx = payload.assumingMemoryBound(to: GitCredentialContext.self).pointee

    let result: Int32
    switch ctx.auth {
    case .plaintext(let user, let pass):
        print("[GitCredential] attempting plaintext auth (user: \(user))")
        result = git_cred_userpass_plaintext_new(cred, user, pass)
    case .none:
        print("[GitCredential] attempting default credentials")
        result = git_cred_default_new(cred)
    }

    let returnVal: Int32 = (result != GIT_OK.rawValue) ? -1 : 0
    print("[GitCredential] returning: \(returnVal)")
    return returnVal
}

// MARK: - GitCredentialHelper

enum GitCredentialHelper {

    private static func makeError(_ code: Int32, _ pointOfFailure: String) -> NSError {
        let message: String
        if let err = giterr_last() {
            message = String(cString: err.pointee.message)
        } else {
            message = "Unknown error"
        }
        print("[GitCredentialHelper] \(pointOfFailure) error (code \(code)): \(message)")
        return NSError(
            domain: "com.logseqgit.git",
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(pointOfFailure) failed: \(message)"
            ]
        )
    }

    /// Clones a remote repository with credential authentication.
    /// Uses git_clone directly to bypass SwiftGit2's credential callback which ignores allowedTypes.
    static func clone(from remoteURL: String, to localPath: URL, credentials: GitCredentialContext) -> Result<Repository, NSError> {
        git_libgit2_init()

        let pointer = UnsafeMutablePointer<git_clone_options>.allocate(capacity: 1)
        git_clone_init_options(pointer, UInt32(GIT_CLONE_OPTIONS_VERSION))
        var opts = pointer.move()
        pointer.deallocate()

        var ctx = credentials
        let result: Result<Repository, NSError> = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            opts.fetch_opts.callbacks.payload = UnsafeMutableRawPointer(ctxPtr)
            opts.fetch_opts.callbacks.credentials = gitCredentialCallback

            var repoPointer: OpaquePointer? = nil
            let cloneResult = localPath.withUnsafeFileSystemRepresentation { localCStr in
                git_clone(&repoPointer, remoteURL, localCStr, &opts)
            }

            guard cloneResult == GIT_OK.rawValue, let repoPointer = repoPointer else {
                return .failure(makeError(cloneResult, "git_clone"))
            }
            return .success(Repository(repoPointer))
        }
        return result
    }

    /// Fetches from the named remote with credential authentication.
    static func fetch(repo: Repository, remoteName: String, credentials: GitCredentialContext) -> Result<Void, NSError> {
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo.pointer, remoteName)
        guard lookupResult == GIT_OK.rawValue, let remote = remote else {
            return .failure(makeError(lookupResult, "git_remote_lookup"))
        }
        defer { git_remote_free(remote) }

        var opts = git_fetch_options()
        git_fetch_init_options(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))

        var ctx = credentials
        let result: Int32 = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            opts.callbacks.payload = UnsafeMutableRawPointer(ctxPtr)
            opts.callbacks.credentials = gitCredentialCallback
            return git_remote_fetch(remote, nil, &opts, nil)
        }

        guard result == GIT_OK.rawValue else {
            return .failure(makeError(result, "git_remote_fetch"))
        }
        return .success(())
    }

    /// Pushes the given refspec to the named remote with credential authentication.
    static func push(repo: Repository, remoteName: String, refspec: String, credentials: GitCredentialContext) -> Result<Void, NSError> {
        var remote: OpaquePointer?
        let lookupResult = git_remote_lookup(&remote, repo.pointer, remoteName)
        guard lookupResult == GIT_OK.rawValue, let remote = remote else {
            return .failure(makeError(lookupResult, "git_remote_lookup"))
        }
        defer { git_remote_free(remote) }

        var opts = git_push_options()
        git_push_init_options(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))

        var ctx = credentials
        let result: Int32 = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            opts.callbacks.payload = UnsafeMutableRawPointer(ctxPtr)
            opts.callbacks.credentials = gitCredentialCallback
            let refspecCopy = strdup(refspec)
            var refspecPtr: UnsafeMutablePointer<CChar>? = refspecCopy
            var refspecs = git_strarray(strings: &refspecPtr, count: 1)
            let pushResult = git_remote_push(remote, &refspecs, &opts)
            free(refspecCopy)
            return pushResult
        }

        guard result == GIT_OK.rawValue else {
            return .failure(makeError(result, "git_remote_push"))
        }
        return .success(())
    }
}
