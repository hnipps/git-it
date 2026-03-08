import XCTest
@testable import LogseqGit

final class SetupFlowViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var configService: ConfigService!
    private var vm: SetupFlowViewModel!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configService = ConfigService(fileURL: tempDir.appendingPathComponent("config.json"))
        vm = SetupFlowViewModel(configService: configService)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDeriveGraphNameFromSSHURL() {
        let name = vm.deriveGraphName(from: "git@github.com:user/repo.git")
        XCTAssertEqual(name, "repo")
    }

    func testDeriveGraphNameFromHTTPSURL() {
        let name = vm.deriveGraphName(from: "https://github.com/user/repo.git")
        XCTAssertEqual(name, "repo")
    }

    func testDeriveGraphNameWithoutGitSuffix() {
        let name = vm.deriveGraphName(from: "https://github.com/user/repo")
        XCTAssertEqual(name, "repo")
    }

    func testUpdateGraphNameIfNeededSetsWhenEmpty() {
        vm.remoteURL = "git@github.com:user/my-notes.git"
        vm.graphName = ""
        vm.updateGraphNameIfNeeded()
        XCTAssertEqual(vm.graphName, "my-notes")
    }

    func testUpdateGraphNameIfNeededDoesNotOverrideManual() {
        vm.remoteURL = "git@github.com:user/repo.git"
        vm.graphName = "My Custom Name"
        vm.updateGraphNameIfNeeded()
        XCTAssertEqual(vm.graphName, "My Custom Name")
    }

    func testAdvanceToAuthSetsStepAndDerivesName() {
        vm.remoteURL = "git@github.com:user/logseq-notes.git"
        vm.graphName = ""
        vm.advanceToAuth()
        XCTAssertEqual(vm.currentStep, .auth)
        XCTAssertEqual(vm.graphName, "logseq-notes")
    }

    func testNavigationFlow() {
        XCTAssertEqual(vm.currentStep, .remote)
        vm.advanceToAuth()
        XCTAssertEqual(vm.currentStep, .auth)
        vm.advanceToClone()
        XCTAssertEqual(vm.currentStep, .clone)
        vm.advanceToInstructions()
        XCTAssertEqual(vm.currentStep, .instructions)
    }

    func testInitialStepIsRemote() {
        let freshVM = SetupFlowViewModel(configService: configService)
        XCTAssertEqual(freshVM.currentStep, .remote)
    }
}
