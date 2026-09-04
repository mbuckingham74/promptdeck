import AppKit
import Foundation
import SwiftData

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

// MARK: - Export service (manual JSON export)

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
    private static func showError(_ message: String) {
        showAlert(style: .warning, title: "Export failed.", message: message)
    }

    /// Exports both libraries to prompts.json + commands.json in a user-chosen directory.
    @MainActor
    static func exportLibraries(modelContext: ModelContext) {
        // Fetch all records (independent of UI mode/search/selection). Read-only.
        let promptEntries: [PromptEntry]
        let commandEntries: [CommandEntry]
        do {
            promptEntries = try modelContext.fetch(FetchDescriptor<PromptEntry>())
            commandEntries = try modelContext.fetch(FetchDescriptor<CommandEntry>())
        } catch {
            showError("Could not read libraries: \(error.localizedDescription)")
            return
        }

        // Single shared exportedAt for both documents.
        let exportedAt = Date()

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

        let promptDocument = PromptLibraryDocument(
            formatVersion: 1,
            library: "prompts",
            exportedAt: exportedAt,
            prompts: promptDTOs
        )
        let commandDocument = CommandLibraryDocument(
            formatVersion: 1,
            library: "commands",
            exportedAt: exportedAt,
            commands: commandDTOs
        )

        // Pre-encode BOTH payloads before touching disk.
        let encoder = makeEncoder()
        let promptsData: Data
        let commandsData: Data
        do {
            promptsData = withTrailingNewline(try encoder.encode(promptDocument))
            commandsData = withTrailingNewline(try encoder.encode(commandDocument))
        } catch {
            showError("Could not encode export data: \(error.localizedDescription)")
            return
        }

        // Native macOS folder picker.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

        let accessing = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { directoryURL.stopAccessingSecurityScopedResource() }
        }

        let promptsURL = directoryURL.appendingPathComponent("prompts.json")
        let commandsURL = directoryURL.appendingPathComponent("commands.json")
        let fileManager = FileManager.default
        let promptsExists = fileManager.fileExists(atPath: promptsURL.path)
        let commandsExists = fileManager.fileExists(atPath: commandsURL.path)

        // Overwrite confirmation when either target already exists.
        if promptsExists || commandsExists {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "Replace existing export files?"
            confirm.informativeText = "Existing Promptdeck export files (prompts.json, commands.json) in this folder will be replaced."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        // Atomic writes (only after both encodings succeeded).
        do {
            try promptsData.write(to: promptsURL, options: .atomic)
            try commandsData.write(to: commandsURL, options: .atomic)
        } catch {
            showError("Could not write export files: \(error.localizedDescription)")
            return
        }

        showAlert(style: .informational, title: "Export complete.", message: "Exported prompts.json and commands.json.")
    }
}
