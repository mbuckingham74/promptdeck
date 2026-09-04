import AppKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export DTOs (explicit; never encode SwiftData models directly)

struct PromptExportDTO: Codable {
    var id: UUID
    var title: String
    var body: String
    var tags: [String]
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastCopiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case tags
        case isFavorite
        case createdAt
        case updatedAt
        case lastCopiedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(tags, forKey: .tags)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        // Encode nil as explicit JSON null (not omitted).
        try container.encode(lastCopiedAt, forKey: .lastCopiedAt)
    }

    init(id: UUID, title: String, body: String, tags: [String], isFavorite: Bool, createdAt: Date, updatedAt: Date, lastCopiedAt: Date?) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCopiedAt = lastCopiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        tags = try container.decode([String].self, forKey: .tags)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastCopiedAt = try container.decodeIfPresent(Date.self, forKey: .lastCopiedAt)
    }
}

struct CommandExportDTO: Codable {
    var id: UUID
    var title: String
    var command: String
    var explanation: String
    var tags: [String]
    var platform: String
    var isDangerous: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastCopiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case command
        case explanation
        case tags
        case platform
        case isDangerous
        case isFavorite
        case createdAt
        case updatedAt
        case lastCopiedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(command, forKey: .command)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(tags, forKey: .tags)
        try container.encode(platform, forKey: .platform)
        try container.encode(isDangerous, forKey: .isDangerous)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        // Encode nil as explicit JSON null (not omitted).
        try container.encode(lastCopiedAt, forKey: .lastCopiedAt)
    }

    init(id: UUID, title: String, command: String, explanation: String, tags: [String], platform: String, isDangerous: Bool, isFavorite: Bool, createdAt: Date, updatedAt: Date, lastCopiedAt: Date?) {
        self.id = id
        self.title = title
        self.command = command
        self.explanation = explanation
        self.tags = tags
        self.platform = platform
        self.isDangerous = isDangerous
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCopiedAt = lastCopiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        command = try container.decode(String.self, forKey: .command)
        explanation = try container.decode(String.self, forKey: .explanation)
        tags = try container.decode([String].self, forKey: .tags)
        platform = try container.decode(String.self, forKey: .platform)
        isDangerous = try container.decode(Bool.self, forKey: .isDangerous)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastCopiedAt = try container.decodeIfPresent(Date.self, forKey: .lastCopiedAt)
    }
}

struct PromptLibraryDocument: Codable {
    var formatVersion: Int
    var library: String
    var exportedAt: Date
    var prompts: [PromptExportDTO]
}

struct CommandLibraryDocument: Codable {
    var formatVersion: Int
    var library: String
    var exportedAt: Date
    var commands: [CommandExportDTO]
}

enum ExportBuildError: Error {
    case fetchFailed(Error)
    case encodeFailed(Error)
}

// MARK: - Export service (encrypted .promptdeck export)

enum ExportService {
    /// Single ISO-8601 UTC format with sub-second precision, shared by
    /// every date field in both documents. A fresh formatter is built per
    /// call because ISO8601DateFormatter is not Sendable (Swift 6).
    private static func iso8601UTCString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601UTCString(from: date))
        }
        return encoder
    }

    private static func withTrailingNewline(_ data: Data) -> Data {
        guard data.last != 0x0A else { return data }
        var result = data
        result.append(0x0A)
        return result
    }

    /// Headless-backup helper (additive; manual Export path unchanged).
    /// Captures both libraries read-only, maps to DTOs, and UUID-sorts.
    /// Performs no disk writes.
    @MainActor
    static func fetchSnapshotDTOs(modelContext: ModelContext) throws -> (prompts: [PromptExportDTO], commands: [CommandExportDTO]) {
        // Snapshot both libraries read-only (independent of UI mode/search/selection).
        let promptEntries: [PromptEntry]
        let commandEntries: [CommandEntry]
        do {
            promptEntries = try modelContext.fetch(FetchDescriptor<PromptEntry>())
            commandEntries = try modelContext.fetch(FetchDescriptor<CommandEntry>())
        } catch {
            throw ExportBuildError.fetchFailed(error)
        }

        let promptDTOs = promptEntries
            .map { entry in
                PromptExportDTO(
                    id: entry.id,
                    title: entry.title,
                    body: entry.body,
                    tags: entry.tags,
                    isFavorite: entry.isFavorite,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    lastCopiedAt: entry.lastCopiedAt
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        let commandDTOs = commandEntries
            .map { entry in
                CommandExportDTO(
                    id: entry.id,
                    title: entry.title,
                    command: entry.command,
                    explanation: entry.explanation,
                    tags: entry.tags,
                    platform: entry.platform.rawValue,
                    isDangerous: entry.isDangerous,
                    isFavorite: entry.isFavorite,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    lastCopiedAt: entry.lastCopiedAt
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        return (prompts: promptDTOs, commands: commandDTOs)
    }

    /// Headless-backup helper (additive; manual Export path unchanged).
    /// Encodes an already-captured DTO pair with one shared exportedAt using
    /// the exact manual-Export documents, encoder, and trailing newlines.
    /// Performs no disk writes.
    static func encodeCanonicalPair(prompts: [PromptExportDTO], commands: [CommandExportDTO], exportedAt: Date) throws -> (promptsData: Data, commandsData: Data) {
        let promptDocument = PromptLibraryDocument(
            formatVersion: 1,
            library: "prompts",
            exportedAt: exportedAt,
            prompts: prompts
        )
        let commandDocument = CommandLibraryDocument(
            formatVersion: 1,
            library: "commands",
            exportedAt: exportedAt,
            commands: commands
        )

        // Pre-encode BOTH payloads in memory (no disk writes here).
        let encoder = makeEncoder()
        do {
            let promptsData = withTrailingNewline(try encoder.encode(promptDocument))
            let commandsData = withTrailingNewline(try encoder.encode(commandDocument))
            return (promptsData: promptsData, commandsData: commandsData)
        } catch {
            throw ExportBuildError.encodeFailed(error)
        }
    }

    /// Canonical in-memory JSON pair. Reuses DTOs, makeEncoder, the shared
    /// exportedAt timestamp, UUID sorting, and trailing newlines.
    /// Performs no disk writes.
    @MainActor
    static func buildCanonicalPair(modelContext: ModelContext) throws -> (promptsData: Data, commandsData: Data, exportedAt: Date) {
        let dtos = try fetchSnapshotDTOs(modelContext: modelContext)

        // Single shared exportedAt for both documents.
        let exportedAt = Date()

        let pair = try encodeCanonicalPair(prompts: dtos.prompts, commands: dtos.commands, exportedAt: exportedAt)
        return (promptsData: pair.promptsData, commandsData: pair.commandsData, exportedAt: exportedAt)
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

    @MainActor
    static func presentExportSuccess(fileName: String) {
        showAlert(style: .informational, title: "Export complete.", message: "Exported \(fileName).")
    }

    @MainActor
    static func presentExportFailure(_ error: Error) {
        let message: String
        if let buildError = error as? ExportBuildError {
            switch buildError {
            case .fetchFailed(let underlying):
                message = "Could not read libraries: \(underlying.localizedDescription)"
            case .encodeFailed(let underlying):
                message = "Could not encode export data: \(underlying.localizedDescription)"
            }
        } else if let archiveError = error as? PromptdeckArchiveError {
            switch archiveError {
            case .emptyPassphrase:
                message = "Enter a passphrase and confirm it."
            default:
                message = "Could not encrypt export data."
            }
        } else {
            message = "Could not write export file: \(error.localizedDescription)"
        }
        showAlert(style: .warning, title: "Export failed.", message: message)
    }

    /// Native macOS save panel for the single encrypted export.
    /// Returns the `.promptdeck` destination, or nil when cancelled.
    @MainActor
    static func exportDestinationURL() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Promptdeck Export.promptdeck"
        if let promptdeckType = UTType(filenameExtension: "promptdeck") {
            panel.allowedContentTypes = [promptdeckType]
        }
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Enforce the .promptdeck extension even if the user edited the name.
        if url.pathExtension.lowercased() == "promptdeck" {
            return url
        }
        return url.appendingPathExtension("promptdeck")
    }

    /// Snapshots SwiftData read-only, seals the canonical pair, and writes the
    /// archive atomically. Passphrase is used as exact UTF-8 bytes and never
    /// persisted (local only, no Keychain/UserDefaults/AppStorage/SwiftData).
    @MainActor
    static func writeEncryptedArchive(to destinationURL: URL, passphrase: String, modelContext: ModelContext) throws {
        let pair = try buildCanonicalPair(modelContext: modelContext)
        let archive = try PromptdeckArchiveCodec.seal(
            prompts: pair.promptsData,
            commands: pair.commandsData,
            passphrase: passphrase
        )
        let accessing = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { destinationURL.stopAccessingSecurityScopedResource() }
        }
        try archive.write(to: destinationURL, options: .atomic)
    }
}

// MARK: - Encrypted export passphrase sheet

/// Modal passphrase prompt: two SecureFields with inline validation.
/// Cancel writes/stores nothing; mismatch/empty shows an inline error and
/// never encrypts or writes. Passphrase lives in local @State only.
struct ExportPassphraseSheet: View {
    var fileName: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encrypt Export")
                .font(.headline)
            Text("Encrypting \(fileName). Enter a passphrase to protect this export.")
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
                Button("Export") {
                    // Exact comparison only: no trimming, no complexity rules.
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
        .frame(minWidth: 360)
    }
}
