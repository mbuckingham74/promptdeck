import Foundation
import SwiftData

/// Headless automatic-backup engine (Task 15A).
///
/// Encrypted-only snapshots reusing the exact manual-Export format
/// (`ExportService` DTOs/documents/encoder + `PromptdeckArchiveCodec`).
/// No scheduling, timers, or daemons live here: files are created only by
/// `setupFirstBackup`, `changeLocation`, and `performBackup`.
///
/// Rules enforced throughout:
/// - SwiftData is read-only (nothing is ever mutated).
/// - The passphrase is used as exact bytes (no trimming) and never logged,
///   persisted outside the Keychain, or replaced by a fallback.
/// - Writes are atomic; `lastHash`/`lastSnapshotFilename`/`lastBackupDate`
///   advance only after the write is verified.
/// - Retention runs only after a verified write, touches only managed
///   `Promptdeck Backup *.promptdeck` files inside the backup folder, never
///   deletes the just-written file, and never throws away a success.
enum AutomaticBackupService {
    static let backupFolderName = "Promptdeck Backups"
    static let filenamePrefix = "Promptdeck Backup "
    static let filenameExtension = "promptdeck"
    static let maxSnapshots = 14

    /// Centralized identity for the retention warning set by
    /// `enforceRetention` on an otherwise successful backup.
    static let retentionWarningMessage = "Backup succeeded, but removing old snapshots failed."

    /// Returns true for the retention warning (nil → false). Mirrors the
    /// Settings view's detection: case-insensitive contains
    /// "removing old snapshots".
    static func isRetentionWarning(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return message.localizedCaseInsensitiveContains("removing old snapshots")
    }

    enum BackupOutcome {
        case backedUp(URL)
        case alreadyBackedUp
    }

    enum BackupError: Error {
        case notConfigured
        case keychainUnavailable
        case locationUnavailable(String)
        case bookmarkStale
        case writeFailed(String)
    }

    // MARK: - performBackup

    /// Writes an encrypted snapshot unless the library is unchanged.
    ///
    /// - Returns `.alreadyBackedUp` (writing nothing and leaving the stored
    ///   hash/date/filename untouched) when `force` is false, the fingerprint
    ///   matches the stored hash, AND the tracked snapshot filename still
    ///   resolves to a managed snapshot in the current backup folder. A
    ///   fingerprint match with a missing/malformed/untracked snapshot falls
    ///   through to the normal encrypted write path; otherwise
    ///   `.backedUp(URL)`.
    @MainActor
    static func performBackup(modelContext: ModelContext, force: Bool) throws -> BackupOutcome {
        let store = BackupConfigurationStore.shared
        guard store.isEnabled, store.bookmarkData != nil else {
            throw BackupError.notConfigured
        }
        let parentURL = try resolveParentURL()
        let accessing = parentURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { parentURL.stopAccessingSecurityScopedResource() }
        }
        let passphrase: String
        do {
            passphrase = try BackupKeychainService.load()
        } catch {
            throw BackupError.keychainUnavailable
        }
        let directory = backupDirectoryURL(parentURL: parentURL)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BackupError.locationUnavailable("Could not prepare the backup folder.")
        }

        let sealed = try sealedArchive(passphrase: passphrase, modelContext: modelContext)

        // Skip unchanged libraries without writing or advancing the date.
        // Reaching here proves the location resolves, the Keychain reads,
        // and read/fingerprint are healthy, so a stale ORDINARY error is
        // now misleading: clear it. A retention warning is preserved
        // untouched (no write occurred, so retention could not have been
        // re-verified). lastHash/lastBackupDate/lastSnapshotFilename are
        // left alone. Dedupe requires BOTH a fingerprint match AND the
        // tracked snapshot still existing as a managed file (Task 16B):
        // a matching hash with a missing snapshot falls through to a
        // replacement write below.
        if !force, let storedHash = store.lastHash, storedHash == sealed.fingerprint,
            lastSuccessfulSnapshotExists(in: directory, store: store)
        {
            if let message = store.lastErrorMessage, !isRetentionWarning(message) {
                store.lastErrorMessage = nil
                store.save()
            }
            return .alreadyBackedUp
        }

        let destination = try writeArchive(sealed.archive, to: directory)

        store.lastHash = sealed.fingerprint
        store.lastSnapshotFilename = destination.lastPathComponent
        store.lastBackupDate = Date()
        store.lastErrorMessage = nil
        store.save()

        enforceRetention(keeping: destination, in: directory)
        return .backedUp(destination)
    }

    // MARK: - Missing-snapshot dedupe recovery (Task 16B)

    /// Returns true only when the tracked snapshot filename still identifies
    /// a managed snapshot in `directory`. Fail-closed: false on any
    /// uncertainty, without throwing or deleting anything.
    ///
    /// Requires ALL of: `store.lastSnapshotFilename` is non-nil/non-empty;
    /// the value is a safe filename only (no "/" or "\\" or NUL, not empty,
    /// ".", or "..", not absolute, and
    /// `URL(fileURLWithPath: name).lastPathComponent == name`); and the URL
    /// formed by resolving that filename inside `directory` still passes the
    /// existing `isManagedSnapshot` check (regular file, exact grammar,
    /// strict date round-trip, magic header). A malformed name returns false
    /// without touching the filesystem outside the backup folder.
    static func lastSuccessfulSnapshotExists(in directory: URL, store: BackupConfigurationStore) -> Bool {
        guard let name = store.lastSnapshotFilename, !name.isEmpty else {
            return false
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            return false
        }
        guard name != ".", name != ".." else {
            return false
        }
        guard !name.hasPrefix("/") else {
            return false
        }
        guard URL(fileURLWithPath: name).lastPathComponent == name else {
            return false
        }
        let candidate = directory.appendingPathComponent(name, isDirectory: false)
        guard candidate.lastPathComponent == name else {
            return false
        }
        return isManagedSnapshot(candidate)
    }

    // MARK: - setupFirstBackup

    /// Provisions a new backup location and writes the first snapshot.
    ///
    /// Always writes (`force` semantics) even when the fingerprint equals a
    /// previously stored hash. On success stores `isEnabled=true` plus the
    /// bookmark, display path, hash, snapshot filename, and date. On ANY failure removes the
    /// provisional configuration and Keychain item, remains Off, and throws;
    /// a snapshot file written before a later failure is left in place.
    @MainActor
    static func setupFirstBackup(parentURL: URL, passphrase: String, modelContext: ModelContext) throws -> URL {
        let store = BackupConfigurationStore.shared

        let bookmark: Data
        do {
            bookmark = try parentURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BackupError.locationUnavailable("Could not remember the selected folder.")
        }

        // Provisional configuration: Off until the first write verifies.
        store.bookmarkData = bookmark
        store.displayPath = parentURL.path
        store.isEnabled = false
        store.save()

        do {
            try BackupKeychainService.save(passphrase: passphrase)
        } catch {
            cleanupFailedSetup()
            throw BackupError.keychainUnavailable
        }

        do {
            let accessing = parentURL.startAccessingSecurityScopedResource()
            defer {
                if accessing { parentURL.stopAccessingSecurityScopedResource() }
            }
            let directory = backupDirectoryURL(parentURL: parentURL)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw BackupError.locationUnavailable("Could not prepare the backup folder.")
            }

            let sealed = try sealedArchive(passphrase: passphrase, modelContext: modelContext)
            let destination = try writeArchive(sealed.archive, to: directory)

            store.bookmarkData = bookmark
            store.displayPath = parentURL.path
            store.lastHash = sealed.fingerprint
            store.lastSnapshotFilename = destination.lastPathComponent
            store.lastBackupDate = Date()
            store.lastErrorMessage = nil
            store.isEnabled = true
            store.save()

            enforceRetention(keeping: destination, in: directory)
            return destination
        } catch let error as BackupError {
            cleanupFailedSetup()
            throw error
        } catch {
            cleanupFailedSetup()
            throw BackupError.writeFailed("Could not write the first backup.")
        }
    }

    // MARK: - changeLocation

    /// Moves future backups to a new folder, writing a snapshot there first.
    ///
    /// The existing configuration is left intact until the new snapshot is
    /// written and verified; only then are the stored bookmark, display
    /// path, hash, snapshot filename, and date replaced. Old backup files are never deleted.
    @MainActor
    static func changeLocation(newParentURL: URL, modelContext: ModelContext) throws -> URL {
        let store = BackupConfigurationStore.shared
        guard store.isEnabled, store.bookmarkData != nil else {
            throw BackupError.notConfigured
        }

        let passphrase: String
        do {
            passphrase = try BackupKeychainService.load()
        } catch {
            throw BackupError.keychainUnavailable
        }

        let newBookmark: Data
        do {
            newBookmark = try newParentURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BackupError.locationUnavailable("Could not remember the selected folder.")
        }

        let accessing = newParentURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { newParentURL.stopAccessingSecurityScopedResource() }
        }
        let directory = backupDirectoryURL(parentURL: newParentURL)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BackupError.locationUnavailable("Could not prepare the backup folder.")
        }

        // Everything below throws before the stored config is touched.
        let sealed = try sealedArchive(passphrase: passphrase, modelContext: modelContext)
        let destination = try writeArchive(sealed.archive, to: directory)

        store.bookmarkData = newBookmark
        store.displayPath = newParentURL.path
        store.lastHash = sealed.fingerprint
        store.lastSnapshotFilename = destination.lastPathComponent
        store.lastBackupDate = Date()
        store.lastErrorMessage = nil
        store.save()

        enforceRetention(keeping: destination, in: directory)
        return destination
    }

    // MARK: - disable

    /// Turns automatic backup off. Removes the stored bookmark, display
    /// path, hash, snapshot filename, date, and error, and deletes the Keychain item.
    /// Never deletes backup files. Throws without claiming a clean state
    /// when Keychain deletion fails.
    static func disable() throws {
        do {
            try BackupKeychainService.delete()
        } catch {
            throw BackupError.keychainUnavailable
        }
        BackupConfigurationStore.shared.clearAll()
    }

    // MARK: - Helpers

    /// Resolves the configured parent folder from its security-scoped
    /// bookmark. A stale or unresolvable bookmark throws `bookmarkStale`
    /// and preserves the stored configuration.
    static func resolveParentURL() throws -> URL {
        let store = BackupConfigurationStore.shared
        guard store.isEnabled, let bookmark = store.bookmarkData else {
            throw BackupError.notConfigured
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                throw BackupError.bookmarkStale
            }
            return url
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.bookmarkStale
        }
    }

    /// The managed backup folder inside a parent folder.
    static func backupDirectoryURL(parentURL: URL) -> URL {
        parentURL.appendingPathComponent(backupFolderName, isDirectory: true)
    }

    /// The managed backup folder inside the configured parent folder.
    static func backupDirectoryURL() throws -> URL {
        backupDirectoryURL(parentURL: try resolveParentURL())
    }

    /// Conservative ownership check for retention (Task 16A).
    ///
    /// Returns true ONLY when ALL hold; returns false on any uncertainty
    /// (fail-closed): a regular file (not a symlink, not a directory),
    /// an exact generated filename
    /// (`Promptdeck Backup YYYY-MM-DD HH-MM-SS.promptdeck` or
    /// `Promptdeck Backup YYYY-MM-DD HH-MM-SS -N.promptdeck` with N>=2 and
    /// no leading zeros, timestamp ranges enforced plus strict calendar
    /// validation via formatter round-trip), and a header beginning
    /// with `PromptdeckArchiveCodec.magic`. Never decrypts, never touches
    /// the Keychain.
    static func isManagedSnapshot(_ url: URL) -> Bool {
        // a. Regular file, not symlink, not directory. Check symlink first;
        // do NOT follow symlinks. Fail closed on any throw/nil.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else {
            return false
        }
        guard values.isSymbolicLink == false else {
            return false
        }
        guard values.isRegularFile == true, values.isDirectory == false else {
            return false
        }
        // b. Exact filename grammar, anchored and case-sensitive.
        let name = url.lastPathComponent
        guard Self.snapshotFilenameRegex.firstMatch(
            in: name,
            options: [],
            range: NSRange(name.startIndex..<name.endIndex, in: name)
        ) != nil else {
            return false
        }
        // b2. Strict calendar validation: the regex accepts impossible
        // dates (e.g. 2026-02-31), so extract the 19-char timestamp after
        // the prefix (collision ` -N` suffix already excluded by position)
        // and require an exact formatter round-trip. Fail closed.
        guard let stampStart = name.index(name.startIndex, offsetBy: filenamePrefix.count, limitedBy: name.endIndex),
            let stampEnd = name.index(stampStart, offsetBy: 19, limitedBy: name.endIndex)
        else {
            return false
        }
        let stamp = String(name[stampStart..<stampEnd])
        guard let date = Self.snapshotStampFormatter.date(from: stamp),
            Self.snapshotStampFormatter.string(from: date) == stamp
        else {
            return false
        }
        // c. Archive magic: header-only check, no decrypt/Keychain/PBKDF2.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }
        do {
            // `as Data?` keeps this compiling whether the SDK spells
            // `read(upToCount:)` as `throws -> Data` or `throws -> Data?`.
            guard let header = try handle.read(upToCount: PromptdeckArchiveCodec.magic.count) as Data?,
                header == PromptdeckArchiveCodec.magic
            else {
                return false
            }
        } catch {
            return false
        }
        return true
    }

    /// Anchored generated-filename grammar, compiled once. Timestamp ranges
    /// are plausible (month 01-12, day 01-31, hour 00-23, min/sec 00-59);
    /// the `-N` suffix allows only N>=2 with no leading zeros. Impossible
    /// calendar dates (e.g. Feb 31) pass this shape check and are rejected
    /// separately by strict formatter round-trip validation.
    private static let snapshotFilenameRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^Promptdeck Backup \\d{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01]) (?:[01][0-9]|2[0-3])-[0-5][0-9]-[0-5][0-9](?: -(?:[2-9]|[1-9][0-9]+))?\\.promptdeck$"
        )
    }()

    /// Strict stamp parser sharing `uniqueDestination`'s generator config
    /// (en_US_POSIX locale, `yyyy-MM-dd HH-mm-ss`, Gregorian calendar,
    /// default time zone) with leniency disabled. A parsed Date formatted
    /// back must equal the original text exactly; formatter normalization
    /// (Feb 30 -> Mar 02, etc.) therefore fails validation.
    private static let snapshotStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        formatter.isLenient = false
        return formatter
    }()

    /// Managed snapshots inside `directory`: only files passing the
    /// conservative `isManagedSnapshot` ownership check, sorted oldest
    /// first by creation date with the filename as fallback. Never throws;
    /// retention treats an unreadable folder as nothing to prune.
    static func listManagedSnapshots(in directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let managed = items.filter {
            Self.isManagedSnapshot($0)
        }
        return managed.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate < rhsDate
            default:
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
    }

    /// Managed snapshots inside the configured backup folder.
    static func listManagedSnapshots() -> [URL] {
        guard let directory = try? backupDirectoryURL() else {
            return []
        }
        return listManagedSnapshots(in: directory)
    }

    // MARK: - Private pipeline

    /// Captures the snapshot once, fingerprints it, and seals the canonical
    /// pair with one shared `exportedAt`. Maps infrastructure failures to
    /// user-facing errors without secrets, hashes, or passphrases.
    @MainActor
    private static func sealedArchive(
        passphrase: String,
        modelContext: ModelContext
    ) throws -> (archive: Data, fingerprint: String, exportedAt: Date) {
        let snapshot: BackupSnapshot
        do {
            snapshot = try BackupSnapshot.capture(modelContext: modelContext)
        } catch {
            throw BackupError.writeFailed("Could not read library data.")
        }
        let fingerprint: String
        do {
            fingerprint = try BackupFingerprint.hash(snapshot: snapshot)
        } catch {
            throw BackupError.writeFailed("Could not fingerprint library data.")
        }
        let exportedAt = Date()
        let pair: (promptsData: Data, commandsData: Data)
        do {
            pair = try snapshot.canonicalData(exportedAt: exportedAt)
        } catch {
            throw BackupError.writeFailed("Could not encode backup data.")
        }
        do {
            let archive = try PromptdeckArchiveCodec.seal(
                prompts: pair.promptsData,
                commands: pair.commandsData,
                passphrase: passphrase
            )
            return (archive: archive, fingerprint: fingerprint, exportedAt: exportedAt)
        } catch PromptdeckArchiveError.emptyPassphrase {
            throw BackupError.keychainUnavailable
        } catch {
            throw BackupError.writeFailed("Could not encrypt backup data.")
        }
    }

    /// Collision-safe destination: `Promptdeck Backup YYYY-MM-DD HH-MM-SS`
    /// plus `.promptdeck`, appending ` -N` while a file already exists.
    private static func uniqueDestination(in directory: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let stamp = formatter.string(from: now)
        var candidate = directory.appendingPathComponent("\(filenamePrefix)\(stamp).\(filenameExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(filenamePrefix)\(stamp) -\(counter).\(filenameExtension)")
            counter += 1
        }
        return candidate
    }

    /// Atomically writes the archive and verifies the file exists.
    /// Neither the hash nor the date may advance before this returns.
    private static func writeArchive(_ archive: Data, to directory: URL) throws -> URL {
        let destination = uniqueDestination(in: directory, now: Date())
        do {
            try archive.write(to: destination, options: .atomic)
        } catch {
            throw BackupError.writeFailed("Could not write the backup file.")
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw BackupError.writeFailed("Could not verify the backup file.")
        }
        return destination
    }

    /// Deletes the oldest managed snapshots so at most `maxSnapshots`
    /// remain. Only runs after a verified write; only touches files passing
    /// the conservative `isManagedSnapshot` ownership check, re-guarded
    /// immediately before deletion; never deletes `newURL`. A retention
    /// failure keeps the backup and records a warning instead of throwing
    /// the success away.
    private static func enforceRetention(keeping newURL: URL, in directory: URL) {
        let managed = listManagedSnapshots(in: directory).filter { $0 != newURL }
        let totalIncludingNew = managed.count + 1
        guard totalIncludingNew > maxSnapshots else {
            return
        }
        let overflow = totalIncludingNew - maxSnapshots
        var failed = false
        for url in managed.prefix(overflow) {
            // Defense-in-depth: re-guard ownership immediately before delete.
            guard Self.isManagedSnapshot(url) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failed = true
            }
        }
        if failed {
            let store = BackupConfigurationStore.shared
            store.lastErrorMessage = Self.retentionWarningMessage
            store.save()
        }
    }

    /// Removes provisional setup state and the Keychain item after a failed
    /// `setupFirstBackup`. Never touches backup files.
    @MainActor
    private static func cleanupFailedSetup() {
        BackupConfigurationStore.shared.clearAll()
        try? BackupKeychainService.delete()
    }
}

// MARK: - User-facing error messages (no secrets, hashes, or passphrases)

extension AutomaticBackupService.BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Automatic backup is not configured."
        case .keychainUnavailable:
            return "Could not access the backup passphrase in the Keychain."
        case .locationUnavailable(let detail):
            return "Backup location unavailable. \(detail)"
        case .bookmarkStale:
            return "The backup folder is no longer accessible. Choose the backup location again."
        case .writeFailed(let detail):
            return "Could not write backup. \(detail)"
        }
    }
}
