import AppKit
import Foundation
import SwiftData
import SwiftUI

// MARK: - Import merge plan (validated, unapplied)

/// Fully validated import content. Produced by `prepareImport` without any
/// mutation; consumed by `applyImport`. Never persists passphrase or bytes.
struct ImportMergePlan {
    var newPrompts: [PromptExportDTO]
    var updatePrompts: [PromptExportDTO]
    var newCommands: [CommandExportDTO]
    var updateCommands: [CommandExportDTO]
    var exportedAt: Date

    var summaryMessage: String {
        "\(newPrompts.count) new Prompts · \(updatePrompts.count) updated\n" +
            "\(newCommands.count) new Commands · \(updateCommands.count) updated\n" +
            "Existing items not included in this export will remain unchanged."
    }
}

/// User-facing validation failures. Messages are intentionally generic and
/// concise; they never expose internals, paths, or crypto details.
enum ImportValidationError: Error {
    case invalidDocument
    case unsupportedVersion
    case mismatchedExportTimestamp
    case invalidPlatform
    case duplicateIdentifier
    case unreadableLibrary
}

extension ImportValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "This file is not a valid Promptdeck export."
        case .unsupportedVersion:
            return "This export uses an unsupported format version."
        case .mismatchedExportTimestamp:
            return "This file is not a valid Promptdeck export."
        case .invalidPlatform:
            return "This file contains an unsupported command platform."
        case .duplicateIdentifier:
            return "This file contains duplicate entries."
        case .unreadableLibrary:
            return "Could not read the local library."
        }
    }
}

enum ImportApplyError: Error {
    case lookupFailed(Error)
    case saveFailed(Error)
}

// MARK: - Import service (encrypted .promptdeck import + UUID merge)

enum ImportService {
    /// JSONDecoder mirroring `ExportService.makeEncoder()`: ISO-8601 UTC with
    /// fractional seconds. Any malformed date string throws (fails the import).
    static func makeImportDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date."
                )
            }
            return date
        }
        return decoder
    }

    /// Validates the decrypted JSON pair and computes new-vs-updated sets
    /// against the current store. Performs NO mutation.
    static func prepareImport(
        promptsData: Data,
        commandsData: Data,
        modelContext: ModelContext
    ) throws -> ImportMergePlan {
        let decoder = makeImportDecoder()
        let promptsDoc: PromptLibraryDocument
        let commandsDoc: CommandLibraryDocument
        do {
            promptsDoc = try decoder.decode(PromptLibraryDocument.self, from: promptsData)
            commandsDoc = try decoder.decode(CommandLibraryDocument.self, from: commandsData)
        } catch {
            throw ImportValidationError.invalidDocument
        }

        guard promptsDoc.formatVersion == 1, commandsDoc.formatVersion == 1 else {
            throw ImportValidationError.unsupportedVersion
        }
        guard promptsDoc.library == "prompts", commandsDoc.library == "commands" else {
            throw ImportValidationError.invalidDocument
        }
        // Both documents share one exportedAt instant; require exact equality
        // so a mismatched or spliced pair cannot merge.
        guard promptsDoc.exportedAt == commandsDoc.exportedAt else {
            throw ImportValidationError.mismatchedExportTimestamp
        }

        for dto in commandsDoc.commands {
            guard CommandPlatform(rawValue: dto.platform) != nil else {
                throw ImportValidationError.invalidPlatform
            }
        }

        // Duplicate UUIDs within a library are rejected. The same UUID
        // appearing once in each library is allowed (independent namespaces).
        let promptIDs = promptsDoc.prompts.map(\.id)
        guard Set(promptIDs).count == promptIDs.count else {
            throw ImportValidationError.duplicateIdentifier
        }
        let commandIDs = commandsDoc.commands.map(\.id)
        guard Set(commandIDs).count == commandIDs.count else {
            throw ImportValidationError.duplicateIdentifier
        }

        let localPrompts: [PromptEntry]
        let localCommands: [CommandEntry]
        do {
            localPrompts = try modelContext.fetch(FetchDescriptor<PromptEntry>())
            localCommands = try modelContext.fetch(FetchDescriptor<CommandEntry>())
        } catch {
            throw ImportValidationError.unreadableLibrary
        }
        let localPromptIDs = Set(localPrompts.map(\.id))
        let localCommandIDs = Set(localCommands.map(\.id))

        let newPrompts = promptsDoc.prompts.filter { !localPromptIDs.contains($0.id) }
        let updatePrompts = promptsDoc.prompts.filter { localPromptIDs.contains($0.id) }
        let newCommands = commandsDoc.commands.filter { !localCommandIDs.contains($0.id) }
        let updateCommands = commandsDoc.commands.filter { localCommandIDs.contains($0.id) }

        return ImportMergePlan(
            newPrompts: newPrompts,
            updatePrompts: updatePrompts,
            newCommands: newCommands,
            updateCommands: updateCommands,
            exportedAt: promptsDoc.exportedAt
        )
    }

    /// Stages the entire merge on a dedicated context (autosave disabled) and
    /// persists with a single `save()`. Existing objects are updated
    /// field-by-field with exact imported values (including timestamps);
    /// nothing is ever deleted and local-only items are untouched. On any
    /// failure nothing is saved and the caller reports "Import failed."
    static func applyImport(
        plan: ImportMergePlan,
        container: ModelContainer,
        mainContext: ModelContext
    ) throws {
        // Dedicated context so staging never touches the live UI context and
        // a single save() makes the merge all-or-nothing.
        let workContext = ModelContext(container)
        workContext.autosaveEnabled = false

        let existingPrompts: [PromptEntry]
        let existingCommands: [CommandEntry]
        do {
            existingPrompts = try workContext.fetch(FetchDescriptor<PromptEntry>())
            existingCommands = try workContext.fetch(FetchDescriptor<CommandEntry>())
        } catch {
            throw ImportApplyError.lookupFailed(error)
        }
        let promptsByID = Dictionary(uniqueKeysWithValues: existingPrompts.map { ($0.id, $0) })
        let commandsByID = Dictionary(uniqueKeysWithValues: existingCommands.map { ($0.id, $0) })

        for dto in plan.newPrompts {
            // Defensive: if the store changed between prepare and apply,
            // update the existing row instead of inserting a duplicate.
            if let existing = promptsByID[dto.id] {
                existing.title = dto.title
                existing.body = dto.body
                existing.tags = dto.tags
                existing.isFavorite = dto.isFavorite
                existing.createdAt = dto.createdAt
                existing.updatedAt = dto.updatedAt
                existing.lastCopiedAt = dto.lastCopiedAt
            } else {
                workContext.insert(PromptEntry(
                    id: dto.id,
                    title: dto.title,
                    body: dto.body,
                    tags: dto.tags,
                    isFavorite: dto.isFavorite,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    lastCopiedAt: dto.lastCopiedAt
                ))
            }
        }
        for dto in plan.updatePrompts {
            if let existing = promptsByID[dto.id] {
                existing.title = dto.title
                existing.body = dto.body
                existing.tags = dto.tags
                existing.isFavorite = dto.isFavorite
                existing.createdAt = dto.createdAt
                existing.updatedAt = dto.updatedAt
                existing.lastCopiedAt = dto.lastCopiedAt
            } else {
                workContext.insert(PromptEntry(
                    id: dto.id,
                    title: dto.title,
                    body: dto.body,
                    tags: dto.tags,
                    isFavorite: dto.isFavorite,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    lastCopiedAt: dto.lastCopiedAt
                ))
            }
        }

        for dto in plan.newCommands {
            // Platform was validated in prepareImport; fall back safely.
            let platform = CommandPlatform(rawValue: dto.platform) ?? .macOS
            if let existing = commandsByID[dto.id] {
                existing.title = dto.title
                existing.command = dto.command
                existing.explanation = dto.explanation
                existing.tags = dto.tags
                existing.platform = platform
                existing.isDangerous = dto.isDangerous
                existing.isFavorite = dto.isFavorite
                existing.createdAt = dto.createdAt
                existing.updatedAt = dto.updatedAt
                existing.lastCopiedAt = dto.lastCopiedAt
            } else {
                workContext.insert(CommandEntry(
                    id: dto.id,
                    title: dto.title,
                    command: dto.command,
                    explanation: dto.explanation,
                    tags: dto.tags,
                    platform: platform,
                    isDangerous: dto.isDangerous,
                    isFavorite: dto.isFavorite,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    lastCopiedAt: dto.lastCopiedAt
                ))
            }
        }
        for dto in plan.updateCommands {
            let platform = CommandPlatform(rawValue: dto.platform) ?? .macOS
            if let existing = commandsByID[dto.id] {
                existing.title = dto.title
                existing.command = dto.command
                existing.explanation = dto.explanation
                existing.tags = dto.tags
                existing.platform = platform
                existing.isDangerous = dto.isDangerous
                existing.isFavorite = dto.isFavorite
                existing.createdAt = dto.createdAt
                existing.updatedAt = dto.updatedAt
                existing.lastCopiedAt = dto.lastCopiedAt
            } else {
                workContext.insert(CommandEntry(
                    id: dto.id,
                    title: dto.title,
                    command: dto.command,
                    explanation: dto.explanation,
                    tags: dto.tags,
                    platform: platform,
                    isDangerous: dto.isDangerous,
                    isFavorite: dto.isFavorite,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    lastCopiedAt: dto.lastCopiedAt
                ))
            }
        }

        do {
            try workContext.save()
        } catch {
            throw ImportApplyError.saveFailed(error)
        }
        // No mainContext save is needed: SwiftData autosaves the main context
        // and both contexts share the same store, so @Query views refresh
        // automatically. The caller bumps resetNonce to clear search/selection
        // and refocus Search. Keep the mainContext parameter so callers pass
        // the live context explicitly (documents intent, no-op otherwise).
        _ = mainContext
    }

    /// Native macOS open panel for the single encrypted import. Returns the
    /// `.promptdeck` source, or nil when cancelled. No location is remembered.
    @MainActor
    static func importSourceURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["promptdeck"]
        panel.allowsOtherFileTypes = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    @MainActor
    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Crypto/container failures share one generic message: never distinguish
    /// wrong passphrase, corruption, or tampering.
    @MainActor
    static func presentImportPreparationFailure(_ error: Error) {
        if error is PromptdeckArchiveError {
            showAlert(
                style: .warning,
                title: "Unable to decrypt this Promptdeck file.",
                message: "Check the file and passphrase, then try again."
            )
            return
        }
        if let validation = error as? ImportValidationError {
            showAlert(
                style: .warning,
                title: "Unable to import this file.",
                message: validation.localizedDescription
            )
            return
        }
        showAlert(
            style: .warning,
            title: "Unable to import this file.",
            message: "This file is not a valid Promptdeck export."
        )
    }

    @MainActor
    static func presentImportReadFailure() {
        showAlert(
            style: .warning,
            title: "Import failed.",
            message: "Could not read the selected file."
        )
    }

    @MainActor
    static func presentImportFailure(_ error: Error) {
        let message: String
        if let validation = error as? ImportValidationError {
            message = validation.localizedDescription
        } else {
            message = "The library was left unchanged."
        }
        showAlert(style: .warning, title: "Import failed.", message: message)
    }

    @MainActor
    static func presentImportSuccess(plan: ImportMergePlan) {
        showAlert(
            style: .informational,
            title: "Import complete.",
            message: "\(plan.newPrompts.count) new Prompts · \(plan.updatePrompts.count) updated\n" +
                "\(plan.newCommands.count) new Commands · \(plan.updateCommands.count) updated"
        )
    }
}

// MARK: - Encrypted import passphrase sheet

/// Modal passphrase prompt: a single SecureField with inline validation.
/// Cancel discards everything; empty is rejected inline and never decrypts.
/// Passphrase lives in local @State only (never persisted).
struct ImportPassphraseSheet: View {
    var fileName: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @State private var passphrase = ""
    @State private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decrypt Import")
                .font(.headline)
            Text("Decrypting \(fileName). Enter the passphrase for this export.")
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $passphrase)
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
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Decrypt") {
                    // Exact text only: no trimming or normalization.
                    if passphrase.isEmpty {
                        inlineError = "Enter the passphrase for this export."
                        return
                    }
                    inlineError = nil
                    let confirmed = passphrase
                    passphrase = ""
                    onConfirm(confirmed)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
