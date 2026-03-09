import Foundation

enum BookmarkResolutionError: LocalizedError, Equatable {
    case missingBookmark
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case staleBookmark
    case notDirectory
    case notWritable
    case cannotAccessSecurityScope

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "No graph folder has been selected."
        case .bookmarkCreationFailed:
            return "Could not save access to the selected folder."
        case .bookmarkResolutionFailed:
            return "Could not reopen the selected graph folder."
        case .staleBookmark:
            return "Saved folder access expired. Please reselect your graph folder."
        case .notDirectory:
            return "Selected URL is not a folder."
        case .notWritable:
            return "Selected folder is not writable."
        case .cannotAccessSecurityScope:
            return "Could not access the selected folder."
        }
    }
}

protocol SecurityScopedBookmarkServicing {
    func createBookmarkData(for folderURL: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> URL
    func withScopedAccess<T>(to folderURL: URL, _ operation: () throws -> T) throws -> T
    func validateWritableDirectory(_ folderURL: URL) throws
}

final class SecurityScopedBookmarkService: SecurityScopedBookmarkServicing {
    static let shared = SecurityScopedBookmarkService()

    func createBookmarkData(for folderURL: URL) throws -> Data {
        do {
            return try withScopedAccess(to: folderURL) {
                try folderURL.bookmarkData(
                    options: bookmarkCreationOptions(),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        } catch BookmarkResolutionError.cannotAccessSecurityScope {
            throw BookmarkResolutionError.cannotAccessSecurityScope
        } catch {
            throw BookmarkResolutionError.bookmarkCreationFailed
        }
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false

        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw BookmarkResolutionError.bookmarkResolutionFailed
        }

        if isStale {
            throw BookmarkResolutionError.staleBookmark
        }

        return resolved
    }

    func withScopedAccess<T>(to folderURL: URL, _ operation: () throws -> T) throws -> T {
        let didStart = folderURL.startAccessingSecurityScopedResource()

        if !didStart && requiresSecurityScope(folderURL) {
            throw BookmarkResolutionError.cannotAccessSecurityScope
        }

        defer {
            if didStart {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }

    private func requiresSecurityScope(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        let sandboxRoot = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

        if standardizedPath.hasPrefix(sandboxRoot) {
            return false
        }

        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroupID) {
            let appGroupRoot = appGroupURL.standardizedFileURL.path
            if standardizedPath.hasPrefix(appGroupRoot) {
                return false
            }
        }
        return true
    }

    private func bookmarkCreationOptions() -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return [.minimalBookmark]
        #endif
    }

    func validateWritableDirectory(_ folderURL: URL) throws {
        try withScopedAccess(to: folderURL) {
            let values = try folderURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ])
            guard values.isDirectory == true else {
                throw BookmarkResolutionError.notDirectory
            }

            if values.isUbiquitousItem == true {
                let status = values.ubiquitousItemDownloadingStatus
                if status != nil && status != URLUbiquitousItemDownloadingStatus.current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: folderURL)

                    let deadline = Date().addingTimeInterval(15)
                    while Date() < deadline {
                        let refreshed = try folderURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                        if refreshed.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                }
            }

            let fm = FileManager.default
            let probe = folderURL.appendingPathComponent(".logseqgit-write-test-\(UUID().uuidString)")
            let data = Data("ok".utf8)
            do {
                try data.write(to: probe, options: .atomic)
                try fm.removeItem(at: probe)
            } catch {
                throw BookmarkResolutionError.notWritable
            }
        }
    }
}
