import Foundation

enum LogseqFolderValidationError: LocalizedError, Equatable {
    case outsideLogseqDirectory
    case notDirectory
    case notWritable

    var errorDescription: String? {
        switch self {
        case .outsideLogseqDirectory:
            return "Pick a folder inside Files > Logseq (Logseq logo)."
        case .notDirectory:
            return "Selected location is not a folder."
        case .notWritable:
            return "Selected folder is not writable."
        }
    }
}

protocol LogseqFolderValidating {
    func validate(_ folderURL: URL) throws
}

final class LogseqFolderValidator: LogseqFolderValidating {
    static let shared = LogseqFolderValidator()

    private let bookmarkService: SecurityScopedBookmarkServicing

    init(bookmarkService: SecurityScopedBookmarkServicing = SecurityScopedBookmarkService.shared) {
        self.bookmarkService = bookmarkService
    }

    func validate(_ folderURL: URL) throws {
        do {
            try bookmarkService.validateWritableDirectory(folderURL)
        } catch BookmarkResolutionError.notDirectory {
            throw LogseqFolderValidationError.notDirectory
        } catch BookmarkResolutionError.notWritable {
            throw LogseqFolderValidationError.notWritable
        }
    }
}
