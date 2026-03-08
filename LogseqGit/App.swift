import SwiftUI
import FileProvider
import BackgroundTasks

@main
struct LogseqGitApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isSetupComplete {
                    MainView()
                } else {
                    SetupFlowView()
                }
            }
            .environmentObject(appState)
            .task {
                await appState.bootstrap()
            }
        }
    }
}

// MARK: - App State

final class AppState: ObservableObject {
    @Published var isSetupComplete: Bool = false

    /// Perform one-time launch setup: register the File Provider domain and
    /// schedule background tasks.
    func bootstrap() async {
        await checkSetupState()
        await registerFileProviderDomain()
        BackgroundSyncService.shared.registerBackgroundTask()
        BackgroundSyncService.shared.scheduleBackgroundSync()
    }

    func checkSetupState() async {
        let complete = ConfigService.shared.isSetupComplete
        await MainActor.run {
            self.isSetupComplete = complete
        }
    }

    // MARK: - File Provider Domain

    private func registerFileProviderDomain() async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: Constants.fileProviderDomainID),
            displayName: "Logseq"
        )

        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            print("[App] Failed to register File Provider domain: \(error)")
        }
    }
}
