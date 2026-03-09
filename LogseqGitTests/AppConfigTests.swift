import XCTest
@testable import LogseqGit

final class AppConfigTests: XCTestCase {

    func testCodableRoundtripWithAllFields() throws {
        let bookmarkData = Data([0x01, 0x02, 0x03])
        let config = AppConfig(
            remoteURL: "https://github.com/user/repo.git",
            authMethod: .https,
            branch: "develop",
            graphName: "my-graph",
            commitMessageTemplate: "sync {{device}}",
            lastPull: Date(timeIntervalSince1970: 1_700_000_000),
            lastPush: Date(timeIntervalSince1970: 1_700_001_000),
            repoMode: .logseqFolder,
            repoFolderBookmarkData: bookmarkData,
            repoFolderDisplayName: "my-graph"
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
        XCTAssertNil(decoded.lastPull)
        XCTAssertNil(decoded.lastPush)
    }

    func testLegacySSHAuthMethodDecodesToHTTPS() throws {
        let json = """
        {
            "remoteURL": "git@github.com:user/repo.git",
            "authMethod": "ssh",
            "branch": "main",
            "graphName": "",
            "commitMessageTemplate": "sync"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(AppConfig.self, from: json)
        XCTAssertEqual(config.authMethod, .https)
    }

    func testInvalidAuthMethodThrows() {
        let json = """
        {
            "remoteURL": "https://github.com/user/repo.git",
            "authMethod": "bogus",
            "branch": "main",
            "graphName": "",
            "commitMessageTemplate": "sync"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(AppConfig.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testDefaultValues() {
        let config = AppConfig(remoteURL: "https://github.com/user/repo.git")
        XCTAssertEqual(config.authMethod, .https)
        XCTAssertEqual(config.branch, "main")
        XCTAssertEqual(config.graphName, "")
        XCTAssertEqual(config.commitMessageTemplate, "Auto-sync from {{device}} at {{timestamp}}")
        XCTAssertNil(config.lastPull)
        XCTAssertNil(config.lastPush)
        XCTAssertEqual(config.repoMode, .legacyProvider)
        XCTAssertNil(config.repoFolderBookmarkData)
        XCTAssertNil(config.repoFolderDisplayName)
    }

    func testLegacyConfigWithoutRepoFieldsDecodesWithDefaults() throws {
        let json = """
        {
            "remoteURL": "git@github.com:user/repo.git",
            "authMethod": "https",
            "branch": "main",
            "graphName": "",
            "commitMessageTemplate": "sync"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(AppConfig.self, from: json)
        XCTAssertEqual(config.repoMode, .legacyProvider)
        XCTAssertNil(config.repoFolderBookmarkData)
        XCTAssertNil(config.repoFolderDisplayName)
    }
}
