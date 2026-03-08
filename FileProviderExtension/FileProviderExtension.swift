import FileProvider
import UniformTypeIdentifiers

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain
    let db: MetadataDatabase
    let repoURL: URL
    let writeMonitor: WriteActivityMonitor

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.repoURL = Constants.repoPath
        self.db = MetadataDatabase.shared
        self.writeMonitor = WriteActivityMonitor()
        super.init()
    }

    func invalidate() {
        writeMonitor.invalidate()
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        switch containerItemIdentifier {
        case .rootContainer, .workingSet:
            return FileProviderEnumerator(containerIdentifier: containerItemIdentifier, db: db)
        default:
            // Verify the identifier exists in the database
            guard db.path(for: containerItemIdentifier) != nil else {
                throw NSFileProviderError(.noSuchItem)
            }
            return FileProviderEnumerator(containerIdentifier: containerItemIdentifier, db: db)
        }
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            // Synthesize a root container item
            let root = FileProviderItem(
                identifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
                parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue,
                filename: "",
                isDirectory: true,
                size: nil,
                creationDate: nil,
                modificationDate: nil,
                contentVersion: 0,
                metadataVersion: 0
            )
            completionHandler(root, nil)
            progress.completedUnitCount = 1
            return progress
        }

        if let found = db.getItem(for: identifier) {
            completionHandler(found, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }

        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Fetch Contents

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let relativePath = db.path(for: itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        let fileURL = repoURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        let item = db.getItem(for: itemIdentifier)
        completionHandler(fileURL, item, nil)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Create Item

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let fm = FileManager.default

        // Resolve parent path
        let parentRelativePath: String
        if itemTemplate.parentItemIdentifier == .rootContainer {
            parentRelativePath = ""
        } else {
            guard let path = db.path(for: itemTemplate.parentItemIdentifier) else {
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
                return progress
            }
            parentRelativePath = path
        }

        let relativePath: String
        if parentRelativePath.isEmpty {
            relativePath = itemTemplate.filename
        } else {
            relativePath = (parentRelativePath as NSString).appendingPathComponent(itemTemplate.filename)
        }

        // Check exclusion
        if RepoManager.shared.shouldExclude(relativePath: relativePath) {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            progress.completedUnitCount = 1
            return progress
        }

        let targetURL = repoURL.appendingPathComponent(relativePath)
        let isDirectory = itemTemplate.contentType == .folder

        do {
            if isDirectory {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else if let sourceURL = url {
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: targetURL)
                try fm.copyItem(at: sourceURL, to: targetURL)
            } else {
                // Create empty file
                fm.createFile(atPath: targetURL.path, contents: nil)
            }
        } catch {
            completionHandler(nil, [], false, error)
            progress.completedUnitCount = 1
            return progress
        }

        // Read attributes for the DB record
        let attrs = try? fm.attributesOfItem(atPath: targetURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
        let creationDate = (attrs?[.creationDate] as? Date) ?? Date()

        db.upsertItem(
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modDate: modDate,
            creationDate: creationDate
        )
        let newAnchor = db.incrementAnchor()

        let identifier = db.identifierForPath(relativePath)
        let parentIdentifier = itemTemplate.parentItemIdentifier

        let createdItem = FileProviderItem(
            identifier: identifier.rawValue,
            parentIdentifier: parentIdentifier.rawValue,
            filename: itemTemplate.filename,
            isDirectory: isDirectory,
            size: isDirectory ? nil : size,
            creationDate: creationDate,
            modificationDate: modDate,
            contentVersion: newAnchor,
            metadataVersion: newAnchor
        )

        writeMonitor.recordWriteActivity()
        completionHandler(createdItem, [], false, nil)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Modify Item

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let fm = FileManager.default

        guard var relativePath = db.path(for: item.itemIdentifier) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        var currentFilename = (relativePath as NSString).lastPathComponent
        var currentParentIdentifier = item.parentItemIdentifier
        var didWriteContent = false

        // Handle rename
        if changedFields.contains(.filename) {
            currentFilename = item.filename
        }

        // Handle move (reparenting)
        if changedFields.contains(.parentItemIdentifier) {
            currentParentIdentifier = item.parentItemIdentifier
        }

        // Compute new path if rename or move occurred
        if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            let newParentPath: String
            if currentParentIdentifier == .rootContainer {
                newParentPath = ""
            } else {
                guard let pp = db.path(for: currentParentIdentifier) else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    progress.completedUnitCount = 1
                    return progress
                }
                newParentPath = pp
            }

            let newRelativePath: String
            if newParentPath.isEmpty {
                newRelativePath = currentFilename
            } else {
                newRelativePath = (newParentPath as NSString).appendingPathComponent(currentFilename)
            }

            if newRelativePath != relativePath {
                let oldURL = repoURL.appendingPathComponent(relativePath)
                let newURL = repoURL.appendingPathComponent(newRelativePath)

                do {
                    let parentDir = newURL.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parentDir.path) {
                        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    }
                    try fm.moveItem(at: oldURL, to: newURL)
                } catch {
                    completionHandler(nil, [], false, error)
                    progress.completedUnitCount = 1
                    return progress
                }

                db.updatePath(
                    for: item.itemIdentifier,
                    newRelativePath: newRelativePath,
                    newFilename: currentFilename,
                    newParentIdentifier: currentParentIdentifier
                )
                relativePath = newRelativePath
            }
        }

        // Handle content update
        if changedFields.contains(.contents), let sourceURL = newContents {
            let targetURL = repoURL.appendingPathComponent(relativePath)
            do {
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                try fm.copyItem(at: sourceURL, to: targetURL)
                didWriteContent = true
            } catch {
                completionHandler(nil, [], false, error)
                progress.completedUnitCount = 1
                return progress
            }
        }

        // Update DB metadata
        let fileURL = repoURL.appendingPathComponent(relativePath)
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
        let creationDate = (attrs?[.creationDate] as? Date) ?? Date()
        let isDirectory = item.contentType == .folder

        db.upsertItem(
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modDate: modDate,
            creationDate: creationDate
        )
        let newAnchor = db.incrementAnchor()

        let updatedItem = FileProviderItem(
            identifier: item.itemIdentifier.rawValue,
            parentIdentifier: currentParentIdentifier.rawValue,
            filename: currentFilename,
            isDirectory: isDirectory,
            size: isDirectory ? nil : size,
            creationDate: creationDate,
            modificationDate: modDate,
            contentVersion: newAnchor,
            metadataVersion: newAnchor
        )

        if didWriteContent {
            writeMonitor.recordWriteActivity()
        }

        completionHandler(updatedItem, [], false, nil)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Delete Item

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let relativePath = db.path(for: identifier) else {
            completionHandler(NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        let fileURL = repoURL.appendingPathComponent(relativePath)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                completionHandler(error)
                progress.completedUnitCount = 1
                return progress
            }
        }

        db.markDeleted(relativePath: relativePath)
        _ = db.incrementAnchor()

        writeMonitor.recordWriteActivity()
        completionHandler(nil)
        progress.completedUnitCount = 1
        return progress
    }
}
