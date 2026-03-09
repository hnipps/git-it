import FileProvider
import UniformTypeIdentifiers

/// NSFileProviderItem-conforming class that wraps a database row.
class FileProviderItem: NSObject, NSFileProviderItem {

    // MARK: - NSFileProviderItem properties

    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities

    // MARK: - Initializer

    init(
        identifier: String,
        parentIdentifier: String,
        filename: String,
        isDirectory: Bool,
        size: Int64?,
        creationDate: Date?,
        modificationDate: Date?,
        contentVersion: Int64,
        metadataVersion: Int64
    ) {
        // Map identifier strings to NSFileProviderItemIdentifier
        if identifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
            self.itemIdentifier = .rootContainer
        } else {
            self.itemIdentifier = NSFileProviderItemIdentifier(identifier)
        }

        if parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue {
            self.parentItemIdentifier = .rootContainer
        } else {
            self.parentItemIdentifier = NSFileProviderItemIdentifier(parentIdentifier)
        }

        self.filename = filename
        self.creationDate = creationDate
        self.contentModificationDate = modificationDate
        self.documentSize = size.map { NSNumber(value: $0) }

        // Content type
        if isDirectory {
            self.contentType = .folder
        } else {
            let ext = (filename as NSString).pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                self.contentType = .plainText
            } else if ext.isEmpty {
                self.contentType = .data
            } else {
                self.contentType = UTType(filenameExtension: ext) ?? .data
            }
        }

        // Capabilities
        if isDirectory {
            self.capabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsDeleting,
                .allowsRenaming,
                .allowsReparenting
            ]
        } else {
            self.capabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsDeleting,
                .allowsRenaming,
                .allowsReparenting
            ]
        }

        // Item version — encode Int64 values as raw bytes in Data
        let contentData = withUnsafeBytes(of: contentVersion.littleEndian) { Data($0) }
        let metadataData = withUnsafeBytes(of: metadataVersion.littleEndian) { Data($0) }
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: contentData,
            metadataVersion: metadataData
        )

        super.init()
    }

    // MARK: - Transfer state

    var isUploaded: Bool { true }
    var isUploading: Bool { false }
    var isDownloaded: Bool { true }
    var isDownloading: Bool { false }
    var isMostRecentVersionDownloaded: Bool { true }
}
