import XCTest
@testable import LogseqGit

private final class ValidatorBookmarkServiceMock: SecurityScopedBookmarkServicing {
    var validationError: Error?

    func createBookmarkData(for folderURL: URL) throws -> Data { Data() }
    func resolveBookmark(_ data: Data) throws -> URL { URL(fileURLWithPath: "/tmp") }
    func withScopedAccess<T>(to folderURL: URL, _ operation: () throws -> T) throws -> T { try operation() }

    func validateWritableDirectory(_ folderURL: URL) throws {
        if let validationError {
            throw validationError
        }
    }
}

final class LogseqFolderValidatorTests: XCTestCase {
    func testAcceptsWritableFolderOutsideLogseqPath() {
        let mock = ValidatorBookmarkServiceMock()
        let validator = LogseqFolderValidator(bookmarkService: mock)
        let url = URL(fileURLWithPath: "/private/var/mobile/Documents/notes")

        XCTAssertNoThrow(try validator.validate(url))
    }

    func testAcceptsWritableFolderWithOpaqueFileProviderPath() {
        let mock = ValidatorBookmarkServiceMock()
        let validator = LogseqFolderValidator(bookmarkService: mock)
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/File Provider Storage/com.apple.fileprovider/storage/7A1B2C3D/graph")

        XCTAssertNoThrow(try validator.validate(url))
    }

    func testMapsNotDirectoryError() {
        let mock = ValidatorBookmarkServiceMock()
        mock.validationError = BookmarkResolutionError.notDirectory
        let validator = LogseqFolderValidator(bookmarkService: mock)
        let url = URL(fileURLWithPath: "/private/var/mobile/Logseq/graph")

        XCTAssertThrowsError(try validator.validate(url)) { error in
            XCTAssertEqual(error as? LogseqFolderValidationError, .notDirectory)
        }
    }

    func testMapsNotWritableError() {
        let mock = ValidatorBookmarkServiceMock()
        mock.validationError = BookmarkResolutionError.notWritable
        let validator = LogseqFolderValidator(bookmarkService: mock)
        let url = URL(fileURLWithPath: "/private/var/mobile/Logseq/graph")

        XCTAssertThrowsError(try validator.validate(url)) { error in
            XCTAssertEqual(error as? LogseqFolderValidationError, .notWritable)
        }
    }

    func testAcceptsLogseqFolderWhenWritable() {
        let mock = ValidatorBookmarkServiceMock()
        let validator = LogseqFolderValidator(bookmarkService: mock)
        let url = URL(fileURLWithPath: "/private/var/mobile/Logseq/graph")

        XCTAssertNoThrow(try validator.validate(url))
    }
}
