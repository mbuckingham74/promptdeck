import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Encrypted `.promptdeck` archive codec (Task 14A).
///
/// Layout (all integers big-endian):
///   magic (8B, "PDECKENC") | version UInt16 (=1) | headerLen UInt32 |
///   header (UTF-8 JSON, sorted keys) | ciphertext | GCM tag (16B)
///
/// Header JSON keys (sorted): cipher, containerVersion, iterations, kdf,
/// nonce (base64), payloadFormat, salt (base64).
///
/// AAD = magicBytes + versionBytes + headerLenBytes + exactHeaderBytes.
/// Inner plaintext = BE32 len + prompts.json bytes + BE32 len + commands.json bytes.
///
/// Reusable for future Import: `open` returns the canonical JSON pair without
/// touching SwiftData. No Import UI here.
enum PromptdeckArchiveCodec {
    static let magic = Data("PDECKENC".utf8)
    static let archiveVersion: UInt16 = 1
    static let keyByteCount = 32
    static let saltByteCount = 16
    static let iterations = 600_000

    private static let cipherName = "AES-256-GCM"
    private static let kdfName = "PBKDF2-HMAC-SHA256"
    private static let payloadFormat = "promptdeck-json-pair-v1"
    private static let containerVersion = 1

    struct ArchiveHeader: Codable {
        var cipher: String
        var containerVersion: Int
        var iterations: Int
        var kdf: String
        var nonce: String
        var payloadFormat: String
        var salt: String
    }

    private static func bigEndianBytes(_ value: UInt16) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt16>.size)
    }

    private static func bigEndianBytes(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt32>.size)
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset]) << 8
        let b1 = UInt16(data[offset + 1])
        return b0 | b1
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset]) << 24
        let b1 = UInt32(data[offset + 1]) << 16
        let b2 = UInt32(data[offset + 2]) << 8
        let b3 = UInt32(data[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltByteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PromptdeckArchiveError.sealingFailed
        }
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto. Uses exact UTF-8 bytes of the
    /// passphrase (no trimming or normalization).
    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> Data {
        let passwordBytes = Array(passphrase.utf8)
        guard !passwordBytes.isEmpty else {
            throw PromptdeckArchiveError.emptyPassphrase
        }
        guard iterations > 0, iterations <= 10_000_000 else {
            throw PromptdeckArchiveError.invalidArchive
        }
        var derived = [UInt8](repeating: 0, count: keyByteCount)
        let status: Int32 = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltRaw in
                derived.withUnsafeMutableBufferPointer { derivedBuffer in
                    guard
                        let passwordBase = passwordBuffer.baseAddress,
                        let saltBase = saltRaw.baseAddress,
                        let derivedBase = derivedBuffer.baseAddress
                    else { return Int32(kCCParamError) }
                    let passwordPtr = UnsafeRawPointer(passwordBase).assumingMemoryBound(to: CChar.self)
                    let saltPtr = UnsafeRawPointer(saltBase).assumingMemoryBound(to: UInt8.self)
                    let derivedPtr = UnsafeMutableRawPointer(derivedBase).assumingMemoryBound(to: UInt8.self)
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        passwordBytes.count,
                        saltPtr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr,
                        keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PromptdeckArchiveError.keyDerivationFailed
        }
        return Data(derived)
    }

    private static func innerPlaintext(prompts: Data, commands: Data) -> Data {
        var out = Data()
        out.append(bigEndianBytes(UInt32(prompts.count)))
        out.append(prompts)
        out.append(bigEndianBytes(UInt32(commands.count)))
        out.append(commands)
        return out
    }

    /// Seals the canonical JSON pair into an encrypted archive.
    static func seal(prompts: Data, commands: Data, passphrase: String) throws -> Data {
        let passwordBytes = Array(passphrase.utf8)
        guard !passwordBytes.isEmpty else {
            throw PromptdeckArchiveError.emptyPassphrase
        }
        let salt = try randomSalt()
        let keyBytes = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce = AES.GCM.Nonce()
        let nonceData = Data(nonce.withUnsafeBytes { Data($0) })

        let header = ArchiveHeader(
            cipher: cipherName,
            containerVersion: containerVersion,
            iterations: iterations,
            kdf: kdfName,
            nonce: nonceData.base64EncodedString(),
            payloadFormat: payloadFormat,
            salt: salt.base64EncodedString()
        )
        let headerEncoder = JSONEncoder()
        headerEncoder.outputFormatting = [.sortedKeys]
        let headerBytes = try headerEncoder.encode(header)

        let versionBytes = bigEndianBytes(archiveVersion)
        let headerLenBytes = bigEndianBytes(UInt32(headerBytes.count))

        var aad = Data()
        aad.append(magic)
        aad.append(versionBytes)
        aad.append(headerLenBytes)
        aad.append(headerBytes)

        let plaintext = innerPlaintext(prompts: prompts, commands: commands)
        let key = SymmetricKey(data: keyBytes)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        } catch {
            throw PromptdeckArchiveError.sealingFailed
        }

        var archive = Data()
        archive.append(aad)
        archive.append(sealedBox.ciphertext)
        archive.append(sealedBox.tag)
        return archive
    }

    /// Opens an encrypted archive. Throws a generic `decryptionFailed` for any
    /// wrong-passphrase or authentication failure, and returns no plaintext on
    /// failure.
    static func open(archive: Data, passphrase: String) throws -> (promptsData: Data, commandsData: Data) {
        // Minimum: magic(8) + version(2) + headerLen(4) + tag(16).
        guard archive.count >= 30 else {
            throw PromptdeckArchiveError.invalidArchive
        }
        guard archive.prefix(8) == magic else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let version = readUInt16BE(archive, at: 8)
        guard version == archiveVersion else {
            throw PromptdeckArchiveError.unsupportedVersion
        }
        let headerLength = Int(readUInt32BE(archive, at: 10))
        guard headerLength > 0 else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let headerEnd = 14 + headerLength
        // Header must fit with at least the 16B tag remaining.
        guard headerEnd + 16 <= archive.count else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let headerBytes = archive.subdata(in: 14 ..< headerEnd)
        let aad = archive.subdata(in: 0 ..< headerEnd)

        let header: ArchiveHeader
        do {
            header = try JSONDecoder().decode(ArchiveHeader.self, from: headerBytes)
        } catch {
            throw PromptdeckArchiveError.invalidArchive
        }
        guard header.cipher == cipherName,
              header.kdf == kdfName,
              header.payloadFormat == payloadFormat
        else {
            throw PromptdeckArchiveError.invalidArchive
        }
        guard header.containerVersion == containerVersion else {
            throw PromptdeckArchiveError.unsupportedVersion
        }
        guard let salt = Data(base64Encoded: header.salt),
              let nonceData = Data(base64Encoded: header.nonce),
              salt.count == saltByteCount,
              nonceData.count == 12
        else {
            throw PromptdeckArchiveError.invalidArchive
        }

        let keyBytes: Data
        do {
            keyBytes = try deriveKey(passphrase: passphrase, salt: salt, iterations: header.iterations)
        } catch PromptdeckArchiveError.emptyPassphrase {
            // Never distinguish passphrase problems: generic decrypt failure.
            throw PromptdeckArchiveError.decryptionFailed
        } catch {
            throw PromptdeckArchiveError.decryptionFailed
        }

        let tagStart = archive.count - 16
        let ciphertext = archive.subdata(in: headerEnd ..< tagStart)
        let tag = archive.subdata(in: tagStart ..< archive.count)

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw PromptdeckArchiveError.invalidArchive
        }

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: aad)
        } catch {
            // Generic error for wrong passphrase, tampering, or AAD mismatch.
            throw PromptdeckArchiveError.decryptionFailed
        }

        // Inner framing: BE32 len + prompts + BE32 len + commands, exact fit.
        guard plaintext.count >= 8 else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let promptsLength = Int(readUInt32BE(plaintext, at: 0))
        guard promptsLength >= 0, 4 + promptsLength + 4 <= plaintext.count else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let commandsLengthOffset = 4 + promptsLength
        let commandsLength = Int(readUInt32BE(plaintext, at: commandsLengthOffset))
        let commandsStart = commandsLengthOffset + 4
        guard commandsLength >= 0, commandsStart + commandsLength == plaintext.count else {
            throw PromptdeckArchiveError.invalidArchive
        }
        let promptsData = plaintext.subdata(in: 4 ..< (4 + promptsLength))
        let commandsData = plaintext.subdata(in: commandsStart ..< (commandsStart + commandsLength))
        return (promptsData: promptsData, commandsData: commandsData)
    }
}

enum PromptdeckArchiveError: Error {
    case invalidArchive
    case unsupportedVersion
    case decryptionFailed
    case emptyPassphrase
    case sealingFailed
    case keyDerivationFailed
}
