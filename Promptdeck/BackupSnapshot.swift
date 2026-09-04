import Foundation
import SwiftData

/// Single read-only capture of both libraries (Task 15A).
///
/// The DTO arrays are fetched, mapped, and UUID-sorted exactly once, then
/// reused for BOTH fingerprinting and canonical-JSON encoding so the two
/// never diverge and SwiftData is never mapped twice.
struct BackupSnapshot {
    var prompts: [PromptExportDTO]
    var commands: [CommandExportDTO]

    /// Captures both libraries read-only. Mutates nothing.
    @MainActor
    static func capture(modelContext: ModelContext) throws -> BackupSnapshot {
        let dtos = try ExportService.fetchSnapshotDTOs(modelContext: modelContext)
        return BackupSnapshot(prompts: dtos.prompts, commands: dtos.commands)
    }

    /// Builds the canonical encrypted-export document pair from these same
    /// DTOs with one shared `exportedAt`, reusing the exact manual-Export
    /// documents, encoder, and trailing newlines. Performs no disk writes.
    func canonicalData(exportedAt: Date) throws -> (promptsData: Data, commandsData: Data) {
        try ExportService.encodeCanonicalPair(prompts: prompts, commands: commands, exportedAt: exportedAt)
    }
}
