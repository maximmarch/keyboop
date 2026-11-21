import AppKit
import Darwin
import Foundation

struct PredictionModel {
    let id: String
    let title: String
    let repository: String?
    let revision: String?
    let filename: String
    let bytes: Int64
    let sha256: String

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var downloadURL: URL? {
        guard let repository, let revision else { return nil }
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")
    }
}

struct PredictionConnection: Equatable {
    let baseURL: URL
    let apiKey: String?
    let modelID: String?
    var modelAlias: String? = nil
}

extension Notification.Name {
    static let predictionRuntimeChanged = Notification.Name("keyboop.predictionRuntimeChanged")
    static let dictationModelRuntimeChanged = Notification.Name("keyboop.dictationModelRuntimeChanged")
}

final class LoopbackModelRequestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class PredictionRuntime {
    enum Purpose: String {
        case prediction, dictation

        var modelKey: String { self == .prediction ? "predictionModelID" : "voicePostProcessModelID" }
        var models: [PredictionModel] { self == .prediction ? PredictionRuntime.models : PredictionRuntime.dictationModels }
    }

    enum InfillStatus: String {
        case waiting, checking, ready, unavailable, unsuitable

        var messageKey: String { "prediction.infill." + rawValue }
    }

    // Each probe exercises the production grammar, confidence threshold and right-edge checks.
    static let infillProbes = [
        (before: "Давайте обсудим ", after: " завтра утром.", expected: Set(["детали", "план", "это"])),
        (before: "The sky is ", after: " on a clear day.", expected: Set(["blue"]))
    ]

    static let shared = PredictionRuntime()
    static let dictation = PredictionRuntime(purpose: .dictation, idleSeconds: 45)
    private static let defaultModel = PredictionModel(
        id: "qwen3-0.6b-base", title: "Qwen3-0.6B-Base · Q4_K_M",
        repository: "itlwas/Qwen3-0.6B-Base-Q4_K_M-GGUF",
        revision: "b35c598ac7ff4a09f9fcae19691a68bf82cd7e87",
        filename: "qwen3-0.6b-base-q4_k_m.gguf", bytes: 396_704_512,
        sha256: "218d3f063193b40008d4e63d90cf83e7dc6d33a8c6c1c647589f868a8fc74492"
    )
    static let models = [
        defaultModel,
        PredictionModel(id: "qwen3.5-0.8b-base", title: "Qwen3.5-0.8B-Base · Q4_K_M",
                        repository: "thwrhrt/Qwen3.5-0.8B-Base-Quant",
                        revision: "27707bf4d439618d2ff927f38f1fed398ae6d722",
                        filename: "Qwen3.5-0.8B-Base-Q4_K_M.gguf", bytes: 529_297_024,
                        sha256: "c736a47eded0b5af672caf5f2622b4edd6a378a78c6e30a97867ccc6f6d39537")
    ]
    static let gemmaDictationModelID = "gemma-4-e2b-it"
    static let dictationModels = [
        PredictionModel(id: gemmaDictationModelID, title: "Gemma 4 E2B IT · Q4_K_M",
                        repository: "lmstudio-community/gemma-4-E2B-it-GGUF",
                        revision: "3d1d91fb148a495f70c9e36ae57bce21921fe8a3",
                        filename: "gemma-4-E2B-it-Q4_K_M.gguf", bytes: 3_427_880_384,
                        sha256: "71e6e8cb64a76da1a734fb8f6ba389d2784950d9902f5e87244fca0a15190c94"),
        PredictionModel(id: "qwen2.5-1.5b-instruct", title: "Qwen2.5-1.5B-Instruct · Q4_K_M",
                        repository: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
                        revision: "91cad51170dc346986eccefdc2dd33a9da36ead9",
                        filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf", bytes: 1_117_320_736,
                        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"),
        PredictionModel(id: "qwen2.5-0.5b-instruct", title: "Qwen2.5-0.5B-Instruct · Q4_K_M",
                        repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
                        revision: "9217f5db79a29953eb74d5343926648285ec7e67",
                        filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf", bytes: 491_400_032,
                        sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
    ]

    // Process ownership, file promotion, status and pending callbacks share a serial queue.
    // Network IO, imports and digest calculation run off this queue.
    private static let libraryQueue = DispatchQueue(label: "ru.keyboop.prediction-runtime", qos: .utility)
    private static let libraryChanged = Notification.Name("keyboop.modelLibraryChanged")
    private let queue = PredictionRuntime.libraryQueue
    private let defaults: UserDefaults
    private let purpose: Purpose
    private let directory: URL
    private let health: URLSession
    private let downloads = URLSession(configuration: .ephemeral)
    private let idleSeconds: TimeInterval
    private var selected: PredictionModel
    private var external: Bool
    private var enabled = false
    private var state = "disabled"
    private var detail = ""
    private var download: URLSessionDownloadTask?
    private var importStatus: String?
    private var libraryObserver: NSObjectProtocol?
    private var progressObserver: NSKeyValueObservation?
    private var generation = UUID()
    private var process: Process?
    private var ownerPipe: FileHandle?
    private var retiring: Process?
    private var restartAfterRetirement = false
    private var ready: PredictionConnection?
    private var infillEnabled = false
    private var infillState: InfillStatus = .waiting
    private var infillRequest: WordCompletionRequest?
    private lazy var infillClient = PredictiveLocalModel()
    private var idleTimer: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var healthRequest: URLSessionDataTask?
    private var retryAfter = DispatchTime.now()

    init(purpose: Purpose = .prediction, defaults: UserDefaults = .standard, directory: URL? = nil,
         idleSeconds: TimeInterval = 120) {
        self.purpose = purpose
        self.defaults = defaults
        let directory = directory ?? Self.modelDirectory
        self.directory = directory
        self.idleSeconds = idleSeconds
        let selectedID = defaults.string(forKey: purpose.modelKey)
        selected = Self.catalog(for: purpose, in: directory).first { $0.id == selectedID } ?? purpose.models[0]
        // Before the managed backend the enabled switch meant an external server on port 18181.
        if purpose == .prediction, defaults.object(forKey: "predictionExternalServer") == nil {
            defaults.set(defaults.bool(forKey: "predictiveLocalModelEnabled"), forKey: "predictionExternalServer")
        }
        external = purpose == .prediction && defaults.bool(forKey: "predictionExternalServer")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        health = URLSession(configuration: configuration, delegate: LoopbackModelRequestDelegate(), delegateQueue: nil)

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in
            guard let self, self.process != nil else { return }
            self.stopServer()
            self.retryAfter = .now() + .seconds(15)
            self.showStandby()
        }
        pressure.resume()
        memoryPressure = pressure
        if purpose == .dictation {
            enabled = true
            state = isInstalled ? "installed" : "missing"
        }
        libraryObserver = NotificationCenter.default.addObserver(forName: Self.libraryChanged, object: nil, queue: nil) { [weak self] note in
            guard let self, let origin = note.object as? PredictionRuntime, origin !== self,
                  origin.directory == self.directory, let id = note.userInfo?["id"] as? String else { return }
            self.queue.async { self.refreshLibrary(changedID: id) }
        }
    }

    deinit {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
    }

    var selectedModelID: String {
        get { queue.sync { selected.id } }
        set {
            queue.sync {
                guard let model = Self.catalog(for: purpose, in: directory).first(where: { $0.id == newValue }),
                      model.id != selected.id else { return }
                discardDownload()
                select(model)
                reconfigure()
            }
        }
    }

    var usesExternalServer: Bool {
        get { queue.sync { external } }
        set {
            queue.sync {
                guard purpose == .prediction, external != newValue else { return }
                discardDownload()
                stopServer()
                external = newValue
                defaults.set(external, forKey: "predictionExternalServer")
                reconfigure()
            }
        }
    }

    var canTestModel: Bool {
        queue.sync { importStatus == nil && enabled && (external || (isInstalled && (ready != nil || state == "installed"))) }
    }

    var isDownloading: Bool { queue.sync { download != nil } }
    var isImporting: Bool { queue.sync { importStatus != nil } }
    var hasSelectedModel: Bool { queue.sync { isInstalled } }
    var availableModels: [PredictionModel] { queue.sync { Self.catalog(for: purpose, in: directory) } }
    var installedModelIDs: Set<String> {
        queue.sync { Set(Self.catalog(for: purpose, in: directory).filter { Self.isInstalled($0, in: directory) }.map(\.id)) }
    }
    static var hasBuiltInServer: Bool { bundledServer() != nil }
    var statusText: String {
        let (key, extra) = queue.sync { importStatus.map { ($0, "") } ?? (state, detail) }
        return L10n.t("prediction.runtime." + key) + extra
    }

    func setEnabled(_ value: Bool) {
        queue.sync {
            guard enabled != value else { return }
            enabled = value
            if !value { stopServer() }
            reconfigure()
        }
    }

    func connection() -> PredictionConnection? {
        queue.sync {
            guard enabled else { return nil }
            if external {
                return PredictionConnection(baseURL: URL(string: "http://127.0.0.1:18181")!, apiKey: nil, modelID: nil)
            }
            return managedConnection()
        }
    }

    /// Give a cold start a bounded amount of time, and keep the requested model pinned during the wait.
    func waitForChatConnection() async throws -> PredictionConnection? {
        try Task.checkCancellation()
        let modelID = queue.sync { () -> String? in
            guard purpose == .dictation, enabled, isInstalled else { return nil }
            _ = managedConnection()
            return selected.id
        }
        guard let modelID else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            try Task.checkCancellation()
            let (connection, starting) = queue.sync { () -> (PredictionConnection?, Bool) in
                guard selected.id == modelID else { return (nil, false) }
                if let ready, process?.isRunning == true {
                    armIdleTimer()
                    return (ready, false)
                }
                return (nil, state == "starting")
            }
            if let connection { return connection }
            if !starting { return nil }
            try await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    private func managedConnection() -> PredictionConnection? {
        if let ready, process?.isRunning == true {
            armIdleTimer()
            return ready
        }
        if process == nil, isInstalled, DispatchTime.now() >= retryAfter { startServer() }
        return nil
    }

    var infillStatus: InfillStatus {
        queue.sync { external || Self.bundledServer() == nil ? .unavailable : infillState }
    }

    func setInfillEnabled(_ value: Bool) {
        queue.sync {
            guard infillEnabled != value else { return }
            infillEnabled = value
            let previous = infillState
            if value {
                checkInfillIfNeeded()
            } else {
                resetInfill()
            }
            if previous == infillState { notifyObservers() }
        }
    }

    func infillConnection() -> PredictionConnection? {
        queue.sync {
            guard enabled, infillEnabled, !external, Self.bundledServer() != nil,
                  let endpoint = managedConnection() else { return nil }
            checkInfillIfNeeded()
            return infillState == .ready ? endpoint : nil
        }
    }

    private func checkInfillIfNeeded() {
        guard enabled, infillEnabled, !external, infillState == .waiting,
              Self.bundledServer() != nil, let endpoint = ready, let child = process, child.isRunning else { return }
        let request = WordCompletionRequest()
        infillRequest = request
        updateInfill(.checking)
        checkInfillProbe(index: 0, endpoint: endpoint, child: child, request: request)
    }

    private func checkInfillProbe(index: Int, endpoint: PredictionConnection, child: Process,
                                  request: WordCompletionRequest) {
        let probe = Self.infillProbes[index]
        guard let key = endpoint.apiKey,
              let context = PredictionPhrase.InfillContext(before: probe.before, after: probe.after) else {
            infillRequest = nil
            updateInfill(.unavailable)
            return
        }
        infillClient.infill(context, endpoint: endpoint.baseURL, apiKey: key, request: request,
                            deadline: .now() + .milliseconds(650)) { [weak self, weak child] event in
            guard let self, let child else { return }
            self.queue.async {
                guard self.infillRequest === request, self.process === child, child.isRunning,
                      self.infillEnabled else { return }
                let verdict = Self.infillProbeVerdict(event, expected: probe.expected)
                if verdict == .ready, index + 1 < Self.infillProbes.count {
                    self.checkInfillProbe(index: index + 1, endpoint: endpoint, child: child, request: request)
                } else {
                    self.infillRequest = nil
                    self.updateInfill(verdict)
                }
            }
        }
    }

    static func infillProbeVerdict(_ event: PredictiveLocalModel.Event, expected: Set<String>) -> InfillStatus {
        switch event {
        case let .finished(word):
            return word.map { expected.contains(WordCompletionIndex.key($0)) } == true ? .ready : .unsuitable
        case .failed, .partial:
            return .unavailable
        }
    }

    private func resetInfill() {
        infillRequest?.cancel()
        infillRequest = nil
        updateInfill(.waiting)
    }

    private func updateInfill(_ value: InfillStatus) {
        guard infillState != value else { return }
        infillState = value
        notifyObservers()
    }

    private func notifyObservers() {
        let name: Notification.Name = purpose == .prediction ? .predictionRuntimeChanged : .dictationModelRuntimeChanged
        DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: self) }
    }

    func downloadSelected() {
        queue.sync {
            guard download == nil, importStatus == nil, !external, !isInstalled,
                  let url = selected.downloadURL else { return }
            let model = selected
            let id = UUID()
            generation = id
            let task = downloads.downloadTask(with: url) { [weak self] temporary, response, error in
                guard let self, self.queue.sync(execute: { self.generation == id }) else { return }
                guard error == nil, let temp = temporary, let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    let message = error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    self.queue.async { self.completeTransfer(id, error: "badDownload", detail: message) }
                    return
                }
                // URLSession retains the temporary file only for the duration of this callback.
                self.verifyAndInstall(temp, model: model, id: id)
            }
            download = task
            update("downloading", " 0%")
            progressObserver = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let percent = Int(min(1, max(0, progress.fractionCompleted)) * 100)
                self?.queue.async { [weak self] in
                    guard let self, self.generation == id, self.state == "downloading" else { return }
                    self.update("downloading", " \(percent)%")
                }
            }
            task.resume()
        }
    }

    func importModel(from source: URL) {
        queue.sync {
            guard !external, source.isFileURL, download == nil, importStatus == nil else { return }
            let id = UUID()
            generation = id
            importStatus = "importing"
            notifyObservers()
            DispatchQueue.global(qos: .utility).async {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let manager = FileManager.default
                let staging = self.directory.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
                let temporary = staging.appendingPathComponent(source.lastPathComponent)
                defer { try? manager.removeItem(at: staging) }
                do {
                    guard try Self.ggufSize(source) != nil else {
                        self.queue.sync { self.completeTransfer(id, error: "invalidGGUF") }
                        return
                    }
                    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
                    try manager.copyItem(at: source, to: temporary)
                    let current = self.queue.sync {
                        guard self.generation == id else { return false }
                        self.importStatus = "verifying"
                        self.notifyObservers()
                        return true
                    }
                    guard current else { return }
                    guard let bytes = try Self.ggufSize(temporary),
                          let hash = ModelDownloader.sha256(ofFileAt: temporary) else {
                        self.queue.sync { self.completeTransfer(id, error: "invalidGGUF") }
                        return
                    }
                    try self.queue.sync {
                        guard self.generation == id else { return }
                        let model: PredictionModel
                        if let known = Self.builtInModels.first(where: { $0.bytes == bytes && $0.sha256 == hash }) {
                            model = known
                            try self.installFile(temporary, as: model)
                        } else {
                            let modelID = Self.customPrefix + hash
                            let customDirectory = Self.customDirectory(in: self.directory)
                            let destination = customDirectory.appendingPathComponent(modelID, isDirectory: true)
                            if let existing = Self.customModel(id: modelID, in: self.directory) {
                                model = existing
                            } else {
                                try manager.createDirectory(at: customDirectory, withIntermediateDirectories: true)
                                try manager.moveItem(at: staging, to: destination)
                                model = Self.customModel(id: modelID, file: destination.appendingPathComponent(source.lastPathComponent), bytes: bytes)
                            }
                        }
                        self.select(model)
                        self.completeTransfer(id)
                        self.modelFilesChanged(model.id)
                    }
                } catch {
                    self.queue.sync { self.completeTransfer(id, error: "ioError", detail: error.localizedDescription) }
                }
            }
        }
    }

    private func verifyAndInstall(_ temporary: URL, model: PredictionModel, id: UUID) {
        let current = queue.sync {
            guard generation == id else { return false }
            update("verifying")
            return true
        }
        guard current else { return }
        let values = try? temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.fileSize.map(Int64.init) == model.bytes,
              ModelDownloader.sha256(ofFileAt: temporary) == model.sha256 else {
            queue.sync { completeTransfer(id, error: "integrity") }
            return
        }
        queue.sync {
            guard generation == id else { return }
            do {
                try installFile(temporary, as: model)
                completeTransfer(id)
                modelFilesChanged(model.id)
            } catch {
                completeTransfer(id, error: "ioError", detail: error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        queue.sync {
            discardDownload()
            reconfigure()
        }
    }

    func deleteSelected() {
        queue.sync {
            discardDownload()
            stopServer()
            let model = selected
            let url = model.repository != nil ? file(for: model) : file(for: model).deletingLastPathComponent()
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                refreshLibrary(changedID: model.id)
                modelFilesChanged(model.id)
            } catch { update("ioError", " · " + error.localizedDescription) }
        }
    }

    func suspend() {
        queue.sync {
            guard process != nil || retiring != nil else { return }
            stopServer()
            showStandby()
        }
    }

    func shutdown() {
        queue.sync {
            enabled = false
            discardDownload()
            stopServer()
        }
    }

    private func completeTransfer(_ id: UUID, error: String? = nil, detail: String = "") {
        guard id == generation else { return }
        progressObserver = nil
        download = nil
        importStatus = nil
        if let error { update(error, detail.isEmpty ? "" : " · " + detail) }
        else { reconfigure() }
        notifyObservers()
    }

    private func discardDownload() {
        generation = UUID()
        progressObserver = nil
        download?.cancel()
        download = nil
        importStatus = nil
    }

    private func reconfigure() {
        retryAfter = .now()
        guard download == nil, importStatus == nil else { return }
        if process?.isRunning == true { update(ready == nil ? "starting" : "ready"); return }
        if purpose == .prediction && enabled && !external && isInstalled { startServer() }
        else { showStandby() }
    }

    private func showStandby() {
        if !enabled { update("disabled") }
        else if external { update("external") }
        else { update(isInstalled ? "installed" : "missing") }
    }

    private func update(_ name: String, _ extra: String = "") {
        guard name != state || extra != detail else { return }
        state = name
        detail = extra
        notifyObservers()
    }

    private func file(for model: PredictionModel) -> URL { directory.appendingPathComponent(model.filename) }
    private var isInstalled: Bool { Self.isInstalled(selected, in: directory) }

    private func select(_ model: PredictionModel) {
        guard selected.id != model.id else { return }
        stopServer()
        selected = model
        defaults.set(model.id, forKey: purpose.modelKey)
    }

    private func modelFilesChanged(_ id: String) {
        NotificationCenter.default.post(name: Self.libraryChanged, object: self, userInfo: ["id": id])
        notifyObservers()
    }

    private func refreshLibrary(changedID: String) {
        if selected.id == changedID {
            if !isInstalled {
                stopServer()
                if !purpose.models.contains(where: { $0.id == selected.id }) { select(purpose.models[0]) }
            }
            reconfigure()
        }
        notifyObservers()
    }

    private func installFile(_ temporary: URL, as model: PredictionModel) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = file(for: model)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    private static var builtInModels: [PredictionModel] { models + dictationModels }
    private static let customPrefix = "gguf-"

    private static func customDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("custom-models", isDirectory: true)
    }

    private static func catalog(for purpose: Purpose, in directory: URL) -> [PredictionModel] {
        let other = purpose == .prediction ? dictationModels : models
        let installed = other.filter { isInstalled($0, in: directory) }
        let entries = (try? FileManager.default.contentsOfDirectory(at: customDirectory(in: directory),
                                                                    includingPropertiesForKeys: nil)) ?? []
        let custom = entries.compactMap { customModel(id: $0.lastPathComponent, in: directory) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return purpose.models + installed + custom
    }

    private static func customModel(id: String, in directory: URL) -> PredictionModel? {
        guard id.hasPrefix(customPrefix) else { return nil }
        let hash = id.dropFirst(customPrefix.count)
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let folder = customDirectory(in: directory).appendingPathComponent(id, isDirectory: true)
        guard let info = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink == false,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let file = files.first(where: { $0.pathExtension.lowercased() == "gguf" }),
              let bytes = (try? ggufSize(file)) else { return nil }
        return customModel(id: id, file: file, bytes: bytes)
    }

    private static func customModel(id: String, file: URL, bytes: Int64) -> PredictionModel {
        PredictionModel(id: id, title: file.deletingPathExtension().lastPathComponent,
                        repository: nil, revision: nil, filename: "custom-models/\(id)/\(file.lastPathComponent)",
                        bytes: bytes, sha256: String(id.dropFirst(customPrefix.count)))
    }

    private static func isInstalled(_ model: PredictionModel, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(model.filename)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == model.bytes
    }

    // This checks the single-file container. llama.cpp checks that it can load the weights.
    private static func ggufSize(_ file: URL) throws -> Int64? {
        guard file.pathExtension.lowercased() == "gguf",
              file.deletingPathExtension().lastPathComponent.range(of: #"-\d{5}-of-\d{5}$"#,
                                                                  options: .regularExpression) == nil else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 24 else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 24), header.count == 24,
              header.starts(with: [0x47, 0x47, 0x55, 0x46]) else { return nil }
        let (version, tensors) = header.withUnsafeBytes { raw in
            (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        guard (2...3).contains(version), tensors > 0 else { return nil }
        return Int64(bytes)
    }

    private func startServer() {
        guard process == nil, enabled, !external, isInstalled else { return }
        if let retiring, retiring.isRunning {
            restartAfterRetirement = true
            update("starting")
            return
        }
        let server = purpose == .dictation ? Self.bundledServer() : Self.findServer()
        guard server != nil, let host = Bundle.main.executableURL else {
            retryAfter = .distantFuture
            update("serverMissing")
            return
        }
        let child = Process()
        let key = UUID().uuidString
        let alias = UUID().uuidString
        do {
            let port = try Self.availablePort()
            let endpoint = PredictionConnection(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                                                apiKey: key, modelID: selected.id, modelAlias: alias)
            let pipe = Pipe()
            child.executableURL = host
            child.arguments = ["--prediction-server-supervisor", purpose.rawValue, selected.id, String(port), alias]
            var environment = ProcessInfo.processInfo.environment
            environment["LLAMA_API_KEY"] = key
            child.environment = environment
            child.standardInput = pipe.fileHandleForReading
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] child in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if self.retiring === child {
                        self.retiring = nil
                        if self.restartAfterRetirement {
                            self.restartAfterRetirement = false
                            self.startServer()
                        }
                        return
                    }
                    guard self.process === child else { return }
                    self.stopServer()
                    self.retryAfter = .now() + .seconds(5)
                    self.update("exited", " (\(child.terminationStatus))")
                }
            }
            try child.run()
            try? pipe.fileHandleForReading.close()
            ownerPipe = pipe.fileHandleForWriting
            process = child
            update("starting")
            checkReadiness(child, endpoint: endpoint, alias: alias, deadline: .now() + .seconds(60))
        } catch {
            retryAfter = .now() + .seconds(5)
            update("startFailed", " · " + error.localizedDescription)
        }
    }

    private func checkReadiness(_ child: Process, endpoint: PredictionConnection, alias: String, deadline: DispatchTime) {
        guard process === child, child.isRunning else { return }
        guard DispatchTime.now() < deadline else {
            stopServer()
            retryAfter = .now() + .seconds(5)
            update("timeout")
            return
        }
        // A loaded model with our one-time alias proves readiness AND ownership of the loopback port.
        var check = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/models"))
        check.timeoutInterval = 1
        check.setValue("Bearer " + (endpoint.apiKey ?? ""), forHTTPHeaderField: "Authorization")
        let task = health.dataTask(with: check) { [weak self] data, response, _ in
            guard let self else { return }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let models = json?["data"] as? [[String: Any]]
            let ours = models?.contains { ($0["id"] as? String) == alias } == true
            self.queue.async {
                guard self.process === child, child.isRunning else { return }
                self.healthRequest = nil
                if (response as? HTTPURLResponse)?.statusCode == 200 && ours {
                    self.ready = endpoint
                    self.update("ready")
                    self.armIdleTimer()
                    self.checkInfillIfNeeded()
                } else {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                        self.checkReadiness(child, endpoint: endpoint, alias: alias, deadline: deadline)
                    }
                }
            }
        }
        healthRequest = task
        task.resume()
    }

    private func armIdleTimer() {
        if idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                self?.stopServer()
                self?.showStandby()
            }
            timer.resume()
            idleTimer = timer
        }
        idleTimer?.schedule(deadline: .now() + idleSeconds, leeway: .seconds(1))
    }

    private func stopServer() {
        idleTimer?.cancel()
        idleTimer = nil
        healthRequest?.cancel()
        healthRequest = nil
        resetInfill()
        ready = nil
        restartAfterRetirement = false
        if let process, process.isRunning { retiring = process }
        process = nil
        try? ownerPipe?.close()
        ownerPipe = nil
    }

    /// This mode starts before AppKit and never installs an input tap. EOF survives even a GUI
    /// crash or SIGKILL. The helper owns the exact child and never discovers it by process name.
    static func runSupervisorIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == "--prediction-server-supervisor" else { return }
        guard arguments.count == 6, let purpose = Purpose(rawValue: arguments[2]),
              let port = UInt16(arguments[4]), port > 0, UUID(uuidString: arguments[5]) != nil,
              let key = ProcessInfo.processInfo.environment["LLAMA_API_KEY"], UUID(uuidString: key) != nil else { exit(2) }
        let id = arguments[3]
        let directory = modelDirectory
        guard let model = builtInModels.first(where: { $0.id == id }) ?? customModel(id: id, in: directory),
              isInstalled(model, in: directory) else { exit(2) }
        let dictation = purpose == .dictation
        guard let binary = dictation ? bundledServer() : findServer() else { exit(2) }
        let modelURL = directory.appendingPathComponent(model.filename)
        let server = Process()
        server.executableURL = binary
        server.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", String(port),
                            "--ctx-size", dictation ? "4096" : "512", "--parallel", "1", "--threads", "2", "--poll", "0",
                            "--cache-ram", "0",
                            "--n-gpu-layers", gpuLayers, "--alias", arguments[5],
                            "--offline", "--no-webui", "--log-disable"]
        if dictation { server.arguments?.append("--no-context-shift") }
        if model.id == gemmaDictationModelID || (dictation && model.repository == nil) {
            server.arguments?.append(contentsOf: ["--reasoning", "off", "--chat-template-kwargs", #"{"enable_thinking":false}"#])
        }
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        do { exit(try supervise(server, owner: .standardInput)) }
        catch { exit(1) }
    }

    static func supervise(_ server: Process, owner: FileHandle) throws -> Int32 {
        try server.run()
        DispatchQueue.global(qos: .utility).async {
            _ = try? owner.read(upToCount: 1)
            guard server.isRunning else { return }
            server.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) {
                if server.isRunning { kill(server.processIdentifier, SIGKILL) }
            }
        }
        server.waitUntilExit()
        return server.terminationStatus
    }

    private static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/prediction-models", isDirectory: true)
    }

    private static var gpuLayers: String {
        #if arch(arm64)
        return "99"
        #else
        return "0"
        #endif
    }

    private static func bundledServer() -> URL? {
        #if arch(x86_64)
        let bundled = "Contents/Helpers/llama/x86_64/llama-server"
        #else
        let bundled = "Contents/Helpers/llama/llama-server"
        #endif
        let url = Bundle.main.bundleURL.appendingPathComponent(bundled)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func findServer() -> URL? {
        if let server = bundledServer() { return server }
        let paths = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                     "/Applications/Ollama.app/Contents/Resources/llama-server"]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var assignedLength = length
        try withUnsafeMutablePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard bind(fd, pointer, length) == 0, getsockname(fd, pointer, &assignedLength) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
