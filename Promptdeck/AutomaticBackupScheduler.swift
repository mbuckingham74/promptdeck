import Foundation
import SwiftData

/// Change-triggered debounced backup scheduler (Tasks 15B + 15C).
///
/// Owned by the Promptdeck app lifecycle via the `shared` singleton.
/// No generic job framework, no daemons, no warning UI.
///
/// Semantics: every successful content mutation calls `contentDidChange()`,
/// which cancels any pending attempt and schedules a new backup 30 seconds
/// later. When the delay expires the scheduler re-checks that automatic
/// backup is still enabled and, if so, runs
/// `AutomaticBackupService.performBackup(modelContext:force:false)` with a
/// fresh `ModelContext` from `PromptdeckApp.sharedContainer`.
///
/// Task 15C adds two lightweight fallbacks that reuse the same silent
/// `runBackupIfEnabled()` path: a one-time per-process launch catch-up
/// (scheduled by the first `startLifecycle()` call) and a process-lifetime
/// daily check approximately every 24 hours. Both are no-ops while backup
/// is disabled, so enabling backup later in the same process still works.
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

    /// Fallback check interval while the process remains alive.
    static let dailyInterval: TimeInterval = 24 * 60 * 60

    private var pendingTask: Task<Void, Never>?
    private var lifecycleStarted = false
    private var dailyTask: Task<Void, Never>?

    private static var debounceNanoseconds: UInt64 {
        UInt64(debounceInterval * 1_000_000_000)
    }

    private static var dailyNanoseconds: UInt64 {
        UInt64(dailyInterval * 1_000_000_000)
    }

    /// Start process-lifetime fallback scheduling. Idempotent: only the
    /// first call schedules the launch catch-up and the daily loop;
    /// later calls (reactivation, window reappearance, Settings) do
    /// nothing. Intentionally does not check `isEnabled` here so the
    /// daily facility still exists if backup is enabled later.
    func startLifecycle() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        // Launch catch-up: prompt post-launch attempt on the next
        // MainActor turn so initial UI presentation is not delayed.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.runBackupIfEnabled()
        }
        // Daily fallback: sleep ~24h between silent `force: false` checks.
        dailyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.dailyNanoseconds)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                self.runBackupIfEnabled()
            }
        }
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
