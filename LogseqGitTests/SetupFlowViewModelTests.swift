import XCTest
@testable import LogseqGit

final class SetupFlowViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var configService: ConfigService!
    private var vm: SetupFlowViewModel!
    private var bookmarkService: SetupBookmarkServiceMock!
    private var folderValidator: SetupFolderValidatorMock!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configService = ConfigService(fileURL: tempDir.appendingPathComponent("config.json"))
        bookmarkService = SetupBookmarkServiceMock()
        folderValidator = SetupFolderValidatorMock()
        vm = SetupFlowViewModel(
            configService: configService,
            bookmarkService: bookmarkService,
            folderValidator: folderValidator
        )
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
        vm.advanceToFolder()
        XCTAssertEqual(vm.currentStep, .folder)
        vm.selectGraphFolder(URL(fileURLWithPath: "/private/var/mobile/Logseq/my-graph"))
        vm.advanceToClone()
        XCTAssertEqual(vm.currentStep, .clone)
        vm.advanceToInstructions()
        XCTAssertEqual(vm.currentStep, .instructions)
    }

    func testInitialStepIsRemote() {
        let freshVM = SetupFlowViewModel(
            configService: configService,
            bookmarkService: bookmarkService,
            folderValidator: folderValidator
        )
        XCTAssertEqual(freshVM.currentStep, .remote)
    }

    func testAdvanceToCloneRequiresFolder() {
        vm.advanceToClone()
        XCTAssertEqual(vm.currentStep, .remote)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testSelectGraphFolderSetsDisplayName() {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Logseq/my-graph")
        vm.selectGraphFolder(folder)

        XCTAssertEqual(vm.selectedGraphFolderURL, folder)
        XCTAssertEqual(vm.selectedGraphFolderDisplayName, "my-graph")
        XCTAssertNil(vm.errorMessage)
    }

    func testSelectGraphFolderWithValidationErrorSetsError() {
        folderValidator.shouldThrow = true
        let folder = URL(fileURLWithPath: "/private/var/mobile/Documents/not-logseq")
        vm.selectGraphFolder(folder)

        XCTAssertNil(vm.selectedGraphFolderURL)
        XCTAssertFalse(vm.errorMessage?.isEmpty ?? true)
    }

    func testSaveConfigPersistsLogseqFolderModeAndBookmark() async throws {
        vm.remoteURL = "https://github.com/user/repo.git"
        vm.branch = "main"
        vm.graphName = "repo"
        vm.selectGraphFolder(URL(fileURLWithPath: "/private/var/mobile/Logseq/repo"))

        try await vm.saveConfig()

        let config = try XCTUnwrap(configService.loadConfig())
        XCTAssertEqual(config.repoMode, .logseqFolder)
        XCTAssertEqual(config.repoFolderDisplayName, "repo")
        XCTAssertEqual(config.repoFolderBookmarkData, Data("bookmark".utf8))
    }
}

private final class SetupBookmarkServiceMock: SecurityScopedBookmarkServicing {
    func createBookmarkData(for folderURL: URL) throws -> Data {
        Data("bookmark".utf8)
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        URL(fileURLWithPath: "/private/var/mobile/Logseq/repo")
    }

    func withScopedAccess<T>(to folderURL: URL, _ operation: () throws -> T) throws -> T {
        try operation()
    }

    func validateWritableDirectory(_ folderURL: URL) throws {}
}

private final class SetupFolderValidatorMock: LogseqFolderValidating {
    var shouldThrow = false

    func validate(_ folderURL: URL) throws {
        if shouldThrow {
            throw LogseqFolderValidationError.outsideLogseqDirectory
        }
    }
}
