import Foundation
import SwiftData

/// Change-triggered debounced backup scheduler (Task 15B).
///
/// Owned by the Promptdeck app lifecycle via the `shared` singleton.
/// No generic job framework, no timers, no daemons, no launch catch-up,
/// no daily fallback, no warning UI.
///
/// Semantics: every successful content mutation calls `contentDidChange()`,
/// which cancels any pending attempt and schedules a new backup 30 seconds
/// later. When the delay expires the scheduler re-checks that automatic
/// backup is still enabled and, if so, runs
/// `AutomaticBackupService.performBackup(modelContext:force:false)` with a
/// fresh `ModelContext` from `PromptdeckApp.sharedContainer`.
///
/// Results are silent: `.backedUp` / `.alreadyBackedUp` do nothing further
/// (the success path already clears the stored error via Task 15A). On
/// throw, `lastHash` / `lastBackupDate` are left untouched and a concise
/// non-secret message is stored in `lastErrorMessage` + `save()` so
/// Settings reflects the unhealthy state. No modal or alert is ever shown.
@MainActor
final class AutomaticBackupScheduler {
    static let shared = AutomaticBackupScheduler()

    /// Debounce window between the last mutation and the backup attempt.
    static let debounceInterval: TimeInterval = 30.0

    private var pendingTask: Task<Void, Never>?

    private static var debounceNanoseconds: UInt64 {
        UInt64(debounceInterval * 1_000_000_000)
    }

    /// Record a successful content mutation. Cancels any pending attempt
    /// and schedules a new one `debounceInterval` later. No-op while
    /// automatic backup is disabled (fire-time check still re-verifies).
    func contentDidChange() {
        let store = BackupConfigurationStore.shared
        guard store.isEnabled, store.bookmarkData != nil else {
            return
        }
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            } catch {
                // Cancellation (a newer mutation superseded us): silent.
                return
            }
            guard !Task.isCancelled else { return }
            // Clear before firing so mutations during the write start a
            // fresh window instead of being wiped by a trailing nil.
            self.pendingTask = nil
            self.runBackupIfEnabled()
        }
    }

    /// Drop any pending attempt. Used when automatic backup is turned off.
    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func runBackupIfEnabled() {
        let store = BackupConfigurationStore.shared
        guard store.isEnabled, store.bookmarkData != nil else {
            return
        }
        do {
            let modelContext = ModelContext(PromptdeckApp.sharedContainer)
            let outcome = try AutomaticBackupService.performBackup(
                modelContext: modelContext,
                force: false
            )
            switch outcome {
            case .backedUp, .alreadyBackedUp:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            // Preserve lastHash/lastBackupDate; record a concise
            // non-secret error so Settings reflects the unhealthy state.
            store.lastErrorMessage = Self.message(for: error)
            store.save()
        }
    }

    /// Short user-facing string without secrets, hashes, or passphrases.
    private static func message(for error: Error) -> String {
        if let backupError = error as? AutomaticBackupService.BackupError {
            return backupError.localizedDescription
        }
        return "Could not write backup."
    }
}
