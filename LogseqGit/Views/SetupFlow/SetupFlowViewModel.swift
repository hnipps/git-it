import Foundation
import SwiftUI

// MARK: - SetupStep

enum SetupStep: Int, CaseIterable {
    case remote
    case auth
    case clone
    case instructions
}

// MARK: - SetupFlowViewModel

final class SetupFlowViewModel: ObservableObject {

    // MARK: - Navigation

    @Published var currentStep: SetupStep = .remote

    // MARK: - Remote Config

    @Published var remoteURL: String = ""
    @Published var branch: String = "main"
    @Published var graphName: String = ""

    // MARK: - Auth Config

    @Published var authMethod: AuthMethod = .https

    // MARK: - Error State

    @Published var errorMessage: String?

    // MARK: - Services

    let gitService: GitService
    let keychainService: KeychainService
    let configService: ConfigService

    // MARK: - Init

    init(
        gitService: GitService? = nil,
        keychainService: KeychainService = .shared,
        configService: ConfigService = .shared
    ) {
        self.keychainService = keychainService
        self.configService = configService
        self.gitService = gitService ?? GitService(
            keychainService: keychainService,
            configService: configService
        )
    }

    // MARK: - Helpers

    /// Tracks the previous derived graph name so we can detect whether the user
    /// has manually edited the field vs. it still matching the auto-derived value.
    private var previousDerivedGraphName: String = ""

    /// Derives a graph name from the remote URL if the user hasn't provided one.
    func deriveGraphName(from url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle git@host:user/repo.git and https://host/user/repo.git
        let lastComponent = trimmed.components(separatedBy: "/").last
            ?? trimmed.components(separatedBy: ":").last
            ?? trimmed
        return lastComponent
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Updates the graph name when the remote URL changes, but only if the user
    /// hasn't manually edited the graph name.
    func updateGraphNameIfNeeded() {
        let derived = deriveGraphName(from: remoteURL)
        if graphName.isEmpty || graphName == previousDerivedGraphName {
            graphName = derived
        }
        previousDerivedGraphName = derived
    }

    // MARK: - Navigation Actions

    func advanceToAuth() {
        if graphName.isEmpty {
            graphName = deriveGraphName(from: remoteURL)
        }
        currentStep = .auth
    }

    func advanceToClone() {
        currentStep = .clone
    }

    func advanceToInstructions() {
        currentStep = .instructions
    }

    // MARK: - Config Persistence

    func saveConfig() async throws {
        let config = AppConfig(
            remoteURL: remoteURL,
            authMethod: authMethod,
            branch: branch,
            graphName: graphName
        )
        try await configService.saveConfig(config)
    }
}
