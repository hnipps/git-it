import XCTest
@testable import LogseqGit

final class SetupFlowIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var configService: ConfigService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configService = ConfigService(fileURL: tempDir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testFullSetupFlow() throws {
        let vm = SetupFlowViewModel(configService: configService)

        // Step 1: Set remote URL
        vm.remoteURL = "git@github.com:user/my-notes.git"
        vm.branch = "main"

        // Step 2: Advance to auth (should derive graph name)
        vm.advanceToAuth()
        XCTAssertEqual(vm.currentStep, .auth)
        XCTAssertEqual(vm.graphName, "my-notes")

        // Step 3: Set auth method
        vm.authMethod = .https

        // Step 4: Advance through remaining steps
        vm.advanceToClone()
        XCTAssertEqual(vm.currentStep, .clone)

        vm.advanceToInstructions()
        XCTAssertEqual(vm.currentStep, .instructions)

        // Step 5: Save config directly (synchronous version for testing)
        let config = AppConfig(
            remoteURL: vm.remoteURL,
            authMethod: vm.authMethod,
            branch: vm.branch,
            graphName: vm.graphName
        )
        try configService.saveConfig(config)

        // Verify config persisted with correct values
        let loaded = configService.loadConfig()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.remoteURL, "git@github.com:user/my-notes.git")
        XCTAssertEqual(loaded?.authMethod, .https)
        XCTAssertEqual(loaded?.branch, "main")
        XCTAssertEqual(loaded?.graphName, "my-notes")
        XCTAssertTrue(configService.isSetupComplete)
    }
}
