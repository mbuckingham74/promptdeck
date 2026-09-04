import AppKit
import Foundation
import SwiftData
import SwiftUI

/// Settings UI for automatic backup (Task 15A).
///
/// One small native section. Observes `BackupConfigurationStore.shared`.
/// Files are created only by setup / change-location / Back Up Now;
/// there is no scheduling, timer, or launch catch-up here.
struct BackupSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var store = BackupConfigurationStore.shared

    @State private var notice: String?
    @State private var actionError: String?
    @State private var pendingParentURL: URL?
    @State private var showingPassphraseSheet = false
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Automatic Backup") {
                if store.isEnabled {
                    enabledContent
                } else {
                    disabledContent
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
        .sheet(isPresented: $showingPassphraseSheet) {
            BackupPassphraseSheet(
                onConfirm: { passphrase in
                    showingPassphraseSheet = false
                    let parent = pendingParentURL
                    pendingParentURL = nil
                    if let parent {
                        runSetup(parentURL: parent, passphrase: passphrase)
                    }
                },
                onCancel: {
                    showingPassphraseSheet = false
                    pendingParentURL = nil
                }
            )
        }
    }

    // MARK: - Off state

    private var disabledContent: some View {
        Group {
            Text("Automatic Backup: Off")
                .font(.headline)
            Text("Recommended: choose a backup location on a different physical drive or in a synced/network location. A local folder is still supported and is better than no backup.")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Set Up Automatic Backup…") {
                pickFolderForSetup()
            }
            .disabled(isWorking)
            if let actionError {
                Text(actionError)
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: - On state

    private var enabledContent: some View {
        Group {
            Text("Automatic Backup: On")
                .font(.headline)
            LabeledContent("Backup location") {
                Text(store.displayPath ?? "Unknown location")
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Last successful backup") {
                Text(lastBackupText)
                    .multilineTextAlignment(.trailing)
            }
            if let storedErrorText {
                Text(storedErrorText)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if let notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if let actionError {
                Text(actionError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button("Back Up Now") {
                    backUpNow()
                }
                .disabled(isWorking)
                Button("Change Location…") {
                    pickFolderForChange()
                }
                .disabled(isWorking)
            }
            Button("Turn Automatic Backup Off", role: .destructive) {
                turnOff()
            }
            .disabled(isWorking)
            Text("Turning off removes the saved settings and passphrase. Backup files are kept.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var lastBackupText: String {
        guard let date = store.lastBackupDate else {
            return "Never"
        }
        return Self.backupDateFormatter.string(from: date)
    }

    /// Stored engine warning, mapped to the required wording.
    private var storedErrorText: String? {
        guard let message = store.lastErrorMessage, !message.isEmpty else {
            return nil
        }
        if message.localizedCaseInsensitiveContains("removing old snapshots") {
            return "Retention cleanup failed. \(message)"
        }
        return message
    }

    // MARK: - Folder picking

    @MainActor
    private func parentFolderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel
    }

    @MainActor
    private func pickFolderForSetup() {
        actionError = nil
        let panel = parentFolderPanel()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        pendingParentURL = url
        showingPassphraseSheet = true
    }

    @MainActor
    private func pickFolderForChange() {
        let panel = parentFolderPanel()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        changeLocation(newParentURL: url)
    }

    // MARK: - Engine actions

    @MainActor
    private func runSetup(parentURL: URL, passphrase: String) {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try AutomaticBackupService.setupFirstBackup(
                parentURL: parentURL,
                passphrase: passphrase,
                modelContext: modelContext
            )
            notice = "Automatic Backup Enabled"
            actionError = nil
        } catch {
            actionError = backupFailureMessage(error)
        }
    }

    @MainActor
    private func backUpNow() {
        guard store.isEnabled else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try AutomaticBackupService.performBackup(modelContext: modelContext, force: false)
            switch outcome {
            case .backedUp:
                notice = "Backed up"
                actionError = nil
            case .alreadyBackedUp:
                notice = "Already backed up."
                actionError = nil
            }
        } catch {
            notice = nil
            actionError = backupFailureMessage(error)
        }
    }

    @MainActor
    private func changeLocation(newParentURL: URL) {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try AutomaticBackupService.changeLocation(
                newParentURL: newParentURL,
                modelContext: modelContext
            )
            notice = "Backed up"
            actionError = nil
        } catch {
            actionError = backupFailureMessage(error)
        }
    }

    @MainActor
    private func turnOff() {
        isWorking = true
        defer { isWorking = false }
        do {
            try AutomaticBackupService.disable()
            AutomaticBackupScheduler.shared.cancelPending()
            notice = nil
            actionError = nil
        } catch {
            actionError = backupFailureMessage(error)
        }
    }

    /// Maps engine errors to concise strings. Never exposes secrets or hashes.
    private func backupFailureMessage(_ error: Error) -> String {
        if let backupError = error as? AutomaticBackupService.BackupError {
            switch backupError {
            case .keychainUnavailable:
                return "Keychain passphrase unavailable. \(backupError.localizedDescription)"
            case .locationUnavailable, .bookmarkStale:
                return "Backup location unavailable. \(backupError.localizedDescription)"
            case .notConfigured:
                return "Backup failed. \(backupError.localizedDescription)"
            case .writeFailed:
                return "Backup failed. \(backupError.localizedDescription)"
            }
        }
        if error is BackupKeychainError {
            return "Keychain passphrase unavailable. \(error.localizedDescription)"
        }
        return "Backup failed. \(error.localizedDescription)"
    }
}

/// Passphrase sheet for first-time setup.
///
/// Two secure fields with exact comparison only. Empty or mismatched
/// entries show an inline error and write nothing. Cancel writes nothing.
struct BackupPassphraseSheet: View {
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Backup Passphrase")
                .font(.headline)
            Text("Choose a passphrase to protect automatic backups. You will not be asked for it again on this Mac.")
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm passphrase", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if let inlineError {
                Text(inlineError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    passphrase = ""
                    confirmation = ""
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Enable Backup") {
                    if passphrase.isEmpty || confirmation.isEmpty {
                        inlineError = "Enter a passphrase and confirm it."
                        return
                    }
                    if passphrase != confirmation {
                        inlineError = "Passphrases do not match."
                        return
                    }
                    inlineError = nil
                    let confirmed = passphrase
                    passphrase = ""
                    confirmation = ""
                    onConfirm(confirmed)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 380)
    }
}
