import Combine
import Foundation
import SwiftData

/// Change-triggered debounced backup scheduler (Tasks 15B + 15C + 15D).
///
/// Owned by the Promptdeck app lifecycle via the `shared` singleton.
/// No generic job framework, no daemons, no notification framework.
///
/// Semantics: every successful content mutation calls `contentDidChange()`,
/// which cancels any pending attempt and schedules a new backup 30 seconds
/// later. When the delay expires the scheduler re-checks that automatic
/// backup is still enabled and, if so, runs
/// `AutomaticBackupService.performBackup(modelContext:force:false)` with a
/// fresh `ModelContext` from `PromptdeckApp.sharedContainer`.
///
/// Task 15C adds two lightweight fallbacks that reuse the same
/// `runBackupIfEnabled()` path: a one-time per-process launch catch-up
/// (scheduled by the first `startLifecycle()` call) and a process-lifetime
/// daily check approximately every 24 hours. Both are no-ops while backup
/// is disabled, so enabling backup later in the same process still works.
///
/// Task 15D warning policy (one transient warning per process, silent
/// otherwise): after every scheduler attempt, if backup is still enabled
/// and `lastErrorMessage` is non-nil/non-empty, the scheduler requests the
/// global warning once per process via `requestWarningOnce()`. Retries
/// (debounce / launch catch-up / daily) are untouched and keep running;
/// dismissal resolves nothing and clears no store state.
@MainActor
final class AutomaticBackupScheduler: ObservableObject {
    static let shared = AutomaticBackupScheduler()

    /// Debounce window between the last mutation and the backup attempt.
    static let debounceInterval: TimeInterval = 30.0

    /// Fallback check interval while the process remains alive.
    static let dailyInterval: TimeInterval = 24 * 60 * 60

    private var pendingTask: Task<Void, Never>?
    private var lifecycleStarted = false
    private var dailyTask: Task<Void, Never>?

    /// Task 15D: transient one-shot warning state. In-memory only, never
    /// persisted to UserDefaults. `didRequestBackupWarning` gates at most
    /// one presentation per process; `dismissWarning()` hides the alert
    /// without clearing it, and view recreation / hide / reactivation /
    /// Settings opening cannot reset the allowance (state lives here).
    @Published var showsBackupWarning = false
    private var didRequestBackupWarning = false

    /// Requests the global warning at most once per process. UI only: never
    /// gates or skips backup attempts.
    private func requestWarningOnce() {
        if didRequestBackupWarning { return }
        didRequestBackupWarning = true
        showsBackupWarning = true
    }

    /// Hides the warning. Clears nothing else: not `lastErrorMessage`,
    /// health, config, or retries.
    func dismissWarning() {
        showsBackupWarning = false
    }

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
    /// Also hides a visible warning for hygiene, but keeps the one-shot
    /// suppression flag (still max one warning per process).
    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        showsBackupWarning = false
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
        // Task 15D single post-attempt check (success AND failure paths).
        // Covers: an ordinary failure just stored above; a retention
        // warning just set inside performBackup's enforceRetention on a
        // .backedUp success; and a pre-existing persisted error still
        // unresolved after a launch .alreadyBackedUp health check. A
        // success that cleared the error leaves nil, so no warning.
        if store.isEnabled,
           let message = store.lastErrorMessage,
           !message.isEmpty {
            requestWarningOnce()
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
