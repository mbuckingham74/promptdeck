import Combine
import Foundation

/// Encapsulated UserDefaults wrapper for automatic-backup configuration
/// (Task 15A). Observed by the existing backup Settings UI.
///
/// Owns exactly the keys listed below. Never stores the passphrase
/// (that lives only in `BackupKeychainService`).
final class BackupConfigurationStore: ObservableObject {
    // nonisolated(unsafe): Swift 6 requires explicit opt-out for a shared
    // mutable singleton. Lazy static initialization is thread-safe, and all
    // reads/writes funnel through UserDefaults (thread-safe) plus plain
    // in-memory state observed by the backup Settings UI.
    static nonisolated(unsafe) let shared = BackupConfigurationStore()

    static let enabledKey = "com.mbuckingham.promptdeck.autobackup.enabled"
    static let bookmarkKey = "com.mbuckingham.promptdeck.autobackup.bookmark"
    static let displayPathKey = "com.mbuckingham.promptdeck.autobackup.displayPath"
    static let lastHashKey = "com.mbuckingham.promptdeck.autobackup.lastHash"
    static let lastSnapshotFilenameKey = "com.mbuckingham.promptdeck.autobackup.lastSnapshotFilename"
    static let lastBackupDateKey = "com.mbuckingham.promptdeck.autobackup.lastBackupDate"
    static let lastErrorKey = "com.mbuckingham.promptdeck.autobackup.lastError"

    private static var ownedKeys: [String] {
        [enabledKey, bookmarkKey, displayPathKey, lastHashKey, lastSnapshotFilenameKey, lastBackupDateKey, lastErrorKey]
    }

    @Published var isEnabled: Bool = false
    @Published var bookmarkData: Data?
    @Published var displayPath: String?
    @Published var lastHash: String?
    @Published var lastSnapshotFilename: String?
    @Published var lastBackupDate: Date?
    @Published var lastErrorMessage: String?

    init() {
        load()
    }

    /// Reads all owned keys from UserDefaults.
    func load() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        bookmarkData = defaults.data(forKey: Self.bookmarkKey)
        displayPath = defaults.string(forKey: Self.displayPathKey)
        lastHash = defaults.string(forKey: Self.lastHashKey)
        lastSnapshotFilename = defaults.string(forKey: Self.lastSnapshotFilenameKey)
        lastBackupDate = defaults.object(forKey: Self.lastBackupDateKey) as? Date
        lastErrorMessage = defaults.string(forKey: Self.lastErrorKey)
    }

    /// Persists the current in-memory state to the owned keys.
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Self.enabledKey)
        if let bookmarkData {
            defaults.set(bookmarkData, forKey: Self.bookmarkKey)
        } else {
            defaults.removeObject(forKey: Self.bookmarkKey)
        }
        if let displayPath {
            defaults.set(displayPath, forKey: Self.displayPathKey)
        } else {
            defaults.removeObject(forKey: Self.displayPathKey)
        }
        if let lastHash {
            defaults.set(lastHash, forKey: Self.lastHashKey)
        } else {
            defaults.removeObject(forKey: Self.lastHashKey)
        }
        if let lastSnapshotFilename {
            defaults.set(lastSnapshotFilename, forKey: Self.lastSnapshotFilenameKey)
        } else {
            defaults.removeObject(forKey: Self.lastSnapshotFilenameKey)
        }
        if let lastBackupDate {
            defaults.set(lastBackupDate, forKey: Self.lastBackupDateKey)
        } else {
            defaults.removeObject(forKey: Self.lastBackupDateKey)
        }
        if let lastErrorMessage {
            defaults.set(lastErrorMessage, forKey: Self.lastErrorKey)
        } else {
            defaults.removeObject(forKey: Self.lastErrorKey)
        }
    }

    /// Removes only Promptdeck-owned backup keys and resets in-memory state.
    func clearAll() {
        let defaults = UserDefaults.standard
        for key in Self.ownedKeys {
            defaults.removeObject(forKey: key)
        }
        isEnabled = false
        bookmarkData = nil
        displayPath = nil
        lastHash = nil
        lastSnapshotFilename = nil
        lastBackupDate = nil
        lastErrorMessage = nil
    }
}
