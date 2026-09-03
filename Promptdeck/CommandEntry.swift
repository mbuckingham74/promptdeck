import Foundation
import SwiftData

enum CommandPlatform: String, Codable {
    case macOS
    case Linux
    case Both
}

@Model
final class CommandEntry {
    var id: UUID
    var title: String
    var command: String
    var explanation: String
    var tags: [String]
    var platform: CommandPlatform
    var isDangerous: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastCopiedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        command: String = "",
        explanation: String = "",
        tags: [String] = [],
        platform: CommandPlatform = .macOS,
        isDangerous: Bool = false,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCopiedAt: Date? = nil
    ) {
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
}
