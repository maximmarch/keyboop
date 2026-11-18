import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Encrypted voice history with export-only legacy clipboard records.
final class VoiceHistory {
    static let shared = VoiceHistory()
    private let settings = AppSettings.shared
    private let fileURL: URL
    private let queue = DispatchQueue(label: "ru.keyboop.voice-history", qos: .utility)
    private var archive = VoiceHistoryArchive()
    private lazy var didLoad: Void = {
        if let key = archive.load(from: fileURL, keys: Self.existingKeys) {
            Self.keyLock.withLock { Self.cachedKey = key }
        }
    }()

    typealias Entry = HistoryEntry

    private init() {
        fileURL = Self.supportDir().appendingPathComponent("history.enc")
    }

    static var storageKey: SymmetricKey? { key() }

    var archiveUnavailable: Bool {
        queue.sync { _ = didLoad; return archive.unavailable }
    }

    /// All mutations are serialized. A result is delivered on the main queue.
    func add(_ text: String, audio: String? = nil, wave: [UInt8]? = nil,
             completion: ((VoiceHistorySaveResult) -> Void)? = nil) {
        enqueue(Entry(date: Date(), text: text, audio: audio, wave: wave, kind: .dictation)) { result in
            if let completion { completion(result) }
            else if result != .disabled { Self.reportFailure(result) }
        }
    }

    func addImported(_ text: String, fileName: String, audio: String?, wave: [UInt8]?,
                     kind: HistoryKind = .imported, completion: @escaping (VoiceHistorySaveResult) -> Void) {
        enqueue(Entry(date: Date(), text: text, audio: audio, wave: wave, kind: kind, app: fileName),
                completion: completion)
    }

    private func enqueue(_ entry: Entry, completion: @escaping (VoiceHistorySaveResult) -> Void) {
        queue.async { [self] in
            _ = didLoad
            let result: VoiceHistorySaveResult
            if settings.voiceHistoryEnabled {
                var proposed = archive.entries
                var entry = entry
                if !settings.voiceSaveAudio { entry.audio = nil; entry.wave = nil }
                proposed.append(entry)
                result = commit(HistoryPolicy.capped(retained(proposed)).kept)
            } else {
                result = .disabled
            }

            // The producer owns a newly staged clip. Never delete it if the archive is unknown
            // or if any committed entry still references it.
            if let clip = entry.audio, !archive.unavailable,
               !archive.entries.contains(where: { $0.audio == clip }) {
                VoiceClips.delete(clip)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func retained(_ entries: [Entry], minutes: Int? = nil) -> [Entry] {
        let minutes = minutes ?? settings.voiceHistoryMinutes
        guard minutes > 0 else { return entries }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return entries.filter { !HistoryPolicy.isExpired($0, before: cutoff) }
    }

    private func commit(_ proposed: [Entry]) -> VoiceHistorySaveResult {
        let changed = proposed != archive.entries
        let result = archive.commit(proposed, to: fileURL, key: Self.key, write: { data, url in
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }, deleteClip: VoiceClips.removeUnreferenced)
        if changed && result == .saved { notifyChanged() }
        return result
    }

    func forgetAudio() -> VoiceHistorySaveResult {
        queue.sync {
            _ = didLoad
            return commit(archive.entries.map {
                guard !$0.isClipboard else { return $0 }
                var entry = $0
                entry.audio = nil
                entry.wave = nil
                return entry
            })
        }
    }

    func countOlder(thanMinutes mins: Int) -> Int {
        queue.sync {
            _ = didLoad
            return archive.entries.count - retained(archive.entries, minutes: mins).count
        }
    }

    func applyRetention(minutes: Int) -> VoiceHistorySaveResult {
        queue.sync {
            _ = didLoad
            return commit(retained(archive.entries, minutes: minutes))
        }
    }

    func all() -> [Entry] {
        queue.sync {
            _ = didLoad
            let visible = retained(archive.entries)
            if visible != archive.entries { _ = commit(visible) }
            return archive.unavailable ? [] : HistoryPolicy.visibleVoiceEntries(visible)
        }
    }

    func lastVisible() -> Entry? {
        queue.sync {
            _ = didLoad
            guard settings.voiceHistoryEnabled, !archive.unavailable else { return nil }
            return HistoryPolicy.lastDictation(retained(archive.entries))
        }
    }

    var hasAnyDictation: Bool {
        queue.sync { _ = didLoad; return HistoryPolicy.lastDictation(archive.entries) != nil }
    }

    func remove(date: Date, text: String) -> VoiceHistorySaveResult {
        queue.sync {
            _ = didLoad
            return commit(archive.entries.filter { $0.isClipboard || $0.date != date || $0.text != text })
        }
    }

    func clear(includingLegacyClipboard: Bool = false) -> VoiceHistorySaveResult {
        queue.sync {
            _ = didLoad
            return commit(includingLegacyClipboard ? [] : archive.entries.filter(\.isClipboard))
        }
    }

    static func reportFailure(_ result: VoiceHistorySaveResult) {
        guard result != .saved else { return }
        VoiceIndicator.shared.showToast(L10n.t(result.messageKey))
    }

    /// Открытое окно истории слушает это и перестраивается мгновенно (не ждёт поллинга).
    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .keyboopVoiceHistoryChanged, object: nil) }
    }

    enum ExportError: Error { case missingArchive, keyUnavailable, damagedArchive, invalidArchive }

    /// Read-only migration path. Do not initialize the singleton, resolve a new
    /// key, prune history, or run the orphan-audio cleanup.
    static func clipboardExport() throws -> ClipboardTransfer.Payload {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        let data: Data
        do { data = try Data(contentsOf: directory.appendingPathComponent("history.enc")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw ExportError.missingArchive }
        catch { throw ExportError.damagedArchive }
        guard let box = try? AES.GCM.SealedBox(combined: data) else { throw ExportError.damagedArchive }
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = keychainBase
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let keys = [keyLock.withLock { cachedKey },
                    (status == errSecSuccess ? item as? Data : nil).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil },
                    (try? Data(contentsOf: directory.appendingPathComponent(".histkey"))).flatMap {
                        $0.count == 32 ? SymmetricKey(data: $0) : nil
                    }].compactMap { $0 }
        guard !keys.isEmpty else { throw ExportError.keyUnavailable }
        guard let clear = keys.lazy.compactMap({ try? AES.GCM.open(box, using: $0) }).first else {
            throw ExportError.damagedArchive
        }
        let entries: [ClipboardTransfer.Entry]
        do { entries = try ClipboardTransfer.exportEntries(from: clear) }
        catch { throw ExportError.invalidArchive }
        return .init(schemaVersion: 1, exportedAt: Date(), sourceApplication: "Keyboop",
                     sourceVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.4",
                     entries: entries)
    }

    // MARK: - Шифрование

    private static func existingKeys() -> [SymmetricKey] {
        let file = try? Data(contentsOf: supportDir().appendingPathComponent(".histkey"))
        let keychain = devBuild && file?.count == 32 ? nil : keychainRead()
        let candidates = devBuild ? [file, keychain] : [keychain, file]
        return candidates.compactMap { data in
            guard let data, data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }
    }

    // Read existing keys without rotating them. New archives use Keychain in production,
    // with the existing private file fallback. Development archives prefer the file.
    private static let keychainService = (Bundle.main.bundleIdentifier ?? "ru.keyboop.app") + ".voicehistory"
    private static let keychainAccount = "history-aes-key"
    private static let keyLock = NSLock()
    private static var cachedKey: SymmetricKey?
    private static let devBuild = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")

    private static func key() -> SymmetricKey? {
        keyLock.withLock { resolveStorageKey() }
    }

    private static func resolveStorageKey() -> SymmetricKey? {
        if let k = cachedKey { return k }
        let archive = supportDir().appendingPathComponent("history.enc")
        do {
            let blob = try Data(contentsOf: archive)
            guard let box = try? AES.GCM.SealedBox(combined: blob),
                  let k = existingKeys().first(where: { (try? AES.GCM.open(box, using: $0)) != nil })
            else { return nil }
            cachedKey = k
            return k
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let k = resolveKey(); cachedKey = k; return k
        } catch { return nil }
    }

    /// Called only for a missing archive. Preserve any existing key, including the legacy file.
    private static func resolveKey() -> SymmetricKey? {
        if let existing = existingKeys().first { return existing }
        let keyURL = supportDir().appendingPathComponent(".histkey")
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        if !devBuild, keychainWrite(data) { return key }
        guard !FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        writeKeyFile(data, to: keyURL)
        guard (try? Data(contentsOf: keyURL)) == data else { return nil }
        return key
    }

    private static func writeKeyFile(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var keychainBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    /// Чтение строго БЕЗ диалога: SecKeychainSetUserInteractionAllowed(false) на время запроса.
    /// errSecInteractionNotAllowed = связка узнала item, но не узнала НАС → это тот самый диалог;
    /// возвращаем nil; недоступный существующий архив остаётся нетронутым.
    private static func keychainRead() -> Data? {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecInteractionNotAllowed {
            kbLog("voice history key: связка требует диалог (identity сменилась)")
            return nil
        }
        guard st == errSecSuccess, let d = out as? Data else { return nil }
        return d
    }

    @discardableResult
    private static func keychainWrite(_ data: Data) -> Bool {
        var add = keychainBase
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
