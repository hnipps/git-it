import Foundation
import Security

// MARK: - SSHKeyType

enum SSHKeyType: String, CaseIterable {
    case ed25519
    case ecdsa
    case rsa
}

// MARK: - KeychainError

enum KeychainError: LocalizedError {
    case duplicateItem
    case itemNotFound
    case unexpectedData
    case unhandledError(status: OSStatus)
    case invalidKeyFormat
    case unsupportedKeyFormat(String)

    var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "An item with this identifier already exists in the keychain."
        case .itemNotFound:
            return "The requested item was not found in the keychain."
        case .unexpectedData:
            return "The keychain returned data in an unexpected format."
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        case .invalidKeyFormat:
            return "The provided key data is not in a valid format."
        case .unsupportedKeyFormat(let message):
            return message
        }
    }
}

// MARK: - KeychainService

final class KeychainService {

    // MARK: - Constants

    private enum ServiceIdentifier {
        static let sshPrivateKey = "com.logseqgit.ssh-key"
        static let sshPublicKey = "com.logseqgit.ssh-public-key"
        static let pat = "com.logseqgit.pat"
    }

    private enum AccountIdentifier {
        static let sshPrivateKey = "ssh-private-key"
        static let sshPublicKey = "ssh-public-key"
        static let pat = "personal-access-token"
    }

    // MARK: - PEM Headers

    private static let pemHeaders: [SSHKeyType: String] = [
        .rsa: "-----BEGIN RSA PRIVATE KEY-----",
        .ecdsa: "-----BEGIN EC PRIVATE KEY-----",
        .ed25519: "-----BEGIN OPENSSH PRIVATE KEY-----"
    ]

    private static let pemFooters: [SSHKeyType: String] = [
        .rsa: "-----END RSA PRIVATE KEY-----",
        .ecdsa: "-----END EC PRIVATE KEY-----",
        .ed25519: "-----END OPENSSH PRIVATE KEY-----"
    ]

    /// Generic begin/end markers that may wrap any key type (e.g. PKCS#8).
    private static let genericBeginMarker = "-----BEGIN PRIVATE KEY-----"
    private static let genericEndMarker = "-----END PRIVATE KEY-----"

    // MARK: - Singleton

    static let shared = KeychainService()

    private init() {}

    // MARK: - SSH Key Management

    /// Import an SSH private key from raw `Data`.
    /// Validates the key format and checks library compatibility before storing.
    func importSSHKey(privateKeyData: Data) throws {
        guard validateSSHKey(privateKeyData) != nil else {
            throw KeychainError.invalidKeyFormat
        }
        try checkKeyCompatibility(privateKeyData)
        try saveOrUpdate(
            data: privateKeyData,
            service: ServiceIdentifier.sshPrivateKey,
            account: AccountIdentifier.sshPrivateKey
        )
    }

    /// Import an SSH private key from PEM-encoded text.
    /// Parses, validates, and stores the key.
    func importSSHKey(fromText text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.invalidKeyFormat
        }
        try importSSHKey(privateKeyData: data)
    }

    /// Retrieve the stored SSH private key, or `nil` if none exists.
    func getSSHPrivateKey() throws -> Data? {
        return try loadData(
            service: ServiceIdentifier.sshPrivateKey,
            account: AccountIdentifier.sshPrivateKey
        )
    }

    /// Delete the stored SSH private key (and any stored public key).
    func deleteSSHKey() throws {
        try deleteItem(
            service: ServiceIdentifier.sshPrivateKey,
            account: AccountIdentifier.sshPrivateKey
        )
        // Best-effort removal of the companion public key.
        try? deleteItem(
            service: ServiceIdentifier.sshPublicKey,
            account: AccountIdentifier.sshPublicKey
        )
    }

    /// Derive the public key string from a private key for display.
    ///
    /// - Note: On iOS without OpenSSL, deriving public keys from arbitrary SSH
    ///   private key formats (OpenSSH, PEM, PKCS#8) is non-trivial. For v1 this
    ///   method returns a previously stored public key if one was saved via
    ///   `storePublicKey(_:)`, or `nil` otherwise. A future version may add
    ///   full derivation support using CryptoKit or a bundled library.
    func derivePublicKey(fromPrivateKey privateKey: Data) -> String? {
        // v1 limitation: return the stored public key if available.
        return try? loadString(
            service: ServiceIdentifier.sshPublicKey,
            account: AccountIdentifier.sshPublicKey
        )
    }

    /// Store a public key string alongside the private key for later retrieval
    /// via `derivePublicKey(fromPrivateKey:)`.
    func storePublicKey(_ publicKey: String) throws {
        guard let data = publicKey.data(using: .utf8) else {
            throw KeychainError.invalidKeyFormat
        }
        try saveOrUpdate(
            data: data,
            service: ServiceIdentifier.sshPublicKey,
            account: AccountIdentifier.sshPublicKey
        )
    }

    // MARK: - SSH Key Validation

    /// Check whether `keyData` looks like a valid SSH private key by inspecting
    /// PEM headers. Returns the detected `SSHKeyType`, or `nil` if unrecognised.
    func validateSSHKey(_ keyData: Data) -> SSHKeyType? {
        guard let text = String(data: keyData, encoding: .utf8) else {
            return nil
        }

        // Check type-specific headers first.
        for (keyType, header) in Self.pemHeaders {
            if let footer = Self.pemFooters[keyType],
               text.contains(header) && text.contains(footer) {
                return keyType
            }
        }

        // Fall back to the generic PKCS#8 wrapper. We cannot distinguish the
        // algorithm without parsing ASN.1, so default to RSA for now.
        if text.contains(Self.genericBeginMarker) && text.contains(Self.genericEndMarker) {
            return .rsa
        }

        return nil
    }

    /// Check whether a validated key is compatible with the bundled libssh2/OpenSSL libraries.
    ///
    /// The bundled libssh2 1.7.0 + OpenSSL 1.0.2 only support PEM-format RSA and DSA keys.
    /// OpenSSH-format keys and ECDSA/ed25519 algorithms will fail at authentication time,
    /// so we reject them here with actionable error messages.
    func checkKeyCompatibility(_ keyData: Data) throws {
        guard let text = String(data: keyData, encoding: .utf8) else {
            throw KeychainError.invalidKeyFormat
        }

        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            throw KeychainError.unsupportedKeyFormat(
                "This key is in OpenSSH format, which is not yet supported. "
                + "Please convert it to PEM format:\n"
                + "ssh-keygen -p -N \"\" -m pem -f ~/.ssh/your_key"
            )
        }

        if text.contains("-----BEGIN EC PRIVATE KEY-----") {
            throw KeychainError.unsupportedKeyFormat(
                "ECDSA keys are not yet supported. Please use an RSA key in PEM format."
            )
        }
    }

    // MARK: - HTTPS PAT Management

    /// Store a Personal Access Token.
    func storePAT(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try saveOrUpdate(
            data: data,
            service: ServiceIdentifier.pat,
            account: AccountIdentifier.pat
        )
    }

    /// Retrieve the stored PAT, or `nil` if none exists.
    func getPAT() throws -> String? {
        return try loadString(
            service: ServiceIdentifier.pat,
            account: AccountIdentifier.pat
        )
    }

    /// Delete the stored PAT.
    func deletePAT() throws {
        try deleteItem(
            service: ServiceIdentifier.pat,
            account: AccountIdentifier.pat
        )
    }

    // MARK: - Private Keychain Helpers

    /// Build the base query dictionary shared across all keychain operations.
    private func baseQuery(service: String, account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
    }

    /// Save `data` to the keychain, updating in place if the item already exists.
    private func saveOrUpdate(data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data

        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let searchQuery = baseQuery(service: service, account: account)
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Load raw `Data` from the keychain. Returns `nil` when no item is found.
    private func loadData(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Remove kSecAttrAccessible for search queries — it is only relevant when adding.
        query.removeValue(forKey: kSecAttrAccessible as String)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Convenience wrapper that loads a UTF-8 string from the keychain.
    private func loadString(service: String, account: String) throws -> String? {
        guard let data = try loadData(service: service, account: account) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    /// Delete an item from the keychain.
    private func deleteItem(service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query.removeValue(forKey: kSecAttrAccessible as String)

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
