import Foundation
import FileProvider
import SQLite3
import os

/// Thread-safe SQLite database manager for File Provider item identifier mapping.
///
/// Stores a mapping from file paths (relative to the repo root) to stable UUIDs
/// used as NSFileProviderItemIdentifiers. Also tracks content/metadata versions
/// and sync anchors for change enumeration.
final class MetadataDatabase {

    // MARK: - Properties

    private var db: OpaquePointer?
    private var cachedAnchor: Int64?
    private let databasePath: String

    // MARK: - Singleton

    static let shared = MetadataDatabase()

    // MARK: - Lifecycle

    private init() {
        self.databasePath = Constants.databasePath.path
        openDatabase()
        createTablesIfNeeded()
    }

    /// Testable initializer that accepts an arbitrary database file path.
    init(databasePath: String) {
        self.databasePath = databasePath
        openDatabase()
        createTablesIfNeeded()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let path = self.databasePath
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            Logger(subsystem: "com.logseqgit.fileprovider", category: "MetadataDatabase")
                .fault("Failed to open database at \(path): \(msg)")
            fatalError("MetadataDatabase: failed to open database at \(path): \(msg)")
        }
        // Enable WAL mode for concurrent reads
        execute("PRAGMA journal_mode=WAL")
    }

    private func createTablesIfNeeded() {
        let createItems = """
            CREATE TABLE IF NOT EXISTS items (
                identifier TEXT PRIMARY KEY,
                relativePath TEXT NOT NULL UNIQUE,
                parentIdentifier TEXT NOT NULL,
                filename TEXT NOT NULL,
                isDirectory INTEGER NOT NULL DEFAULT 0,
                size INTEGER,
                creationDate REAL,
                modificationDate REAL,
                contentVersion INTEGER NOT NULL DEFAULT 1,
                metadataVersion INTEGER NOT NULL DEFAULT 1,
                changeAnchor INTEGER NOT NULL DEFAULT 0,
                isDeleted INTEGER NOT NULL DEFAULT 0
            );
            """
        let createSyncState = """
            CREATE TABLE IF NOT EXISTS sync_state (
                key TEXT PRIMARY KEY,
                value INTEGER
            );
            """
        let seedAnchor = "INSERT OR IGNORE INTO sync_state (key, value) VALUES ('currentAnchor', 0);"

        execute(createItems)
        execute(createSyncState)
        execute(seedAnchor)
        execute("CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parentIdentifier, isDeleted);")
        execute("CREATE INDEX IF NOT EXISTS idx_items_anchor ON items(changeAnchor);")
    }

    // MARK: - Sync Anchors

    /// The current sync anchor value (cached to avoid repeated queries).
    var currentAnchor: Int64 {
        if let cached = cachedAnchor { return cached }
        var anchor: Int64 = 0
        let sql = "SELECT value FROM sync_state WHERE key = 'currentAnchor';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            anchor = sqlite3_column_int64(stmt, 0)
        }
        cachedAnchor = anchor
        return anchor
    }

    /// Atomically increment the sync anchor and return the new value.
    @discardableResult
    func incrementAnchor() -> Int64 {
        execute("UPDATE sync_state SET value = value + 1 WHERE key = 'currentAnchor';")
        cachedAnchor = nil
        return currentAnchor
    }

    // MARK: - Item CRUD

    /// Return the existing identifier for a path, or create a new one (along with any missing ancestors).
    func identifierForPath(_ relativePath: String) -> NSFileProviderItemIdentifier {
        // Root case
        let normalized = normalizePath(relativePath)
        if normalized.isEmpty {
            return .rootContainer
        }

        // Check if already exists
        if let existing = lookupIdentifier(for: normalized) {
            return NSFileProviderItemIdentifier(existing)
        }

        // Ensure parent exists first (recursive)
        let parentPath = (normalized as NSString).deletingLastPathComponent
        let parentIdentifier = identifierForPath(parentPath)

        // Create new entry
        let newID = UUID().uuidString
        let filename = (normalized as NSString).lastPathComponent

        // We don't know if it's a directory at this point; default to false.
        // The caller should use upsertItem to set the correct value.
        let sql = """
            INSERT OR IGNORE INTO items
            (identifier, relativePath, parentIdentifier, filename, isDirectory, changeAnchor)
            VALUES (?, ?, ?, ?, 0, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return NSFileProviderItemIdentifier(newID)
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, newID)
        bindText(stmt, 2, normalized)
        bindText(stmt, 3, parentIdentifier.rawValue)
        bindText(stmt, 4, filename)
        sqlite3_bind_int64(stmt, 5, currentAnchor)
        sqlite3_step(stmt)

        // It's possible the INSERT was ignored because a concurrent writer already created it.
        if let existing = lookupIdentifier(for: normalized) {
            return NSFileProviderItemIdentifier(existing)
        }
        return NSFileProviderItemIdentifier(newID)
    }

    /// Look up the relative path for a given identifier.
    func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer {
            return ""
        }
        let sql = "SELECT relativePath FROM items WHERE identifier = ? AND isDeleted = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, identifier.rawValue)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }

    /// Look up a single item by identifier, returning a FileProviderItem or nil.
    func getItem(for identifier: NSFileProviderItemIdentifier) -> FileProviderItem? {
        let sql = """
            SELECT identifier, parentIdentifier, filename, isDirectory, size,
                   creationDate, modificationDate, contentVersion, metadataVersion
            FROM items
            WHERE identifier = ? AND isDeleted = 0;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, identifier.rawValue)
        let items = readItems(from: stmt)
        return items.first
    }

    /// Insert or update an item. Bumps contentVersion and sets changeAnchor to current.
    func upsertItem(
        relativePath: String,
        isDirectory: Bool,
        size: Int64?,
        modDate: Date?,
        creationDate: Date?
    ) {
        let normalized = normalizePath(relativePath)
        guard !normalized.isEmpty else { return } // Don't upsert root

        let parentPath = (normalized as NSString).deletingLastPathComponent
        let parentIdentifier = identifierForPath(parentPath)
        let filename = (normalized as NSString).lastPathComponent
        let anchor = currentAnchor

        // Check if item already exists
        let existingID = lookupIdentifier(for: normalized)
        let identifier = existingID ?? UUID().uuidString

        if existingID != nil {
            // Update existing
            let sql = """
                UPDATE items SET
                    parentIdentifier = ?,
                    filename = ?,
                    isDirectory = ?,
                    size = ?,
                    creationDate = ?,
                    modificationDate = ?,
                    contentVersion = contentVersion + 1,
                    changeAnchor = ?,
                    isDeleted = 0
                WHERE identifier = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, parentIdentifier.rawValue)
            bindText(stmt, 2, filename)
            sqlite3_bind_int(stmt, 3, isDirectory ? 1 : 0)
            bindOptionalInt64(stmt, 4, size)
            bindOptionalDouble(stmt, 5, creationDate?.timeIntervalSince1970)
            bindOptionalDouble(stmt, 6, modDate?.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 7, anchor)
            bindText(stmt, 8, identifier)
            sqlite3_step(stmt)
        } else {
            // Insert new
            let sql = """
                INSERT INTO items
                (identifier, relativePath, parentIdentifier, filename, isDirectory, size, creationDate, modificationDate, contentVersion, metadataVersion, changeAnchor, isDeleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?, 0);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, identifier)
            bindText(stmt, 2, normalized)
            bindText(stmt, 3, parentIdentifier.rawValue)
            bindText(stmt, 4, filename)
            sqlite3_bind_int(stmt, 5, isDirectory ? 1 : 0)
            bindOptionalInt64(stmt, 6, size)
            bindOptionalDouble(stmt, 7, creationDate?.timeIntervalSince1970)
            bindOptionalDouble(stmt, 8, modDate?.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 9, anchor)
            sqlite3_step(stmt)
        }
    }

    /// Mark an item as deleted and bump its changeAnchor.
    func markDeleted(relativePath: String) {
        let normalized = normalizePath(relativePath)
        let anchor = currentAnchor
        let sql = "UPDATE items SET isDeleted = 1, changeAnchor = ? WHERE relativePath = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchor)
        bindText(stmt, 2, normalized)
        sqlite3_step(stmt)
    }

    /// Permanently remove deleted items whose changeAnchor is older than the given anchor.
    func removeDeletedItems(olderThan anchor: Int64) {
        let sql = "DELETE FROM items WHERE isDeleted = 1 AND changeAnchor < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchor)
        sqlite3_step(stmt)
    }

    /// Update the path, filename, and parent for an item (rename/move).
    func updatePath(
        for identifier: NSFileProviderItemIdentifier,
        newRelativePath: String,
        newFilename: String,
        newParentIdentifier: NSFileProviderItemIdentifier
    ) {
        let normalized = normalizePath(newRelativePath)
        let anchor = currentAnchor
        let sql = """
            UPDATE items SET
                relativePath = ?,
                filename = ?,
                parentIdentifier = ?,
                metadataVersion = metadataVersion + 1,
                changeAnchor = ?
            WHERE identifier = ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, normalized)
        bindText(stmt, 2, newFilename)
        bindText(stmt, 3, newParentIdentifier.rawValue)
        sqlite3_bind_int64(stmt, 4, anchor)
        bindText(stmt, 5, identifier.rawValue)
        sqlite3_step(stmt)
    }

    // MARK: - Enumeration

    /// Paginated listing of non-deleted children of a parent.
    func enumerateItems(
        in parent: NSFileProviderItemIdentifier,
        startingAt offset: Int,
        limit: Int
    ) -> [FileProviderItem] {
        let sql = """
            SELECT identifier, parentIdentifier, filename, isDirectory, size,
                   creationDate, modificationDate, contentVersion, metadataVersion
            FROM items
            WHERE parentIdentifier = ? AND isDeleted = 0
            ORDER BY filename ASC
            LIMIT ? OFFSET ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, parent.rawValue)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))

        return readItems(from: stmt)
    }

    /// Recently changed non-deleted items for the working set.
    func getWorkingSetItems(startingAt offset: Int, limit: Int) -> [FileProviderItem] {
        let sql = """
            SELECT identifier, parentIdentifier, filename, isDirectory, size,
                   creationDate, modificationDate, contentVersion, metadataVersion
            FROM items
            WHERE isDeleted = 0
            ORDER BY changeAnchor DESC
            LIMIT ? OFFSET ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))

        return readItems(from: stmt)
    }

    /// Return all changes since the given sync anchor.
    func getChangesSince(anchor: Int64) -> (
        updated: [FileProviderItem],
        deletedIdentifiers: [NSFileProviderItemIdentifier],
        newAnchor: Int64
    ) {
        let newAnchor = currentAnchor

        // Updated (non-deleted) items
        let updatedSQL = """
            SELECT identifier, parentIdentifier, filename, isDirectory, size,
                   creationDate, modificationDate, contentVersion, metadataVersion
            FROM items
            WHERE changeAnchor > ? AND isDeleted = 0
            ORDER BY changeAnchor ASC;
            """
        var updatedStmt: OpaquePointer?
        var updated: [FileProviderItem] = []
        if sqlite3_prepare_v2(db, updatedSQL, -1, &updatedStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(updatedStmt, 1, anchor)
            updated = readItems(from: updatedStmt)
            sqlite3_finalize(updatedStmt)
        }

        // Deleted items
        let deletedSQL = """
            SELECT identifier FROM items
            WHERE changeAnchor > ? AND isDeleted = 1
            ORDER BY changeAnchor ASC;
            """
        var deletedStmt: OpaquePointer?
        var deletedIdentifiers: [NSFileProviderItemIdentifier] = []
        if sqlite3_prepare_v2(db, deletedSQL, -1, &deletedStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(deletedStmt, 1, anchor)
            while sqlite3_step(deletedStmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(deletedStmt, 0))
                deletedIdentifiers.append(NSFileProviderItemIdentifier(id))
            }
            sqlite3_finalize(deletedStmt)
        }

        return (updated, deletedIdentifiers, newAnchor)
    }

    // MARK: - Bulk Operations

    /// Scan the repo directory on disk, upsert all found items, and mark missing items as deleted.
    ///
    /// This is used after a git pull or for initial population of the database.
    func syncWithDisk(repoURL: URL, excludedPaths: [String] = []) {
        let fm = FileManager.default

        // Increment anchor for this sync batch
        let anchor = incrementAnchor()

        // Collect all relative paths currently on disk
        var diskPaths = Set<String>()

        guard let enumerator = fm.enumerator(
            at: repoURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        execute("BEGIN TRANSACTION;")

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(
                of: repoURL.path + "/",
                with: ""
            )

            // Skip excluded paths
            if excludedPaths.contains(where: { relativePath.hasPrefix($0) }) {
                if fileURL.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            diskPaths.insert(relativePath)

            let resourceValues = try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )
            let isDir = resourceValues?.isDirectory ?? fileURL.hasDirectoryPath
            let size = resourceValues?.fileSize.map { Int64($0) }
            let created = resourceValues?.creationDate
            let modified = resourceValues?.contentModificationDate

            upsertItem(
                relativePath: relativePath,
                isDirectory: isDir,
                size: size,
                modDate: modified,
                creationDate: created
            )
        }

        // Mark items not found on disk as deleted
        let allPaths = allNonDeletedPaths()
        for existingPath in allPaths {
            if !diskPaths.contains(existingPath) {
                markDeleted(relativePath: existingPath)
            }
        }

        execute("COMMIT;")

        // Ignore anchor variable warning — it was used to increment the global anchor
        _ = anchor
    }

    // MARK: - Private Helpers

    private func normalizePath(_ path: String) -> String {
        var p = path
        // Remove leading slash
        while p.hasPrefix("/") {
            p = String(p.dropFirst())
        }
        // Remove trailing slash
        while p.hasSuffix("/") {
            p = String(p.dropLast())
        }
        // Normalize "." to empty
        if p == "." { return "" }
        return p
    }

    private func lookupIdentifier(for normalizedPath: String) -> String? {
        let sql = "SELECT identifier FROM items WHERE relativePath = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, normalizedPath)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }

    private func allNonDeletedPaths() -> [String] {
        let sql = "SELECT relativePath FROM items WHERE isDeleted = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return paths
    }

    /// Read FileProviderItem rows from a prepared statement with the standard 9-column SELECT.
    private func readItems(from stmt: OpaquePointer?) -> [FileProviderItem] {
        var items: [FileProviderItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let identifier = String(cString: sqlite3_column_text(stmt, 0))
            let parentIdentifier = String(cString: sqlite3_column_text(stmt, 1))
            let filename = String(cString: sqlite3_column_text(stmt, 2))
            let isDirectory = sqlite3_column_int(stmt, 3) != 0
            let size: Int64? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? sqlite3_column_int64(stmt, 4) : nil
            let creationDate: Date? = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)) : nil
            let modificationDate: Date? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)) : nil
            let contentVersion = sqlite3_column_int64(stmt, 7)
            let metadataVersion = sqlite3_column_int64(stmt, 8)

            items.append(FileProviderItem(
                identifier: identifier,
                parentIdentifier: parentIdentifier,
                filename: filename,
                isDirectory: isDirectory,
                size: size,
                creationDate: creationDate,
                modificationDate: modificationDate,
                contentVersion: contentVersion,
                metadataVersion: metadataVersion
            ))
        }
        return items
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            if let errMsg = errMsg {
                let message = String(cString: errMsg)
                sqlite3_free(errMsg)
                print("MetadataDatabase: SQL error: \(message)")
            }
            return false
        }
        return true
    }

    // MARK: - Binding Helpers

    /// SQLITE_TRANSIENT equivalent — tells SQLite to copy the string.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, Self.sqliteTransient)
    }

    private func bindOptionalInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value = value {
            sqlite3_bind_int64(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
