import XCTest
import UniformTypeIdentifiers
import FileProvider
@testable import LogseqGit

final class FileProviderItemTests: XCTestCase {

    func testDirectoryContentType() {
        let item = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "pages",
            isDirectory: true,
            size: nil,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertEqual(item.contentType, .folder)
    }

    func testMarkdownContentType() {
        let item = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "page.md",
            isDirectory: false,
            size: 512,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertEqual(item.contentType, .plainText)
    }

    func testNoExtensionContentType() {
        let item = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "LICENSE",
            isDirectory: false,
            size: 100,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertEqual(item.contentType, .data)
    }

    func testDirectoryCapabilities() {
        let item = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "dir",
            isDirectory: true,
            size: nil,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
    }

    func testFileCapabilities() {
        let item = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.md",
            isDirectory: false,
            size: 256,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
    }

    func testDocumentSizeMapping() {
        let itemWithSize = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.txt",
            isDirectory: false,
            size: 1024,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertEqual(itemWithSize.documentSize, NSNumber(value: 1024))

        let itemWithoutSize = FileProviderItem(
            identifier: UUID().uuidString,
            parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
            filename: "file.txt",
            isDirectory: false,
            size: nil,
            creationDate: nil,
            modificationDate: nil,
            contentVersion: 1,
            metadataVersion: 1
        )
        XCTAssertNil(itemWithoutSize.documentSize)
    }
}
