// Clipboard transfer format v1. Keep this file identical in Keyboop and SelectionBar.
import CommonCrypto
import CryptoKit
import Foundation
import Security

enum ClipboardTransfer {
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumEntries = 500
    private static let magic = Data("KBCLIP\u{01}".utf8)
    private static let saltBytes = 16

    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let text: String
        let createdAt: Date
        let app: String?
        let ordinal: Int
    }

    struct Payload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let exportedAt: Date
        let sourceApplication: String
        let sourceVersion: String
        let entries: [Entry]
    }

    enum Failure: Error, Equatable { case password, format, size, authentication, invalidEntries, crypto }

    static func seal(_ payload: Payload, password: String) throws -> Data {
        try validate(payload)
        let clear = try JSONEncoder().encode(payload)
        guard clear.count <= maximumFileBytes - 64 else { throw Failure.size }
        var salt = Data(count: saltBytes)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltBytes, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.crypto }
        let header = magic + salt
        let key = try derive(password, salt: salt)
        guard let combined = try AES.GCM.seal(clear, using: key, authenticating: header).combined else { throw Failure.crypto }
        return header + combined
    }

    static func open(_ data: Data, password: String) throws -> Payload {
        guard data.count <= maximumFileBytes else { throw Failure.size }
        let headerSize = magic.count + saltBytes
        guard data.count >= headerSize + 28, data.starts(with: magic) else { throw Failure.format }
        let header = Data(data.prefix(headerSize))
        let key = try derive(password, salt: Data(header.suffix(saltBytes)))
        let clear: Data
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(headerSize)))
            clear = try AES.GCM.open(box, using: key, authenticating: header)
        } catch { throw Failure.authentication }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: clear) else { throw Failure.format }
        try validate(payload)
        return payload
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumFileBytes {
            guard let chunk = try handle.read(upToCount: min(64 * 1024, maximumFileBytes + 1 - data.count)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw Failure.size
    }

    static func stableID(text: String, date: Date, app: String?) throws -> UUID {
        // Date bit pattern and app disambiguate repeated clipboard text. The caller
        // folds a per-identity occurrence into the ID for otherwise identical rows.
        struct Identity: Encodable {
            let text: String
            let date: UInt64
            let app: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(Identity(text: text, date: date.timeIntervalSinceReferenceDate.bitPattern, app: app))
        return uuid(SHA256.hash(data: bytes))
    }

    static func occurrenceID(_ id: UUID, occurrence: Int) -> UUID {
        uuid(SHA256.hash(data: Data("\(id.uuidString):\(occurrence)".utf8)))
    }

    private static func uuid(_ digest: SHA256.Digest) -> UUID {
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0f) | 0x80
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func validate(_ payload: Payload) throws {
        guard payload.schemaVersion == 1, payload.sourceApplication == "Keyboop",
              payload.sourceVersion.utf8.count <= 100, payload.exportedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw Failure.format }
        guard payload.entries.count <= maximumEntries,
              Set(payload.entries.map(\.id)).count == payload.entries.count,
              payload.entries.enumerated().allSatisfy({ index, entry in
                  entry.ordinal == index && entry.text.utf8.count <= 80_000 &&
                  !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  entry.createdAt >= Date(timeIntervalSince1970: 0) &&
                  entry.createdAt <= payload.exportedAt.addingTimeInterval(300) &&
                  (entry.app?.utf8.count ?? 0) <= 1024
              }) else { throw Failure.invalidEntries }
    }

    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        guard (12...1024).contains(bytes.count) else { throw Failure.password }
        var derived = Data(count: 32)
        let result = derived.withUnsafeMutableBytes { output in
            bytes.withUnsafeBytes { pass in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!.assumingMemoryBound(to: Int8.self),
                        pass.count, saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard result == kCCSuccess else { throw Failure.crypto }
        return SymmetricKey(data: derived)
    }
}
