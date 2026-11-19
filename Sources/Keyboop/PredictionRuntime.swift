import AppKit
import Darwin
import Foundation

struct PredictionModel {
    let id: String
    let title: String
    let repository: String
    let revision: String
    let filename: String
    let bytes: Int64
    let sha256: String

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
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
    enum Purpose {
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
    static let dictationModels = [
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
    // Network IO and digest calculation run on URLSession's delegate queues.
    private let queue = DispatchQueue(label: "ru.keyboop.prediction-runtime", qos: .utility)
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
        self.directory = directory ?? Self.modelDirectory
        self.idleSeconds = idleSeconds
        let selectedID = defaults.string(forKey: purpose.modelKey)
        selected = purpose.models.first { $0.id == selectedID } ?? purpose.models[0]
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
    }

    var selectedModelID: String {
        get { queue.sync { selected.id } }
        set {
            queue.sync {
                guard let model = purpose.models.first(where: { $0.id == newValue }), model.id != selected.id else { return }
                discardDownload()
                stopServer()
                selected = model
                defaults.set(model.id, forKey: purpose.modelKey)
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
        queue.sync { enabled && (external || (isInstalled && (ready != nil || state == "installed"))) }
    }

    var isDownloading: Bool { queue.sync { download != nil } }
    var hasSelectedModel: Bool { queue.sync { isInstalled } }
    var installedModelIDs: Set<String> {
        queue.sync { Set(purpose.models.filter { size(file(for: $0)) == $0.bytes }.map(\.id)) }
    }
    static var hasBuiltInServer: Bool { bundledServer() != nil }
    var statusText: String {
        let (key, extra) = queue.sync { (state, detail) }
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
            guard download == nil, !external, !isInstalled else { return }
            let model = selected
            let id = UUID()
            generation = id
            let task = downloads.downloadTask(with: model.downloadURL) { [weak self] temporary, response, error in
                guard let self, self.queue.sync(execute: { self.generation == id }) else { return }
                guard error == nil, let temp = temporary, let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    let message = error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    self.queue.async { self.completeDownload(id, error: "badDownload", detail: message) }
                    return
                }
                self.queue.sync { if self.generation == id { self.update("verifying") } }
                guard self.size(temp) == model.bytes,
                      ModelDownloader.sha256(ofFileAt: temp) == model.sha256 else {
                    self.queue.async { self.completeDownload(id, error: "integrity") }
                    return
                }
                // URLSession retains the temporary file only for the duration of this callback.
                self.queue.sync {
                    guard self.generation == id else { return }
                    do {
                        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                        let destination = self.file(for: model)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
                        } else {
                            try FileManager.default.moveItem(at: temp, to: destination)
                        }
                        self.completeDownload(id)
                    } catch {
                        self.completeDownload(id, error: "ioError", detail: error.localizedDescription)
                    }
                }
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
            let url = file(for: selected)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                showStandby()
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

    private func completeDownload(_ id: UUID, error: String? = nil, detail: String = "") {
        guard id == generation else { return }
        progressObserver = nil
        download = nil
        if let error { update(error, detail.isEmpty ? "" : " · " + detail) }
        else { reconfigure() }
    }

    private func discardDownload() {
        generation = UUID()
        progressObserver = nil
        download?.cancel()
        download = nil
    }

    private func reconfigure() {
        retryAfter = .now()
        guard download == nil else { return }
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
    private func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
    private var isInstalled: Bool { size(file(for: selected)) == selected.bytes }

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
            child.arguments = ["--prediction-server-supervisor", selected.id, String(port), alias]
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
        guard arguments.count == 5, let model = (models + dictationModels).first(where: { $0.id == arguments[2] }),
              let port = UInt16(arguments[3]), port > 0, UUID(uuidString: arguments[4]) != nil,
              let key = ProcessInfo.processInfo.environment["LLAMA_API_KEY"], UUID(uuidString: key) != nil else { exit(2) }
        let dictation = dictationModels.contains { $0.id == model.id }
        guard let binary = dictation ? bundledServer() : findServer() else { exit(2) }
        let modelURL = modelDirectory.appendingPathComponent(model.filename)
        let server = Process()
        server.executableURL = binary
        server.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", String(port),
                            "--ctx-size", dictation ? "4096" : "512", "--parallel", "1", "--threads", "2", "--poll", "0",
                            "--cache-ram", "0",
                            "--n-gpu-layers", gpuLayers, "--alias", arguments[4],
                            "--offline", "--no-webui", "--log-disable"]
        if dictation { server.arguments?.append("--no-context-shift") }
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
