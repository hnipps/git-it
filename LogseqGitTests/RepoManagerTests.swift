import XCTest
@testable import LogseqGit

final class RepoManagerTests: XCTestCase {
    private let manager = RepoManager(repoRootResolver: RepoManagerResolverMock())

    func testExcludesGitDirectory() {
        XCTAssertTrue(manager.shouldExclude(relativePath: ".git/HEAD"))
    }

    func testExcludesDSStore() {
        XCTAssertTrue(manager.shouldExclude(relativePath: ".DS_Store"))
        XCTAssertTrue(manager.shouldExclude(relativePath: "subdir/.DS_Store"))
    }

    func testExcludesLogseqBakDirectory() {
        XCTAssertTrue(manager.shouldExclude(relativePath: "logseq/bak/old.md"))
    }

    func testExcludesNodeModules() {
        XCTAssertTrue(manager.shouldExclude(relativePath: "node_modules/pkg/index.js"))
    }

    func testExcludesDotLogseq() {
        XCTAssertTrue(manager.shouldExclude(relativePath: ".logseq/graphs.edn"))
    }

    func testDoesNotExcludeNormalFile() {
        XCTAssertFalse(manager.shouldExclude(relativePath: "pages/mypage.md"))
    }

    func testDoesNotExcludeJournalFile() {
        XCTAssertFalse(manager.shouldExclude(relativePath: "journals/2024-01-01.md"))
    }
}

private struct RepoManagerResolverMock: RepoRootResolving {
    func resolveRepoRootURL() throws -> URL { Constants.repoPath }
    func resolveRepoMode() -> RepoMode { .legacyProvider }
    func shouldUseLegacyFileProviderStorage() -> Bool { true }
}
