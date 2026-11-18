import CryptoKit
import Darwin
import Foundation

enum VoiceHistorySaveResult: Equatable {
    case saved, disabled, unavailable, encryptionFailed, writeFailed

    var messageKey: String {
        switch self {
        case .disabled: return "hist.saveDisabled"
        case .unavailable: return "hist.saveUnavailable"
        case .encryptionFailed, .writeFailed: return "hist.saveFailed"
        case .saved: return "hist.saveDone"
        }
    }
}

/// Holds the last verified snapshot. A failed write leaves both the snapshot and
/// cleanup eligibility unchanged.
struct VoiceHistoryArchive {
    private(set) var entries: [HistoryEntry] = []
    private(set) var unavailable = false
    private var ciphertext: Data?
    private var pendingCleanup: Set<String> = []

    private static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    mutating func load(from url: URL, keys: () -> [SymmetricKey]) -> SymmetricKey? {
        do {
            guard let data = try Self.read(url) else { return nil }
            let box = try AES.GCM.SealedBox(combined: data)
            for key in keys() {
                guard let plaintext = try? AES.GCM.open(box, using: key) else { continue }
                let decoded = try JSONDecoder().decode([HistoryEntry].self, from: plaintext)
                entries = decoded
                ciphertext = data
                return key
            }
        } catch {
            // An unreadable or malformed archive is never treated as an empty one.
        }
        unavailable = true
        return nil
    }

    mutating func commit(_ proposed: [HistoryEntry], to url: URL, key: () -> SymmetricKey?,
                         write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                         deleteClip: (String) -> Bool) -> VoiceHistorySaveResult {
        guard !unavailable else { return .unavailable }
        // Independent running instances must not pass the snapshot check at
        // the same time. A busy lock fails promptly and leaves the archive intact.
        let lockPath = url.appendingPathExtension("lock").path
        let lock = open(lockPath, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return .writeFailed }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return .writeFailed }
        do {
            guard try Self.read(url) == ciphertext else {
                unavailable = true
                return .unavailable
            }
        } catch { return .writeFailed }

        if proposed != entries {
            guard let key = key() else { return .unavailable }
            let sealed: Data
            do {
                let clear = try JSONEncoder().encode(proposed)
                guard let combined = try AES.GCM.seal(clear, using: key).combined else { return .encryptionFailed }
                sealed = combined
            } catch { return .encryptionFailed }
            do { try write(sealed, url) }
            catch { return .writeFailed }

            let retained = Set(proposed.compactMap(\.audio))
            pendingCleanup.formUnion(Set(entries.compactMap(\.audio)).subtracting(retained))
            pendingCleanup.subtract(retained)
            entries = proposed
            ciphertext = sealed
        }

        pendingCleanup = Set(pendingCleanup.filter { !deleteClip($0) })
        return .saved
    }
}
