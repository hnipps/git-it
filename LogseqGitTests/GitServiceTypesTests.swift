import XCTest
@testable import LogseqGit

final class GitServiceTypesTests: XCTestCase {

    // MARK: - PullResult

    func testPullResultUpToDateMessage() {
        let result = PullResult.upToDate
        XCTAssertEqual(result.logMessage, "Already up to date")
    }

    func testPullResultSingularFile() {
        let result = PullResult.pulled(fileCount: 1)
        XCTAssertEqual(result.logMessage, "Pulled 1 file")
    }

    func testPullResultPluralFiles() {
        let result = PullResult.pulled(fileCount: 5)
        XCTAssertEqual(result.logMessage, "Pulled 5 files")
    }

    func testPullResultConflictBranch() {
        let result = PullResult.conflictBranch(name: "CONFLICT-2024-01-01")
        XCTAssertEqual(result.logMessage, "Conflict detected — local changes saved to branch CONFLICT-2024-01-01")
    }

    // MARK: - GitError

    func testGitErrorNotCloned() throws {
        let desc = try XCTUnwrap(GitError.notCloned.errorDescription)
        XCTAssertEqual(desc, "Repository has not been cloned yet.")
    }

    func testGitErrorCloneFailed() throws {
        let desc = try XCTUnwrap(GitError.cloneFailed("timeout").errorDescription)
        XCTAssertEqual(desc, "Clone failed: timeout")
    }

    func testGitErrorAuthenticationFailed() throws {
        let desc = try XCTUnwrap(GitError.authenticationFailed.errorDescription)
        XCTAssertEqual(desc, "Authentication failed. Check your credentials.")
    }
}
