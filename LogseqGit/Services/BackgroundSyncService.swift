import Foundation
import BackgroundTasks

class BackgroundSyncService {
    static let shared = BackgroundSyncService()

    private init() {}

    /// Register the background refresh task with the system.
    /// Call this once during app launch (e.g. in `application(_:didFinishLaunchingWithOptions:)`).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Constants.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
                self.handleBackgroundSync(task: bgTask)
        }
    }

    /// Schedule the next background sync. Safe to call multiple times;
    /// the system coalesces duplicate requests for the same identifier.
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Constants.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min minimum
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SyncLogger.shared.log(
                SyncLogEntry(
                    action: "error",
                    message: "Failed to schedule background sync: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Private

    private func handleBackgroundSync(task: BGAppRefreshTask) {
        // Schedule the next occurrence before doing work
        scheduleBackgroundSync()

        let syncTask = Task {
            do {
                let gitService = GitService()
                if try await gitService.hasUncommittedChanges() {
                    let result = try await gitService.commitAndPush(message: nil)
                    SyncLogger.shared.log(
                        SyncLogEntry(action: "background-push", message: result.message)
                    )
                }
                task.setTaskCompleted(success: true)
            } catch {
                SyncLogger.shared.log(
                    SyncLogEntry(
                        action: "error",
                        message: "Background sync failed: \(error.localizedDescription)"
                    )
                )
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            syncTask.cancel()
        }
    }
}
