import XCTest
@testable import LogseqGit

final class SyncLoggerTests: XCTestCase {

    private var tempDir: URL!
    private var logger: SyncLogger!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let logURL = tempDir.appendingPathComponent("sync.log")
        logger = SyncLogger(logURL: logURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLogAndReadEntries() {
        logger.log(SyncLogEntry(action: "pull", message: "Pulled 3 files"))
        logger.log(SyncLogEntry(action: "push", message: "Pushed 1 file"))
        logger.log(SyncLogEntry(action: "commit", message: "Committed"))

        let entries = logger.getRecentEntries(limit: 10)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].action, "pull")
        XCTAssertEqual(entries[2].action, "commit")
    }

    func testGetRecentEntriesRespectsLimit() {
        for i in 0..<5 {
            logger.log(SyncLogEntry(action: "push", message: "Entry \(i)"))
        }
        let entries = logger.getRecentEntries(limit: 2)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].message, "Entry 3")
        XCTAssertEqual(entries[1].message, "Entry 4")
    }

    func testClearLogRemovesAllEntries() {
        logger.log(SyncLogEntry(action: "pull", message: "test"))
        logger.clearLog()
        let entries = logger.getRecentEntries(limit: 100)
        XCTAssertTrue(entries.isEmpty)
    }

    func testTrimsToMaxEntries() {
        for i in 0..<105 {
            logger.log(SyncLogEntry(action: "push", message: "Entry \(i)"))
        }
        let entries = logger.getRecentEntries(limit: 200)
        XCTAssertEqual(entries.count, 100)
        // Oldest entries should have been trimmed; first remaining is Entry 5
        XCTAssertEqual(entries.first?.message, "Entry 5")
    }

    func testGetRecentEntriesReturnsEmptyWhenNoFile() {
        let freshURL = tempDir.appendingPathComponent("nonexistent.log")
        let freshLogger = SyncLogger(logURL: freshURL)
        XCTAssertTrue(freshLogger.getRecentEntries().isEmpty)
    }
}
