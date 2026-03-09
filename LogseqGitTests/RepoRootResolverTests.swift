import XCTest
@testable import LogseqGit

private final class MockBookmarkService: SecurityScopedBookmarkServicing {
    var resolvedURL: URL
    var shouldThrowOnResolve = false
    var validateCalled = false

    init(resolvedURL: URL) {
        self.resolvedURL = resolvedURL
    }

    func createBookmarkData(for folderURL: URL) throws -> Data {
        Data(folderURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        if shouldThrowOnResolve {
            throw BookmarkResolutionError.bookmarkResolutionFailed
        }
        return resolvedURL
    }

    func withScopedAccess<T>(to folderURL: URL, _ operation: () throws -> T) throws -> T {
        try operation()
    }

    func validateWritableDirectory(_ folderURL: URL) throws {
        validateCalled = true
    }
}

final class RepoRootResolverTests: XCTestCase {
    private var tempDir: URL!
    private var configService: ConfigService!
    private var bookmarkService: MockBookmarkService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configService = ConfigService(fileURL: tempDir.appendingPathComponent("config.json"))
        bookmarkService = MockBookmarkService(resolvedURL: tempDir.appendingPathComponent("selected", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testNoConfigDefaultsToLegacyPath() throws {
        let resolver = RepoRootResolver(configService: configService, bookmarkService: bookmarkService)
        XCTAssertEqual(try resolver.resolveRepoRootURL(), Constants.repoPath)
        XCTAssertEqual(resolver.resolveRepoMode(), .legacyProvider)
        XCTAssertTrue(resolver.shouldUseLegacyFileProviderStorage())
    }

    func testLegacyModeUsesLegacyPath() throws {
        try configService.saveConfig(AppConfig(remoteURL: "https://example.com/repo.git", repoMode: .legacyProvider))
        let resolver = RepoRootResolver(configService: configService, bookmarkService: bookmarkService)
        XCTAssertEqual(try resolver.resolveRepoRootURL(), Constants.repoPath)
        XCTAssertTrue(resolver.shouldUseLegacyFileProviderStorage())
    }

    func testLogseqFolderWithoutBookmarkThrows() throws {
        try configService.saveConfig(AppConfig(remoteURL: "https://example.com/repo.git", repoMode: .logseqFolder))
        let resolver = RepoRootResolver(configService: configService, bookmarkService: bookmarkService)

        XCTAssertThrowsError(try resolver.resolveRepoRootURL()) { error in
            XCTAssertEqual(error as? BookmarkResolutionError, .missingBookmark)
        }
    }

    func testLogseqFolderResolvesBookmarkURL() throws {
        try configService.saveConfig(
            AppConfig(
                remoteURL: "https://example.com/repo.git",
                repoMode: .logseqFolder,
                repoFolderBookmarkData: Data([0x01])
            )
        )
        let resolver = RepoRootResolver(configService: configService, bookmarkService: bookmarkService)

        XCTAssertEqual(try resolver.resolveRepoRootURL(), bookmarkService.resolvedURL)
        XCTAssertEqual(resolver.resolveRepoMode(), .logseqFolder)
        XCTAssertFalse(resolver.shouldUseLegacyFileProviderStorage())
        XCTAssertTrue(bookmarkService.validateCalled)
    }
}
