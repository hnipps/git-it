import XCTest
@testable import LogseqGit

final class SecurityScopedBookmarkServiceTests: XCTestCase {
    private var tempDir: URL!
    private var folderURL: URL!
    private var service: SecurityScopedBookmarkService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        folderURL = tempDir.appendingPathComponent("graph", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        service = SecurityScopedBookmarkService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testBookmarkRoundTripResolvesFolderURL() throws {
        let data = try service.createBookmarkData(for: folderURL)
        let resolved = try service.resolveBookmark(data)
        XCTAssertEqual(resolved.lastPathComponent, folderURL.lastPathComponent)
    }

    func testValidateWritableDirectoryPassesForWritableFolder() throws {
        XCTAssertNoThrow(try service.validateWritableDirectory(folderURL))
    }

    func testWithScopedAccessThrowsForOutsideSandboxURLWithoutScope() {
        let externalURL = URL(fileURLWithPath: "/var/logseqgit-external")
        XCTAssertThrowsError(try service.withScopedAccess(to: externalURL) {}) { error in
            XCTAssertEqual(error as? BookmarkResolutionError, .cannotAccessSecurityScope)
        }
    }

    func testCreateBookmarkDataThrowsForOutsideSandboxURLWithoutScope() {
        let externalURL = URL(fileURLWithPath: "/var/logseqgit-external")
        XCTAssertThrowsError(try service.createBookmarkData(for: externalURL)) { error in
            XCTAssertEqual(error as? BookmarkResolutionError, .cannotAccessSecurityScope)
        }
    }

    func testValidateWritableDirectoryThrowsForFileURL() throws {
        let fileURL = tempDir.appendingPathComponent("note.md")
        try Data("hello".utf8).write(to: fileURL)
        XCTAssertThrowsError(try service.validateWritableDirectory(fileURL)) { error in
            XCTAssertEqual(error as? BookmarkResolutionError, .notDirectory)
        }
    }
}
