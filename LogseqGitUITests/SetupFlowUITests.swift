import XCTest

final class SetupFlowUITests: XCTestCase {

    private var app: XCUIApplication!
    private var repoURL: String!
    private var pat: String!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Read credentials from a JSON config file bundled in the test target.
        // Generate this file before running tests:
        //   echo '{"repoURL":"...","pat":"..."}' > LogseqGitUITests/UITestConfig.json
        let bundle = Bundle(for: type(of: self))
        if let configURL = bundle.url(forResource: "UITestConfig", withExtension: "json"),
           let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            repoURL = json["repoURL"]
            pat = json["pat"]
        }

        // Fall back to environment variables (works on simulator or when forwarded).
        if repoURL == nil {
            repoURL = ProcessInfo.processInfo.environment["UITEST_REPO_URL"]
        }
        if pat == nil {
            pat = ProcessInfo.processInfo.environment["UITEST_PAT"]
        }

        app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Runs the full setup flow (remote config → auth → clone → instructions → MainView).
    /// Returns after MainView is confirmed visible.
    private func runSetupFlowToMainView() throws {
        let repoURL = try XCTUnwrap(repoURL, "Set UITEST_REPO_URL or provide LogseqGitUITests/UITestConfig.json")
        let pat = try XCTUnwrap(pat, "Set UITEST_PAT or provide LogseqGitUITests/UITestConfig.json")

        // Step 1: Remote config — enter repo URL and tap Next
        let remoteURLField = app.textFields[AccessibilityID.remoteURLField]
        XCTAssertTrue(remoteURLField.waitForExistence(timeout: 10))
        remoteURLField.tap()
        remoteURLField.typeText(repoURL)

        let remoteNextButton = app.buttons[AccessibilityID.remoteNextButton]
        XCTAssertTrue(remoteNextButton.isEnabled)
        remoteNextButton.tap()

        // Step 2: Auth config — enter PAT and tap Next
        let patField = app.secureTextFields[AccessibilityID.patField]
        XCTAssertTrue(patField.waitForExistence(timeout: 5))
        patField.tap()
        patField.typeText(pat)

        let authNextButton = app.buttons[AccessibilityID.authNextButton]
        XCTAssertTrue(authNextButton.isEnabled)
        authNextButton.tap()

        let useLegacyFolderButton = app.buttons[AccessibilityID.folderUseLegacyButton]
        XCTAssertTrue(useLegacyFolderButton.waitForExistence(timeout: 5))
        useLegacyFolderButton.tap()

        let folderNextButton = app.buttons[AccessibilityID.folderContinueButton]
        XCTAssertTrue(folderNextButton.isEnabled)
        folderNextButton.tap()

        // Step 3: Wait for clone to complete — the Instructions "Done" button appears
        let doneButton = app.buttons[AccessibilityID.instructionsDoneButton]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 120))

        // Step 4: Tap Done to finish setup
        doneButton.tap()

        // Step 5: Assert MainView is visible via Pull button accessibility ID
        let pullButton = app.buttons[AccessibilityID.pullButton]
        XCTAssertTrue(pullButton.waitForExistence(timeout: 10), "MainView should be showing after setup")
    }

    // MARK: - Tests

    func testFullSetupFlow() throws {
        try runSetupFlowToMainView()

        // --- A) Config assertions ---
        let graphName = app.staticTexts[AccessibilityID.graphNameLabel]
        XCTAssertTrue(graphName.waitForExistence(timeout: 5), "Graph name label should exist")
        let graphValue = graphName.label
        XCTAssertTrue(graphValue.contains("logseq-uitest"),
                      "Graph name should contain 'logseq-uitest', got: \(graphValue)")

        let branchLabel = app.staticTexts[AccessibilityID.branchLabel]
        XCTAssertTrue(branchLabel.exists, "Branch label should exist")
        XCTAssertTrue(branchLabel.label.contains("main"),
                      "Branch should contain 'main', got: \(branchLabel.label)")

        let remoteLabel = app.staticTexts[AccessibilityID.remoteURLLabel]
        XCTAssertTrue(remoteLabel.exists, "Remote URL label should exist")
        XCTAssertTrue(remoteLabel.label.contains("logseq-uitest"),
                      "Remote URL should contain 'logseq-uitest', got: \(remoteLabel.label)")

        // --- B) Status assertion ---
        let statusText = app.staticTexts[AccessibilityID.statusText]
        XCTAssertTrue(statusText.waitForExistence(timeout: 10), "Status text should exist")
        XCTAssertEqual(statusText.label, "Up to date",
                       "Status should be 'Up to date' after successful clone, got: \(statusText.label)")

        // --- C) Pull operation assertion ---
        let pullButton = app.buttons[AccessibilityID.pullButton]
        XCTAssertTrue(pullButton.exists && pullButton.isEnabled, "Pull button should be enabled")
        pullButton.tap()

        // After pull completes, "Last pull" row is added to the Status section which
        // can push the sync buttons off-screen in a lazy List. Wait for the pull to
        // finish by observing the status text, then scroll down to verify the button.
        let statusStillUpToDate = statusText.waitFor(\.label, toEqual: "Up to date", timeout: 30)
        XCTAssertTrue(statusStillUpToDate,
                      "Status should remain 'Up to date' after pull, got: \(statusText.label)")

        // No error alert should have appeared
        let errorAlert = app.alerts["Error"]
        XCTAssertFalse(errorAlert.exists, "No error alert should appear after pull")

        // Scroll down to make the pull button visible again (it may have moved
        // off-screen after the "Last pull" row appeared).
        let list = app.collectionViews.firstMatch
        if list.exists { list.swipeUp() }

        XCTAssertTrue(pullButton.waitForExistence(timeout: 5), "Pull button should still exist")
        XCTAssertTrue(pullButton.isEnabled, "Pull button should re-enable after pull completes")
    }

    func testClonedFilesAvailableInFilesApp() throws {
        try runSetupFlowToMainView()

        // Go to home screen
        XCUIDevice.shared.press(.home)

        // Launch the Files app
        let filesApp = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        filesApp.launch()

        // Navigate to the Browse tab
        let browseTab = filesApp.tabBars.buttons["Browse"]
        if browseTab.waitForExistence(timeout: 5) {
            browseTab.tap()
        }

        // Look for the FileProvider location in the sidebar.
        // The system uses the app's display name ("LogseqGit") rather than the
        // domain displayName we pass to NSFileProviderDomain.
        let logseqLocation = filesApp.cells["DOC.sidebar.item.LogseqGit"]
        XCTAssertTrue(logseqLocation.waitForExistence(timeout: 15),
                      "LogseqGit location should appear in Files app under Locations")

        // Tap into the LogseqGit location
        logseqLocation.tap()

        // Verify at least one item (file or folder) is listed
        let firstCell = filesApp.cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10),
                      "At least one file or folder should be listed in the Logseq location")
    }
}

// MARK: - XCUIElement Helpers

extension XCUIElement {
    /// Polls a key path on the element until it matches the expected value or the timeout expires.
    func waitFor<T: Equatable>(_ keyPath: KeyPath<XCUIElement, T>, toEqual expected: T, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self[keyPath: keyPath] == expected {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return self[keyPath: keyPath] == expected
    }
}
