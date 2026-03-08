import XCTest
import FileProvider
@testable import LogseqGit

final class MetadataDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var db: MetadataDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        db = MetadataDatabase(databasePath: dbPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - identifierForPath

    func testIdentifierForPathReturnsRootForEmpty() {
        let id = db.identifierForPath("")
        XCTAssertEqual(id, .rootContainer)
    }

    func testIdentifierForPathReturnsPersistentID() {
        let id1 = db.identifierForPath("pages/test.md")
        let id2 = db.identifierForPath("pages/test.md")
        XCTAssertEqual(id1, id2)
    }

    func testIdentifierForPathCreatesParents() {
        let childID = db.identifierForPath("a/b/c.md")
        XCTAssertNotEqual(childID, .rootContainer)

        // Parent "a/b" should exist
        let parentID = db.identifierForPath("a/b")
        XCTAssertNotEqual(parentID, .rootContainer)

        // Grandparent "a" should exist
        let grandparentID = db.identifierForPath("a")
        XCTAssertNotEqual(grandparentID, .rootContainer)
    }

    // MARK: - upsert and getItem

    func testUpsertAndGetItem() {
        let now = Date()
        db.upsertItem(
            relativePath: "pages/test.md",
            isDirectory: false,
            size: 1024,
            modDate: now,
            creationDate: now
        )

        let id = db.identifierForPath("pages/test.md")
        let item = db.getItem(for: id)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.filename, "test.md")
    }

    func testUpsertExistingUpdatesSize() {
        db.upsertItem(relativePath: "file.md", isDirectory: false, size: 100, modDate: nil, creationDate: nil)
        db.upsertItem(relativePath: "file.md", isDirectory: false, size: 200, modDate: nil, creationDate: nil)

        let id = db.identifierForPath("file.md")
        let item = db.getItem(for: id)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.documentSize, NSNumber(value: 200))
    }

    func testUpsertExistingIncrementsVersion() {
        db.upsertItem(relativePath: "file.md", isDirectory: false, size: 100, modDate: nil, creationDate: nil)
        let id = db.identifierForPath("file.md")
        let versionBefore = db.getItem(for: id)?.itemVersion
        XCTAssertNotNil(versionBefore)

        db.upsertItem(relativePath: "file.md", isDirectory: false, size: 200, modDate: nil, creationDate: nil)
        let versionAfter = db.getItem(for: id)?.itemVersion
        XCTAssertNotNil(versionAfter)
        XCTAssertNotEqual(versionBefore, versionAfter)
    }

    // MARK: - markDeleted

    func testMarkDeletedHidesFromEnumeration() {
        db.upsertItem(relativePath: "doomed.md", isDirectory: false, size: 50, modDate: nil, creationDate: nil)
        db.markDeleted(relativePath: "doomed.md")

        let items = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        let filenames = items.map { $0.filename }
        XCTAssertFalse(filenames.contains("doomed.md"))
    }

    // MARK: - enumerateItems

    func testEnumerateItemsReturnsChildren() {
        db.upsertItem(relativePath: "a.md", isDirectory: false, size: 10, modDate: nil, creationDate: nil)
        db.upsertItem(relativePath: "b.md", isDirectory: false, size: 20, modDate: nil, creationDate: nil)
        db.upsertItem(relativePath: "sub/c.md", isDirectory: false, size: 30, modDate: nil, creationDate: nil)

        let rootItems = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 100)
        // Root should have: a.md, b.md, and the "sub" directory
        let rootFilenames = rootItems.map { $0.filename }
        XCTAssertTrue(rootFilenames.contains("a.md"))
        XCTAssertTrue(rootFilenames.contains("b.md"))
        XCTAssertTrue(rootFilenames.contains("sub"))
    }

    func testEnumerateItemsPagination() {
        for i in 0..<5 {
            db.upsertItem(relativePath: "file\(i).md", isDirectory: false, size: Int64(i * 10), modDate: nil, creationDate: nil)
        }

        let page1 = db.enumerateItems(in: .rootContainer, startingAt: 0, limit: 2)
        let page2 = db.enumerateItems(in: .rootContainer, startingAt: 2, limit: 2)
        let page3 = db.enumerateItems(in: .rootContainer, startingAt: 4, limit: 2)

        XCTAssertEqual(page1.count, 2)
        XCTAssertEqual(page2.count, 2)
        XCTAssertEqual(page3.count, 1)
    }

    // MARK: - getChangesSince

    func testGetChangesSinceReturnsUpdated() {
        let anchor = db.currentAnchor
        db.incrementAnchor()
        db.upsertItem(relativePath: "new.md", isDirectory: false, size: 100, modDate: nil, creationDate: nil)

        let changes = db.getChangesSince(anchor: anchor)
        let filenames = changes.updated.map { $0.filename }
        XCTAssertTrue(filenames.contains("new.md"))
    }

    func testGetChangesSinceReturnsDeleted() {
        db.upsertItem(relativePath: "old.md", isDirectory: false, size: 100, modDate: nil, creationDate: nil)
        let anchor = db.currentAnchor
        db.incrementAnchor()
        db.markDeleted(relativePath: "old.md")

        let changes = db.getChangesSince(anchor: anchor)
        XCTAssertFalse(changes.deletedIdentifiers.isEmpty)
    }

    // MARK: - Path normalization

    func testPathNormalization() {
        let id1 = db.identifierForPath("/pages/test.md")
        let id2 = db.identifierForPath("pages/test.md/")
        let id3 = db.identifierForPath("pages/test.md")
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id2, id3)

        let rootID = db.identifierForPath(".")
        XCTAssertEqual(rootID, .rootContainer)
    }

    // MARK: - Anchors

    func testIncrementAnchor() {
        let old = db.currentAnchor
        let new = db.incrementAnchor()
        XCTAssertGreaterThan(new, old)
    }
}
