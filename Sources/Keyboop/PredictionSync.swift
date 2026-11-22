import CryptoKit
import Foundation

final class PredictionSync {
    static let shared = PredictionSync(defaults: .standard, history: .shared, writer: hostWriter())
    static let changed = Notification.Name("KeyboopPredictionSyncChanged")
    static let importedSettings = Notification.Name("KeyboopPredictionSyncImportedSettings")
    private static let ledgerSuffix = ".preferences.json"
    private static let historySuffix = ".personal.json"
    private let defaults: UserDefaults
    private let history: PersonalPredictionStore
    private let writer: UUID
    private let worker = DispatchQueue(label: "ru.keyboop.prediction-sync", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var timer: Timer?
    private var running = false
    private var rerun = false
    private var importedDigest: Data?
    private var importedSession: UInt64?
    private(set) var status = "sync.off"
    private(set) var lastSuccess: Date?

    init(defaults: UserDefaults, history: PersonalPredictionStore, writer: UUID) {
        self.defaults = defaults
        self.history = history
        self.writer = writer
    }

    // ByHost preferences keep restored copies of the same account from sharing a writer ID.
    private static func hostWriter() -> UUID {
        let key = "predictionSyncWriter" as CFString
        let domain = (Bundle.main.bundleIdentifier ?? "ru.keyboop.app") as CFString
        if let value = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? String,
           let id = UUID(uuidString: value) { return id }
        let id = UUID()
        CFPreferencesSetValue(key, id.uuidString as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return id
    }

    var enabled: Bool { defaults.bool(forKey: "predictionSyncEnabled") }
    var folderPath: String? { defaults.string(forKey: "predictionSyncFolderPath") }
    var sharesPersonal: Bool { defaults.bool(forKey: "predictionSyncPersonal") }
    private var personalAllowed: Bool { sharesPersonal && defaults.bool(forKey: "personalPredictionEnabled") }

    func choose(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        if folderPath != url.path {
            defaults.removeObject(forKey: "predictionSyncCheckpoint")
            defaults.set(false, forKey: "predictionSyncPersonal")
        }
        defaults.set(bookmark, forKey: "predictionSyncFolder")
        defaults.set(url.path, forKey: "predictionSyncFolderPath")
        setEnabled(true)
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: "predictionSyncEnabled")
        start()
    }

    func setSharesPersonal(_ value: Bool) {
        defaults.set(value, forKey: "predictionSyncPersonal")
        start()
    }

    func start() {
        lock.withLock { generation += 1 }
        timer?.invalidate()
        timer = nil
        importedDigest = nil
        history.setPeerHistory(nil)
        lastSuccess = nil
        status = enabled ? "sync.waiting" : "sync.off"
        notify()
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.syncNow() }
        timer?.tolerance = 2
        syncNow()
    }

    func syncNow() {
        guard enabled, let bookmark = defaults.data(forKey: "predictionSyncFolder") else { return }
        guard !running else { rerun = true; return }
        running = true
        status = "sync.working"
        notify()
        let token = lock.withLock { generation }
        let personal = personalAllowed
        if personal { history.setEnabled(true) }
        worker.async {
            do {
                var stale = false
                let root = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
                let folder = try PredictionSyncFolder(root: root, writer: self.writer)
                try self.exchangePreferences(folder, token: token)
                if self.active(token) { try self.exchangePersonal(folder, enabled: personal, token: token) }
                self.finish(token, success: true, root: root, stale: stale)
            } catch { self.finish(token, success: false, root: nil, stale: false) }
        }
    }

    private func active(_ token: Int) -> Bool { lock.withLock { generation == token } }

    private func exchangePreferences(_ folder: PredictionSyncFolder, token: Int) throws {
        let own = folder.own(Self.ledgerSuffix)
        var peers: [PredictionSyncLedger] = []
        var published: PredictionSyncLedger?
        for url in try folder.files(suffix: Self.ledgerSuffix) {
            let data = try folder.read(url, limit: 32_000_000)
            let peer = try JSONDecoder().decode(PredictionSyncLedger.self, from: data)
            try peer.validate()
            peers.append(peer)
            if url.lastPathComponent == own.lastPathComponent { published = peer }
        }
        // An editor can change a preference while files download. Diff and apply on the main thread
        // against the current values, keeping our merged state locally until publication succeeds.
        let result: PredictionSyncLedger? = try DispatchQueue.main.sync {
            guard active(token) else { return nil }
            let previous = try defaults.data(forKey: "predictionSyncCheckpoint").map {
                try JSONDecoder().decode(PredictionSyncLedger.self, from: $0)
            }
            try previous?.validate()
            let words = PredictionSyncLedger.terms(defaults.string(forKey: "predictionGlossary") ?? "")
            let options = Dictionary(uniqueKeysWithValues: PredictionSyncLedger.optionKeys.map { ($0, defaults.bool(forKey: $0)) })
            let ledger = PredictionSyncLedger.reconcile(previous: previous, peers: peers, glossary: words,
                                                       preferences: options, writer: writer)
            let merged = ledger.activeWords
            var changed = false
            if words != merged {
                defaults.set(merged.values.sorted().joined(separator: "\n"), forKey: "predictionGlossary")
                changed = true
            }
            for key in PredictionSyncLedger.optionKeys {
                let value = ledger.options[key]?.value ?? false
                if options[key] != value { defaults.set(value, forKey: key); changed = true }
            }
            if previous != ledger { defaults.set(try JSONEncoder().encode(ledger), forKey: "predictionSyncCheckpoint") }
            if changed { NotificationCenter.default.post(name: Self.importedSettings, object: self) }
            return ledger
        }
        guard let result, published != result else { return }
        let data = try JSONEncoder().encode(result)
        guard data.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try folder.write(data, to: own) { self.active(token) }
    }

    private func exchangePersonal(_ folder: PredictionSyncFolder, enabled: Bool, token: Int) throws {
        let own = folder.own(Self.historySuffix)
        let allowed = { self.active(token) && self.personalAllowed }
        guard enabled, allowed() else {
            let placeholder = folder.directory.appendingPathComponent("." + own.lastPathComponent + ".icloud")
            if FileManager.default.fileExists(atPath: own.path) || FileManager.default.fileExists(atPath: placeholder.path) {
                try folder.write(nil, to: own) { self.active(token) && !self.personalAllowed }
            }
            DispatchQueue.main.sync {
                if active(token) { importedDigest = nil; history.setPeerHistory(nil) }
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var source: Data?
        var snapshots: [Data] = []
        var digest = SHA256()
        for url in try folder.files(suffix: Self.historySuffix) {
            guard allowed() else { return }
            let data = try folder.read(url, limit: 16_000_000)
            if url.lastPathComponent == own.lastPathComponent { source = data }
            else {
                digest.update(data: Data(SHA256.hash(data: data)))
                snapshots.append(data)
            }
        }
        let fingerprint = Data(digest.finalize())
        let needsMerge = DispatchQueue.main.sync { importedDigest != fingerprint || importedSession != history.session }
        if needsMerge {
            let histories = try snapshots.map { data in
                let value = try JSONDecoder().decode(PersonalPredictionHistory.self, from: data)
                guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
                return value
            }
            let peers = histories.isEmpty ? nil : PersonalPredictionHistory.combined(histories)
            DispatchQueue.main.sync {
                if allowed() {
                    history.setPeerHistory(peers)
                    importedSession = history.session
                    importedDigest = fingerprint
                }
            }
        }
        // Never republish words learned on another Mac.
        if allowed(), let local = history.localSnapshot() {
            let data = try encoder.encode(local)
            guard data.count <= 16_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            if data != source { try folder.write(data, to: own, allowed: allowed) }
        }
    }

    private func finish(_ token: Int, success: Bool, root: URL?, stale: Bool) {
        DispatchQueue.main.async {
            self.running = false
            if self.active(token) {
                if success, let root {
                    self.lastSuccess = Date()
                    if stale, let data = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        self.defaults.set(data, forKey: "predictionSyncFolder")
                        self.defaults.set(root.path, forKey: "predictionSyncFolderPath")
                    }
                }
                self.status = success ? "sync.done" : "sync.retry"
                self.notify()
            }
            if self.rerun { self.rerun = false; self.syncNow() }
        }
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
