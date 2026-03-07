import FileProvider

/// Enumerates items and changes for a given container (directory or working set).
class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let db: MetadataDatabase
    private let pageSize = 100

    init(containerIdentifier: NSFileProviderItemIdentifier, db: MetadataDatabase) {
        self.containerIdentifier = containerIdentifier
        self.db = db
        super.init()
    }

    func invalidate() { }

    // MARK: - Item Enumeration

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let offset: Int
        if page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
            || page == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage {
            offset = 0
        } else {
            offset = decodePage(page)
        }

        let items: [FileProviderItem]
        if containerIdentifier == .workingSet {
            items = db.getWorkingSetItems(startingAt: offset, limit: pageSize)
        } else {
            items = db.enumerateItems(in: containerIdentifier, startingAt: offset, limit: pageSize)
        }

        observer.didEnumerate(items)

        if items.count < pageSize {
            observer.finishEnumerating(upTo: nil)
        } else {
            let nextPage = encodePage(offset + items.count)
            observer.finishEnumerating(upTo: nextPage)
        }
    }

    // MARK: - Change Enumeration

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        let anchor = decodeSyncAnchor(syncAnchor)
        let changes = db.getChangesSince(anchor: anchor)

        if !changes.updated.isEmpty {
            observer.didUpdate(changes.updated)
        }
        if !changes.deletedIdentifiers.isEmpty {
            observer.didDeleteItems(withIdentifiers: changes.deletedIdentifiers)
        }

        let newAnchor = encodeSyncAnchor(changes.newAnchor)
        observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = encodeSyncAnchor(db.currentAnchor)
        completionHandler(anchor)
    }
}

// MARK: - Encoding Helpers

func encodeSyncAnchor(_ value: Int64) -> NSFileProviderSyncAnchor {
    let data = Data(String(value).utf8)
    return NSFileProviderSyncAnchor(data)
}

func decodeSyncAnchor(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
    guard let string = String(data: anchor.rawValue, encoding: .utf8),
          let value = Int64(string) else {
        return 0
    }
    return value
}

func encodePage(_ offset: Int) -> NSFileProviderPage {
    let data = Data(String(offset).utf8)
    return NSFileProviderPage(data)
}

func decodePage(_ page: NSFileProviderPage) -> Int {
    guard let string = String(data: page.rawValue, encoding: .utf8),
          let value = Int(string) else {
        return 0
    }
    return value
}
