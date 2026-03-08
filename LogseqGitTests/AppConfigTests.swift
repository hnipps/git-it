import XCTest
@testable import LogseqGit

final class AppConfigTests: XCTestCase {

    func testCodableRoundtripWithAllFields() throws {
        let config = AppConfig(
            remoteURL: "git@github.com:user/repo.git",
            authMethod: .ssh,
            sshKeyRef: "key-ref-123",
            branch: "develop",
            graphName: "my-graph",
            commitMessageTemplate: "sync {{device}}",
            lastPull: Date(timeIntervalSince1970: 1_700_000_000),
            lastPush: Date(timeIntervalSince1970: 1_700_001_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(config)
        let decoded = try decoder.decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testCodableRoundtripWithNilOptionals() throws {
        let config = AppConfig(
            remoteURL: "https://github.com/user/repo.git",
            authMethod: .https,
            sshKeyRef: nil,
            lastPull: nil,
            lastPush: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(config)
        let decoded = try decoder.decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertNil(decoded.sshKeyRef)
        XCTAssertNil(decoded.lastPull)
        XCTAssertNil(decoded.lastPush)
    }

    func testDefaultValues() {
        let config = AppConfig(remoteURL: "git@host:user/repo.git", authMethod: .ssh)
        XCTAssertEqual(config.branch, "main")
        XCTAssertEqual(config.graphName, "")
        XCTAssertEqual(config.commitMessageTemplate, "Auto-sync from {{device}} at {{timestamp}}")
        XCTAssertNil(config.lastPull)
        XCTAssertNil(config.lastPush)
        XCTAssertNil(config.sshKeyRef)
    }
}
