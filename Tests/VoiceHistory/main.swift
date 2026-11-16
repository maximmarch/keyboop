import CryptoKit
import Darwin
import Foundation

let fs = FileManager.default
let directory = fs.temporaryDirectory.appendingPathComponent("kb-history-tests-\(UUID())", isDirectory: true)
try fs.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fs.removeItem(at: directory) }

let archiveURL = directory.appendingPathComponent("history.enc")
let key = SymmetricKey(size: .bits256)
let wrongKey = SymmetricKey(size: .bits256)
let date = Date(timeIntervalSince1970: 1_700_000_000)
let voice = HistoryEntry(date: date, text: "synthetic voice", audio: "shared")
let other = HistoryEntry(date: date.addingTimeInterval(1), text: "synthetic voice 2", audio: "shared")
let clipboard = HistoryEntry(date: date, text: "synthetic clipboard", kind: .clipboard)
let imported = HistoryEntry(date: date, text: "synthetic import", audio: "new", kind: .imported)
let initial = [voice, other, clipboard]
var archive = VoiceHistoryArchive()
var deleted: [String] = []
var checks = 0

func check(_ name: String, _ success: Bool) {
    precondition(success, name)
    checks += 1
    print("PASS \(name)")
}

let firstLoad = archive.load(from: archiveURL) { fatalError("missing archive requested a key") }
check("missing archive allows first save", firstLoad == nil && !archive.unavailable)
let first = archive.commit(initial, to: archiveURL, key: { key }, deleteClip: { _ in
    fatalError("first save attempted cleanup")
})
let original = try Data(contentsOf: archiveURL)
check("successful encrypted save", first == .saved && archive.entries == initial &&
      original.range(of: Data(voice.text.utf8)) == nil)
var reopened = VoiceHistoryArchive()
let restored = reopened.load(from: archiveURL) { [wrongKey, key] }
check("reopen selects authenticated key and retains clip references", restored != nil && reopened.entries == initial)

let failWrite: (Data, URL) throws -> Void = { _, _ in throw CocoaError(.fileWriteNoPermission) }
var noAudio = voice
noAudio.audio = nil
let cutoff = date.addingTimeInterval(10)
let retention = initial.filter { !HistoryPolicy.isExpired($0, before: cutoff) }
let failureCases: [(String, [HistoryEntry])] = [
    ("update", initial + [HistoryEntry(date: date, text: "next")]),
    ("import", initial + [imported]),
    ("remove", [other, clipboard]),
    ("retention", retention),
    ("clear voice", [clipboard]),
    ("clear all", []),
    ("forget audio", [noAudio, clipboard])
]
for (name, proposal) in failureCases {
    let result = archive.commit(proposal, to: archiveURL, key: { key }, write: failWrite) { clip in
        deleted.append(clip)
        return true
    }
    let bytes = try Data(contentsOf: archiveURL)
    check("failed \(name) preserves disk, memory and clips", result == .writeFailed &&
          archive.entries == initial && bytes == original && deleted.isEmpty)
}

let heldLock = open(archiveURL.appendingPathExtension("lock").path, O_WRONLY)
precondition(heldLock >= 0 && flock(heldLock, LOCK_EX | LOCK_NB) == 0)
let concurrent = archive.commit([clipboard], to: archiveURL, key: { key }) { _ in
    fatalError("busy archive attempted cleanup")
}
close(heldLock)
check("lock contention preserves the incumbent snapshot", concurrent == .writeFailed && archive.entries == initial)

let invalid = HistoryEntry(date: Date(timeIntervalSinceReferenceDate: .infinity), text: "invalid date")
let cryptoError = archive.commit([invalid], to: archiveURL, key: { key }) { _ in
    fatalError("encoding failure attempted cleanup")
}
let keyError = archive.commit([clipboard], to: archiveURL, key: { nil }) { _ in
    fatalError("key failure attempted cleanup")
}
check("serialization failure and unavailable key preserve the last commit",
      cryptoError == .encryptionFailed && keyError == .unavailable && archive.entries == initial)

for (label, bytes, keys) in [
    ("wrong key", original, [wrongKey]),
    ("unavailable key", original, []),
    ("corrupt archive", Data([1, 2, 3]), [key]),
    ("invalid plaintext", try AES.GCM.seal(Data("invalid JSON".utf8), using: key).combined!, [key]),
] {
    let badURL = directory.appendingPathComponent(label)
    try bytes.write(to: badURL)
    var blocked = VoiceHistoryArchive()
    _ = blocked.load(from: badURL) { keys }
    let blockedResult = blocked.commit([clipboard], to: badURL, key: { fatalError("key rotation") }) { _ in
        fatalError("unverified archive attempted cleanup")
    }
    let after = try Data(contentsOf: badURL)
    check("\(label) blocks overwrites and cleanup", blockedResult == .unavailable && bytes == after)
}

let notAFile = directory.appendingPathComponent("directory")
try fs.createDirectory(at: notAFile, withIntermediateDirectories: false)
var unreadable = VoiceHistoryArchive()
_ = unreadable.load(from: notAFile) { [] }
check("filesystem read error is unavailable, not empty", unreadable.unavailable)

let retry = reopened.commit([other, clipboard, imported], to: archiveURL, key: { key }, deleteClip: { _ in
    fatalError("shared clip still referenced")
})
check("reopen and retry retain shared audio and legacy clipboard", retry == .saved &&
      reopened.entries == [other, clipboard, imported])
let clipFile = directory.appendingPathComponent("shared.enc")
try Data([0x42]).write(to: clipFile)
let pruned = reopened.commit([clipboard, imported], to: archiveURL, key: { key }) { clip in
    var onDisk = VoiceHistoryArchive()
    _ = onDisk.load(from: archiveURL) { [key] }
    precondition(!onDisk.entries.contains { $0.audio == clip })
    deleted.append(clip)
    return false
}
check("cleanup failure follows the committed archive and leaves the clip for retry",
      pruned == .saved && deleted == ["shared"] && fs.fileExists(atPath: clipFile.path))
let clear = reopened.commit([clipboard], to: archiveURL, key: { key }) { clip in
    deleted.append(clip)
    if clip == "shared" { try! fs.removeItem(at: clipFile) }
    return true
}
check("voice clear retries failed cleanup and preserves legacy clipboard",
      clear == .saved && !fs.fileExists(atPath: clipFile.path) &&
      deleted.sorted() == ["new", "shared", "shared"] && reopened.entries == [clipboard])
let staleWrite = archive.commit([imported], to: archiveURL, key: { key }) { _ in
    fatalError("stale snapshot attempted cleanup")
}
check("external archive change blocks stale overwrite", staleWrite == .unavailable)

print("\(checks) voice-history checks passed")
