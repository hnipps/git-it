import Foundation

/// Service for reading and writing the shared `AppConfig`.
///
/// Uses atomic writes to the configuration file stored in the
/// App Group shared container.
final class ConfigService {
    static let shared = ConfigService()

    // MARK: - Private

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        self.fileURL = Constants.configFilePath

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Testable initializer that accepts an arbitrary file URL.
    init(fileURL: URL) {
        self.fileURL = fileURL

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Public API

    /// Loads the persisted configuration, returning `nil` if no config file exists
    /// or if the file cannot be decoded.
    func loadConfig() -> AppConfig? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            print("[ConfigService] Failed to load config: \(error)")
            return nil
        }
    }

    /// Persists the given configuration to disk.
    ///
    /// - Parameter config: The configuration to save.
    /// - Throws: Encoding or file-system errors.
    func saveConfig(_ config: AppConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns `true` when a valid configuration with a non-empty `remoteURL` exists.
    var isSetupComplete: Bool {
        guard let config = loadConfig() else { return false }
        return !config.remoteURL.isEmpty
    }
}
