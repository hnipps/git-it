import Clibgit2
import Foundation
import SwiftGit2

// MARK: - Credential Context

struct GitCredentialContext {
    enum AuthType {
        case ssh(privateKey: String)
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
    guard let payload = payload else { return -1 }
    let ctx = payload.assumingMemoryBound(to: GitCredentialContext.self).pointee

    let result: Int32
    switch ctx.auth {
    case .ssh(let key):
        result = git_cred_ssh_key_memory_new(cred, "git", nil, key, "")
    case .plaintext(let user, let pass):
        result = git_cred_userpass_plaintext_new(cred, user, pass)
    case .none:
        result = git_cred_default_new(cred)
    }
    return (result != GIT_OK.rawValue) ? -1 : 0
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
        return NSError(
            domain: "com.logseqgit.git",
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(pointOfFailure) failed: \(message)"
            ]
        )
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
