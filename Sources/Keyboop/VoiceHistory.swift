import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Encrypted voice history with export-only legacy clipboard records.
final class VoiceHistory {
    static let shared = VoiceHistory()
    private let settings = AppSettings.shared
    private let fileURL: URL
    private var cache: [Entry] = []
    private var archiveUnavailable = false

    /// Запись живёт в `ClipboardHistoryCore.swift` (`HistoryEntry`): с 04.09.2026 в ленте два типа
    /// записей, и стенд проверяет чтение старых файлов без самой истории. Правило про Optional-поля
    /// (`audio` с 08.08, `wave` с 10.08, `kind`/`app` с 04.09) записано там же и остаётся несущим.
    typealias Entry = HistoryEntry

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.enc")
        do { cache = try load() }
        catch { archiveUnavailable = true; return }
        if prune() { save() }   // на старте подчистить записи старше срока хранения
        // Сироты: клипы, чьи записи исчезли путём, который про файлы не знал (перевыпуск ключа
        // обнуляет историю целиком). Один проход по каталогу на старте, это дешевле, чем накопить
        // гигабайт нечитаемых файлов.
        VoiceClips.keepOnly(Set(cache.compactMap { $0.audio }))
    }

    /// Ключ шифрования истории. Им же шифруются аудиоклипы (`VoiceClips`): держать голос открытым
    /// рядом с зашифрованным текстом было бы самообманом, речь восстанавливает содержание не хуже.
    static var storageKey: SymmetricKey? { key() }

    /// `audio` — идентификатор клипа из `VoiceClips` (nil, если сохранение аудио выключено).
    ///
    /// ⚠️ Клип живёт ровно столько же, сколько запись, поэтому КАЖДЫЙ путь, которым запись отсюда
    /// исчезает, обязан унести и файл: срок хранения (`prune`), потолки по типам (`applyCaps`),
    /// удаление одной (`remove`), «очистить всё» (`clear`).
    func add(_ text: String, audio: String? = nil, wave: [UInt8]? = nil) {
        guard settings.voiceHistoryEnabled else {
            if let a = audio { VoiceClips.delete(a) }   // история выключена — клипу тем более не место
            return
        }
        cache.append(Entry(date: Date(), text: text, audio: audio, wave: wave, kind: .dictation))
        _ = prune()
        applyCaps()
        save()
        notifyChanged()
    }

    /// Расшифровка импортированного аудиофайла (задача 229). Не подчиняется сроку хранения: человек
    /// принёс файл сам и ждал расшифровки минуты, стирать её через час было бы издевательством.
    /// Уходит только вручную, «очистить историю» или по своему потолку в `HistoryPolicy`.
    func addImported(_ text: String, fileName: String, audio: String?, wave: [UInt8]?, kind: HistoryKind = .imported) {
        guard settings.voiceHistoryEnabled else {
            if let a = audio { VoiceClips.delete(a) }
            return
        }
        cache.append(Entry(date: Date(), text: text, audio: audio, wave: wave, kind: kind, app: fileName))
        _ = prune()
        applyCaps()
        save()
        notifyChanged()
    }

    /// Потолки считаются отдельно для диктовок и буфера (`HistoryPolicy`), чтобы сотня
    /// скопированных строк не вытеснила диктовки. У выброшенных диктовок уносим клипы.
    private func applyCaps() {
        let (kept, dropped) = HistoryPolicy.capped(cache)
        guard !dropped.isEmpty else { return }
        dropped.compactMap { $0.audio }.forEach(VoiceClips.delete)
        cache = kept
    }

    /// Удалить записи старше voiceHistoryMinutes (0 = хранить всё). true — если что-то удалили.
    @discardableResult
    func prune() -> Bool {
        let mins = settings.voiceHistoryMinutes
        guard mins > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(mins) * 60)
        let before = cache.count
        // Импортированные файлы срок хранения не трогает (см. addImported).
        cache.filter { HistoryPolicy.isExpired($0, before: cutoff) }.compactMap { $0.audio }.forEach(VoiceClips.delete)
        cache.removeAll { HistoryPolicy.isExpired($0, before: cutoff) }
        return cache.count != before
    }

    /// Снять ссылки на аудио со ВСЕХ записей (человек выключил сохранение записи голоса).
    /// Сами тексты остаются: он выключил звук, а не историю.
    func forgetAudio() {
        guard cache.contains(where: { $0.audio != nil }) else { return }
        cache = cache.map { var e = $0; e.audio = nil; e.wave = nil; return e }
        save()
        notifyChanged()
    }

    /// Сколько записей удалил бы срок хранения в `mins` минут, если применить его сейчас. Ничего не
    /// меняет: по этому числу настройки спрашивают человека перед сокращением срока.
    func countOlder(thanMinutes mins: Int) -> Int {
        guard mins > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(mins) * 60)
        return cache.filter { HistoryPolicy.isExpired($0, before: cutoff) }.count
    }

    /// Применить новый срок хранения (зовётся из настроек) — подчистить + обновить окно.
    func applyRetention() {
        if prune() { save(); notifyChanged() }
    }
    /// Все записи, УЖЕ подчищенные по сроку хранения.
    ///
    /// ⚠️ ЧИСТИМ ПРЯМО ЗДЕСЬ (аудит умолчаний, 05.08.2026). Раньше `prune()` звался только на старте,
    /// при добавлении записи и при смене срока в настройках. То есть человек, продиктовавший один раз
    /// и больше не диктовавший, открывал окно истории через два часа и видел запись, срок которой
    /// вышел час назад: она лежала и в памяти, и в файле. Обходной путь для меню уже был
    /// (`lastVisible()` ниже), а окно и файл оставались честными только случайно.
    ///
    /// Это не про удобство, а про принцип №2: срок хранения это обещание, а не оформление.
    func all() -> [Entry] {
        if prune() { save() }
        return HistoryPolicy.visibleVoiceEntries(cache)
    }

    /// Последняя диктовка, которую ПРЯМО СЕЙЧАС законно показать: история включена и запись ещё не
    /// просрочена по сроку хранения. Ничего не меняет и не пишет на диск — зовётся из сборки меню.
    ///
    /// Отдельно от `all().last`, потому что `cache` вычищается только в `prune()` (на добавлении и при
    /// смене срока в настройках), а между этими моментами в нём спокойно лежит запись, срок которой
    /// уже вышел. Пункт «Скопировать последнюю диктовку» опирается именно на этот метод, иначе он
    /// предлагал бы скопировать то, что человек велел удалить полчаса назад.
    ///
    /// Только диктовки: с появлением буфера в ленте (задача 228) последняя ЗАПИСЬ и последняя
    /// ДИКТОВКА разошлись, а пункт обещает именно диктовку.
    func lastVisible() -> Entry? {
        guard settings.voiceHistoryEnabled, let e = HistoryPolicy.lastDictation(cache) else { return nil }
        let mins = settings.voiceHistoryMinutes
        guard mins > 0 else { return e }                       // 0 = хранить всё
        return e.date >= Date().addingTimeInterval(-Double(mins) * 60) ? e : nil
    }
    /// Есть ли в кэше хоть одна диктовка, без учёта срока хранения.
    ///
    /// Нужно затем, чтобы отличить «диктовок ещё не было» от «диктовка была, но её срок вышел»:
    /// для человека это разные новости (задача 242). `all()` для такой проверки не годится — он
    /// чистит просроченное и пишет на диск, то есть сам стирает признак, который мы пришли измерить.
    ///
    /// ⚠️ ЧЕСТНАЯ ГРАНИЦА: `prune()` зовётся не только из `all()`, но и из `init`, `add` и смены
    /// срока хранения, поэтому просроченная запись доживает до этой проверки не всегда. Значит
    /// «была, но просрочена» мы говорим, только когда МОЖЕМ это доказать, а в остальных случаях
    /// сообщение обязано быть верным при обоих раскладах — см. `voice.pasteLastNever`.
    var hasAnyDictation: Bool { HistoryPolicy.lastDictation(cache) != nil }

    func remove(date: Date, text: String) {
        cache.filter { !$0.isClipboard && $0.date == date && $0.text == text }.compactMap { $0.audio }.forEach(VoiceClips.delete)
        cache.removeAll { !$0.isClipboard && $0.date == date && $0.text == text }
        save()
        notifyChanged()
    }
    @discardableResult
    func clear(includingLegacyClipboard: Bool = false) -> Bool {
        guard !archiveUnavailable else { return false }
        let kept = includingLegacyClipboard ? [] : cache.filter { $0.isClipboard }
        let old = cache
        cache = kept
        guard save() else { cache = old; return false }
        VoiceClips.keepOnly(Set(kept.compactMap { $0.audio }))
        notifyChanged()
        return true
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
        let keys = [cachedKey,
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

    @discardableResult
    private func save() -> Bool {
        guard !archiveUnavailable, let key = Self.key() else { return false }
        do {
            let data = try JSONEncoder().encode(cache)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else { return false }
            try combined.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            kbLog("voice history save failed")
            return false
        }
    }

    private func load() throws -> [Entry] {
        let blob: Data
        do { blob = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let box = try AES.GCM.SealedBox(combined: blob)
        for key in Self.existingKeys() {
            guard let data = try? AES.GCM.open(box, using: key) else { continue }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            Self.cachedKey = key
            return entries
        }
        throw ExportError.keyUnavailable
    }

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
    private static var cachedKey: SymmetricKey?
    private static let devBuild = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")

    private static func key() -> SymmetricKey? {
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
