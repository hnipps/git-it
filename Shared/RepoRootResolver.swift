import Foundation

protocol RepoRootResolving {
    func resolveRepoRootURL() throws -> URL
    func resolveRepoMode() -> RepoMode
    func shouldUseLegacyFileProviderStorage() -> Bool
}

final class RepoRootResolver: RepoRootResolving {
    static let shared = RepoRootResolver()

    private let configService: ConfigService
    private let bookmarkService: SecurityScopedBookmarkServicing

    init(
        configService: ConfigService = .shared,
        bookmarkService: SecurityScopedBookmarkServicing = SecurityScopedBookmarkService.shared
    ) {
        self.configService = configService
        self.bookmarkService = bookmarkService
    }

    func resolveRepoMode() -> RepoMode {
        configService.loadConfig()?.repoMode ?? .legacyProvider
    }

    func shouldUseLegacyFileProviderStorage() -> Bool {
        resolveRepoMode() == .legacyProvider
    }

    func resolveRepoRootURL() throws -> URL {
        guard let config = configService.loadConfig() else {
            return Constants.repoPath
        }

        switch config.repoMode {
        case .legacyProvider:
            return Constants.repoPath
        case .logseqFolder:
            guard let bookmark = config.repoFolderBookmarkData else {
                throw BookmarkResolutionError.missingBookmark
            }
            let folderURL = try bookmarkService.resolveBookmark(bookmark)
            try bookmarkService.validateWritableDirectory(folderURL)
            return folderURL
        }
    }
}
