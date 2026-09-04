import CryptoKit
import Foundation

/// Change-detection document for automatic backups (Task 15A).
///
/// `exportedAt` is deliberately excluded: two snapshots of identical
/// library content must hash identically regardless of when they were
/// taken. Every persistent field is covered via the export DTOs
/// (including `lastCopiedAt` as explicit null when nil, and tags exactly
/// as stored).
struct BackupFingerprintDocument: Codable {
    var fingerprintVersion: Int = 1
    var prompts: [PromptExportDTO]
    var commands: [CommandExportDTO]
}

/// Deterministic library fingerprint used to skip unchanged backups.
enum BackupFingerprint {
    /// Sorts DTOs by `id.uuidString`, encodes with
    /// `ExportService.makeEncoder()` (sorted keys + shared date strategy),
    /// and returns the SHA-256 digest as lowercase hex.
    static func hash(prompts: [PromptExportDTO], commands: [CommandExportDTO]) throws -> String {
        let document = BackupFingerprintDocument(
            fingerprintVersion: 1,
            prompts: prompts.sorted { $0.id.uuidString < $1.id.uuidString },
            commands: commands.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try ExportService.makeEncoder().encode(document)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience overload for an already-captured snapshot.
    static func hash(snapshot: BackupSnapshot) throws -> String {
        try hash(prompts: snapshot.prompts, commands: snapshot.commands)
    }
}
