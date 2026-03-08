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

    func testSyncPopulatesNestedDirectoryStructure() throws {
        // Create a realistic Logseq graph structure
        let pagesDir = repoDir.appendingPathComponent("pages")
        let journalsDir = repoDir.appendingPathComponent("journals")
        let logseqDir = repoDir.appendingPathComponent("logseq")

        for dir in [pagesDir, journalsDir, logseqDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let pageContent = "- Some page content"
        try pageContent.write(to: pagesDir.appendingPathComponent("ProjectA.md"), atomically: true, encoding: .utf8)
        try pageContent.write(to: pagesDir.appendingPathComponent("ProjectB.md"), atomically: true, encoding: .utf8)
        try "- journal entry".write(to: journalsDir.appendingPathComponent("2026_03_08.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: logseqDir.appendingPathComponent("config.edn"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir, excludedPaths: ["logseq/"])

        // Root should contain pages and journals
        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let rootFilenames = rootItems.map { $0.filename }
        XCTAssertTrue(rootFilenames.contains("pages"))
        XCTAssertTrue(rootFilenames.contains("journals"))

        // logseq/ directory entry itself is recorded (exclusion skips its contents)
        // but its children should be empty since all were excluded
        let logseqID = db.identifierForPath("logseq")
        let logseqChildren = db.enumerateItems(in: logseqID, startingAt: 0, limit: 100)
        XCTAssertTrue(logseqChildren.isEmpty, "logseq/ children should be excluded")

        // pages and journals should be directories
        for item in rootItems where item.filename == "pages" || item.filename == "journals" {
            XCTAssertEqual(item.contentType, .folder, "\(item.filename) should be a directory")
        }

        // Drill into pages/ — should contain both files
        let pagesID = db.identifierForPath("pages")
        let pageItems = db.enumerateItems(in: pagesID, startingAt: 0, limit: 100)
        let pageFilenames = pageItems.map { $0.filename }
        XCTAssertEqual(pageFilenames.sorted(), ["ProjectA.md", "ProjectB.md"])

        // Verify file metadata
        for item in pageItems {
            XCTAssertNotEqual(item.contentType, .folder, "\(item.filename) should not be a directory")
            XCTAssertNotNil(item.documentSize, "\(item.filename) should have a size")
            XCTAssertGreaterThan(item.documentSize!.intValue, 0)
        }
    }

    func testSyncThenResyncAfterNewFiles() throws {
        let pagesDir = repoDir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        try "# Original".write(to: pagesDir.appendingPathComponent("existing.md"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir)

        // Verify initial state
        let pagesID = db.identifierForPath("pages")
        let initialItems = db.enumerateItems(in: pagesID, startingAt: 0, limit: 100)
        XCTAssertEqual(initialItems.map { $0.filename }, ["existing.md"])

        // Simulate pull — add new files
        try "# New Page".write(to: pagesDir.appendingPathComponent("new_page.md"), atomically: true, encoding: .utf8)
        let journalsDir = repoDir.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journalsDir, withIntermediateDirectories: true)
        try "- entry".write(to: journalsDir.appendingPathComponent("2026_03_08.md"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir)

        // Old file should still be present
        let updatedPageItems = db.enumerateItems(in: pagesID, startingAt: 0, limit: 100)
        let updatedFilenames = updatedPageItems.map { $0.filename }
        XCTAssertTrue(updatedFilenames.contains("existing.md"))
        XCTAssertTrue(updatedFilenames.contains("new_page.md"))

        // New directory should appear at root
        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let rootFilenames = rootItems.map { $0.filename }
        XCTAssertTrue(rootFilenames.contains("journals"))
        XCTAssertTrue(rootFilenames.contains("pages"))
    }

    func testSyncWithRepoManagerExclusionPatterns() throws {
        // Create directories/files matching RepoManager.exclusionPatterns
        // Note: syncWithDisk uses .skipsHiddenFiles, so hidden entries (.git, .DS_Store,
        // .logseq, logseq/.recycle) are never even enumerated by FileManager.
        let dirs = ["pages", "logseq/bak", "logseq/.recycle", ".logseq", "node_modules"]
        for dir in dirs {
            let url = repoDir.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "data".write(to: url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }

        // Create .DS_Store at root and .git directory (hidden — skipped by enumerator)
        try "binary".write(to: repoDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let gitDir = repoDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Create a normal file in pages/
        try "# Page".write(to: repoDir.appendingPathComponent("pages").appendingPathComponent("real.md"), atomically: true, encoding: .utf8)

        db.syncWithDisk(repoURL: repoDir, excludedPaths: RepoManager.exclusionPatterns)

        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let rootFilenames = rootItems.map { $0.filename }

        // pages/ should be visible
        XCTAssertTrue(rootFilenames.contains("pages"), "pages/ should be visible")

        // Hidden entries are excluded by .skipsHiddenFiles (never reach exclusion logic)
        XCTAssertFalse(rootFilenames.contains(".git"), ".git/ should be skipped (hidden)")
        XCTAssertFalse(rootFilenames.contains(".DS_Store"), ".DS_Store should be skipped (hidden)")
        XCTAssertFalse(rootFilenames.contains(".logseq"), ".logseq/ should be skipped (hidden)")

        // node_modules/ directory entry itself is recorded, but its contents are excluded
        // (exclusion matches children like "node_modules/file.txt" via hasPrefix)
        let nodeModulesID = db.identifierForPath("node_modules")
        let nodeModulesItems = db.enumerateItems(in: nodeModulesID, startingAt: 0, limit: 100)
        XCTAssertTrue(nodeModulesItems.isEmpty, "node_modules/ children should be excluded")

        // logseq/bak/ contents should be excluded
        let logseqBakID = db.identifierForPath("logseq/bak")
        let bakItems = db.enumerateItems(in: logseqBakID, startingAt: 0, limit: 100)
        XCTAssertTrue(bakItems.isEmpty, "logseq/bak/ children should be excluded")

        // logseq/.recycle/ is hidden — skipped by enumerator, so no entry at all
        // Verify pages/real.md is accessible
        let pagesID = db.identifierForPath("pages")
        let pageItems = db.enumerateItems(in: pagesID, startingAt: 0, limit: 100)
        let pageFilenames = pageItems.map { $0.filename }
        XCTAssertTrue(pageFilenames.contains("real.md"), "pages/real.md should be visible")
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

        // Check that pages exists and vendor's children are excluded
        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let rootFilenames = rootItems.map { $0.filename }
        XCTAssertTrue(rootFilenames.contains("pages"))

        // vendor/ directory entry itself is recorded but its contents are excluded
        let vendorID = db.identifierForPath("vendor")
        let vendorItems = db.enumerateItems(in: vendorID, startingAt: 0, limit: 100)
        XCTAssertTrue(vendorItems.isEmpty, "vendor/ children should be excluded")
    }
}
