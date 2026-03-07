import Foundation

// MARK: - SyncLogEntry

struct SyncLogEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let action: String  // "pull", "push", "commit", "background-push", "error"
    let message: String // Human-readable summary

    init(action: String, message: String) {
        self.id = UUID()
        self.date = Date()
        self.action = action
        self.message = message
    }
}

// MARK: - SyncLogger

class SyncLogger {
    static let shared = SyncLogger()

    private let logURL: URL
    private let maxEntries = 100
    private let queue = DispatchQueue(label: "com.logseqgit.synclogger", qos: .utility)

    private init() {
        logURL = Constants.syncLogPath
    }

    /// Append a log entry to the JSON array file, trimming to `maxEntries`.
    func log(_ entry: SyncLogEntry) {
        queue.sync {
            var entries = readEntries()
            entries.append(entry)

            // Trim oldest entries when exceeding the cap
            if entries.count > maxEntries {
                entries = Array(entries.suffix(maxEntries))
            }

            writeEntries(entries)
        }
    }

    /// Return the most recent log entries, up to `limit`.
    func getRecentEntries(limit: Int = 20) -> [SyncLogEntry] {
        let entries = queue.sync { readEntries() }
        return Array(entries.suffix(limit))
    }

    /// Delete the log file entirely.
    func clearLog() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    // MARK: - Private Helpers

    private func readEntries() -> [SyncLogEntry] {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: logURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SyncLogEntry].self, from: data)
        } catch {
            return []
        }
    }

    private func writeEntries(_ entries: [SyncLogEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)

            // Ensure the parent directory exists
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            try data.write(to: logURL, options: .atomic)
        } catch {
            // Logging failures are non-fatal; silently discard.
        }
    }
}
