import Foundation

/// Monitors write activity from the File Provider extension and signals the main app
/// to commit after a period of inactivity (60 seconds).
///
/// This uses Darwin notifications (inter-process) to wake the main app since the
/// extension runs in a separate process with a strict 20 MB memory limit.
final class WriteActivityMonitor {

    // MARK: - Properties

    private var debounceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.logseqgit.write-monitor")
    private let debounceInterval: TimeInterval = 60.0

    // MARK: - Public API

    /// Call this whenever the extension performs a write (create, modify, delete).
    /// Resets the debounce timer; after `debounceInterval` seconds of silence the
    /// monitor posts a Darwin notification so the main app can commit.
    func recordWriteActivity() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimer()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.debounceInterval)
            timer.setEventHandler { [weak self] in
                self?.signalCommitNeeded()
            }
            timer.resume()
            self.debounceTimer = timer
        }
    }

    /// Cancel any pending timer. Call from `invalidate()` on the extension.
    func invalidate() {
        queue.async { [weak self] in
            self?.cancelTimer()
        }
    }

    // MARK: - Private

    private func cancelTimer() {
        debounceTimer?.cancel()
        debounceTimer = nil
    }

    private func signalCommitNeeded() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(Constants.DarwinNotification.fileProviderDidUpdate as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }
}
