import XCTest
@testable import LogseqGit

final class ConfigServiceTests: XCTestCase {

    private var tempDir: URL!
    private var service: ConfigService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("config.json")
        service = ConfigService(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLoadRoundtrip() throws {
        let config = AppConfig(
            remoteURL: "git@github.com:user/repo.git",
            authMethod: .ssh,
            branch: "main",
            graphName: "repo"
        )
        try service.saveConfig(config)
        let loaded = service.loadConfig()
        XCTAssertEqual(loaded, config)
    }

    func testLoadConfigReturnsNilWhenNoFile() {
        XCTAssertNil(service.loadConfig())
    }

    func testIsSetupCompleteReturnsFalseWhenNoConfig() {
        XCTAssertFalse(service.isSetupComplete)
    }

    func testIsSetupCompleteReturnsFalseWhenEmptyRemoteURL() throws {
        let config = AppConfig(remoteURL: "", authMethod: .ssh)
        try service.saveConfig(config)
        XCTAssertFalse(service.isSetupComplete)
    }

    func testIsSetupCompleteReturnsTrueWhenConfigured() throws {
        let config = AppConfig(
            remoteURL: "git@github.com:user/repo.git",
            authMethod: .ssh
        )
        try service.saveConfig(config)
        XCTAssertTrue(service.isSetupComplete)
    }

    func testSaveCreatesParentDirectory() throws {
        let nested = tempDir
            .appendingPathComponent("a/b/c")
            .appendingPathComponent("config.json")
        let nestedService = ConfigService(fileURL: nested)
        let config = AppConfig(remoteURL: "https://example.com/repo.git", authMethod: .https)
        try nestedService.saveConfig(config)
        XCTAssertEqual(nestedService.loadConfig(), config)
    }
}
