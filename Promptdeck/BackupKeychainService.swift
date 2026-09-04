import Foundation
import Security

/// Keychain failures for the automatic-backup passphrase.
///
/// Single case only: callers map this to
/// `AutomaticBackupService.BackupError.keychainUnavailable`.
/// Messages never include secret material.
enum BackupKeychainError: Error {
    case unavailable
}

extension BackupKeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Could not access the backup passphrase in the Keychain."
        }
    }
}

/// Keychain storage for the automatic-backup passphrase (Task 15A).
///
/// The passphrase is stored as exact UTF-8 bytes (no trimming or
/// normalization) under a dedicated service/account pair, and is never
/// logged. Only the passphrase lives here; all other backup configuration
/// lives in `BackupConfigurationStore`.
enum BackupKeychainService {
    static let service = "com.mbuckingham.promptdeck.autobackup"
    static let account = "backup-passphrase"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Creates or replaces the stored passphrase using its exact bytes.
    static func save(passphrase: String) throws {
        let data = Data(passphrase.utf8)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        // ThisDeviceOnly: the backup passphrase must never migrate off this Mac.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw BackupKeychainError.unavailable
        }
        let updateQuery = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw BackupKeychainError.unavailable
        }
    }

    /// Loads the stored passphrase. Never logs or exposes secret material.
    static func load() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let passphrase = String(data: data, encoding: .utf8)
        else {
            throw BackupKeychainError.unavailable
        }
        return passphrase
    }

    /// Deletes the stored passphrase. A missing item counts as clean.
    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackupKeychainError.unavailable
        }
    }
}
