import XCTest
import FileProvider
@testable import LogseqGit

final class MetadataDatabaseSyncTests: XCTestCase {

    private var tempDir: URL!
    private var repoDir: URL!
    private var db: MetadataDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        repoDir = tempDir.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        db = MetadataDatabase(databasePath: dbPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSyncWithDiskPopulatesDatabase() throws {
        // Create temp files
        let pagesDir = repoDir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try "# Test".write(to: pagesDir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)
        try "# Other".write(to: pagesDir.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir)

        // Verify items are in the database
        let items = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let filenames = items.map { $0.filename }
        XCTAssertTrue(filenames.contains("pages"))
    }

    func testSyncWithDiskMarksRemovedAsDeleted() throws {
        let pagesDir = repoDir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        let testFile = pagesDir.appendingPathComponent("test.md")
        try "# Test".write(to: testFile, atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir)

        // Delete the file from disk
        try FileManager.default.removeItem(at: testFile)

        // Re-sync
        db.syncWithDisk(repoURL: repoDir)

        // The file should be marked deleted (not enumerable)
        let pagesID = db.identifierForPath("pages")
        let items = db.enumerateItems(in: pagesID, startingAt: 0, limit: 100)
        let filenames = items.map { $0.filename }
        XCTAssertFalse(filenames.contains("test.md"))
    }

    func testSyncWithDiskRespectsExcludedPaths() throws {
        // Create .git/config (should be excluded) - note: syncWithDisk uses skipsHiddenFiles
        // so we create a non-hidden directory to test exclusion
        let gitDir = repoDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "data".write(to: gitDir.appendingPathComponent("lib.js"), atomically: true, encoding: .utf8)

        let pagesDir = repoDir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try "# Test".write(to: pagesDir.appendingPathComponent("test.md"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir, excludedPaths: ["vendor/"])

        // Check that pages exists but vendor does not
        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let rootFilenames = rootItems.map { $0.filename }
        XCTAssertTrue(rootFilenames.contains("pages"))
        XCTAssertFalse(rootFilenames.contains("vendor"))
    }
}
