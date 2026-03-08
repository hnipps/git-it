import XCTest
@testable import LogseqGit

final class ConfigSyncLoggerIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveConfigAndLogActivity() throws {
        let configService = ConfigService(fileURL: tempDir.appendingPathComponent("config.json"))
        let logger = SyncLogger(logURL: tempDir.appendingPathComponent("sync.log"))

        // Save config
        let config = AppConfig(
            remoteURL: "git@github.com:user/repo.git",
            authMethod: .ssh,
            branch: "main",
            graphName: "repo"
        )
        try configService.saveConfig(config)

        // Log an entry
        logger.log(SyncLogEntry(action: "pull", message: "Pulled 3 files"))

        // Verify both coexist and read back correctly
        let loadedConfig = configService.loadConfig()
        XCTAssertEqual(loadedConfig, config)

        let entries = logger.getRecentEntries(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.action, "pull")
    }
}
