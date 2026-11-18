import Darwin
import Foundation

/// Owns the optional SAGE model files and the one-shot correction helper. Corrections run in a
/// separate process, with token IDs passed over pipes. Only model downloads use the network.
final class SageRuntime {
    static let shared = SageRuntime()
    static let didChange = Notification.Name("keyboop.sageRuntimeChanged")

    enum Failure: String, LocalizedError, Equatable {
        case unavailable, missing, download, integrity, install, empty, tooLong, busy, timeout, inference

        var localizationKey: String { "sage.error." + rawValue }
        var errorDescription: String? { L10n.t(localizationKey) }
    }

    enum State: Equatable {
        case unavailable
        case missing
        case downloading(Double)
        case ready
        case failed(Failure)
    }

    struct Artifact {
        let filename: String
        let url: URL
        let bytes: Int64
        let sha256: String

        init(filename: String, repository: String, revision: String, bytes: Int64, sha256: String) {
            self.filename = filename
            self.url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    static let modelArtifacts: [Artifact] = {
        let weights = "krut42/voice-sage95m-fp16"
        let weightRevision = "3b0170d9388c7640f28870d60971f19b74b13bc5"
        let tokenizer = "ai-forever/sage-fredt5-distilled-95m"
        let tokenizerRevision = "ed51b4a46603931380951a3d8456685c9215864f"
        return [
            Artifact(filename: "encoder_model.onnx", repository: weights, revision: weightRevision,
                     bytes: 97_863_391, sha256: "0181db616a7336b163d5796b8c3975756234357233e1595722b34831483b747a"),
            Artifact(filename: "decoder_model.onnx", repository: weights, revision: weightRevision,
                     bytes: 162_149_131, sha256: "142f189f6a4483b15bab972ce6ea80db9846350b68051dd0852b40341962f96e"),
            Artifact(filename: "vocab.json", repository: tokenizer, revision: tokenizerRevision,
                     bytes: 1_813_640, sha256: "a1bbb734326805d8ef4c6ff183cc6b7bbaa382e666f5eaa2c9b2381c4ea89378"),
            Artifact(filename: "merges.txt", repository: tokenizer, revision: tokenizerRevision,
                     bytes: 1_270_925, sha256: "bd05ba8658a199897510cd84cd98ec1424c812259db6e03319c33a5bfcac2b90")
        ]
    }()

    private final class Download {
        let staging: URL
        var index = 0
        var completedBytes: Int64 = 0
        var task: URLSessionDownloadTask?
        var progress: NSKeyValueObservation?

        init(staging: URL) { self.staging = staging }
    }

    private final class Correction {
        let completion: (Result<String, Error>) -> Void
        var process: Process?
        init(_ completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
    }

    private let queue = DispatchQueue(label: "ru.keyboop.sage-runtime", qos: .utility)
    private let worker = DispatchQueue(label: "ru.keyboop.sage-correction", qos: .userInitiated)
    private let session: URLSession
    private let directory: URL
    private let helper: URL
    private let artifacts: [Artifact]
    private let timeout: TimeInterval
    private var downloadJob: Download?
    private var correction: Correction?
    private var stateValue: State = .missing

    static let maxInputBytes = 4096
    private static let maxOutputBytes = 8192

    var state: State { queue.sync { stateValue } }
    var downloadByteCount: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }

    init(directory: URL = SageRuntime.modelDirectory, helper: URL = SageRuntime.helperURL,
         artifacts: [Artifact] = SageRuntime.modelArtifacts, timeout: TimeInterval = 30) {
        self.directory = directory
        self.helper = helper
        self.artifacts = artifacts
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 45 * 60
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        stateValue = installedState()
    }

    // MARK: Downloads

    func download() {
        queue.async {
            guard self.downloadJob == nil else { return }
            let state = self.installedState()
            guard state == .missing else { self.update(state); return }
            let staging = self.directory.deletingLastPathComponent()
                .appendingPathComponent(".sage-download-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let job = Download(staging: staging)
                self.downloadJob = job
                self.update(.downloading(0))
                self.startNextArtifact(job)
            } catch {
                self.update(.failed(.install))
            }
        }
    }

    func cancelDownload() {
        queue.async {
            guard self.downloadJob != nil else { return }
            self.discardDownload()
            self.update(self.installedState())
        }
    }

    func deleteModel() {
        queue.async {
            self.discardDownload()
            self.cancelCorrection()
            do {
                if FileManager.default.fileExists(atPath: self.directory.path) {
                    try FileManager.default.removeItem(at: self.directory)
                }
                self.update(self.installedState())
            } catch {
                self.update(.failed(.install))
            }
        }
    }

    private func startNextArtifact(_ job: Download) {
        guard job.index < artifacts.count else {
            do {
                // Every member has been verified. Both paths are on the same volume and this
                // rename installs the set as one directory, so readers never see half a model.
                if installedState() != .ready {
                    if FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                    try FileManager.default.moveItem(at: job.staging, to: directory)
                }
                finishDownload(job, state: .ready)
            } catch {
                finishDownload(job, state: .failed(.install))
            }
            return
        }

        let artifact = artifacts[job.index]
        let index = job.index
        let task = session.downloadTask(with: artifact.url) { [weak self, weak job] temporary, response, error in
            guard let self, let job, self.queue.sync(execute: { self.downloadJob === job }) else { return }
            guard error == nil, let temporary, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.queue.async { self.finishDownload(job, state: .failed(.download)) }
                return
            }
            guard Self.size(of: temporary) == artifact.bytes,
                  ModelDownloader.sha256(ofFileAt: temporary) == artifact.sha256 else {
                self.queue.async { self.finishDownload(job, state: .failed(.integrity)) }
                return
            }
            // URLSession may reclaim the temporary file when this callback returns.
            self.queue.sync {
                guard self.downloadJob === job, job.index == index else { return }
                do {
                    let target = job.staging.appendingPathComponent(artifact.filename)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    job.progress = nil
                    job.task = nil
                    job.completedBytes += artifact.bytes
                    job.index += 1
                    self.startNextArtifact(job)
                } catch {
                    self.finishDownload(job, state: .failed(.install))
                }
            }
        }
        job.task = task
        job.progress = task.progress.observe(\.completedUnitCount) { [weak self, weak job] progress, _ in
            let received = max(0, min(progress.completedUnitCount, artifact.bytes))
            self?.queue.async { [weak self, weak job] in
                guard let self, let job, self.downloadJob === job, job.index == index else { return }
                let fraction = Double(job.completedBytes + received) / Double(self.downloadByteCount)
                self.update(.downloading((fraction * 100).rounded(.down) / 100))
            }
        }
        task.resume()
    }

    private func finishDownload(_ job: Download, state: State) {
        guard downloadJob === job else { return }
        discardDownload()
        update(state)
    }

    private func discardDownload() {
        guard let job = downloadJob else { return }
        downloadJob = nil
        job.progress = nil
        job.task?.cancel()
        try? FileManager.default.removeItem(at: job.staging)
    }

    // MARK: Correction

    func correct(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [self] in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.deliver(.failure(Failure.empty), completion)
            }
            guard text.utf8.count <= Self.maxInputBytes else {
                return Self.deliver(.failure(Failure.tooLong), completion)
            }
            guard self.correction == nil else {
                return Self.deliver(.failure(Failure.busy), completion)
            }
            let installed = self.installedState()
            guard installed == .ready else {
                return Self.deliver(.failure(installed == .unavailable ? Failure.unavailable : Failure.missing), completion)
            }

            let job = Correction(completion)
            self.correction = job
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self, weak job] in
                guard let self, let job, self.correction === job else { return }
                self.stop(job.process)
                self.completeCorrection(job, result: .failure(Failure.timeout))
            }
            self.worker.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.runCorrection(text, job: job) }
                self.queue.async { self.completeCorrection(job, result: result) }
            }
        }
    }

    private func runCorrection(_ text: String, job: Correction) throws -> String {
        let tokenizer: SageTokenizer
        do {
            tokenizer = try SageTokenizer(vocabulary: directory.appendingPathComponent("vocab.json"),
                                          merges: directory.appendingPathComponent("merges.txt"))
        } catch {
            throw Failure.integrity
        }
        let ids: [Int64]
        do {
            ids = try tokenizer.encode(text)
        } catch SageTokenizer.Failure.inputTooLong {
            throw Failure.tooLong
        } catch {
            throw Failure.integrity
        }
        guard !ids.isEmpty, ids.count <= SageTokenizer.maximumInputTokens else { throw Failure.tooLong }

        let process = Process()
        process.executableURL = helper
        process.arguments = ["encoder_model.onnx", "decoder_model.onnx"].map {
            directory.appendingPathComponent($0).path
        }
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        // Early helper exit must report an error to the app even if the pipe has no reader.
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.inference }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try queue.sync {
            guard correction === job else { throw CocoaError(.userCancelled) }
            do {
                try process.run()
                job.process = process
            } catch {
                throw Failure.inference
            }
        }
        defer {
            stop(process)
            process.waitUntilExit()
        }

        do {
            try writer.write(contentsOf: Data((ids.map(String.init).joined(separator: " ") + "\n").utf8))
            try writer.close()
        } catch {
            try? writer.close()
            throw Failure.inference
        }

        let reader = output.fileHandleForReading
        var outputBytes = Data()
        do {
            while let chunk = try reader.read(upToCount: 1024), !chunk.isEmpty {
                outputBytes.append(chunk)
                guard outputBytes.count <= Self.maxOutputBytes else { throw Failure.inference }
            }
        } catch {
            throw Failure.inference
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let line = String(data: outputBytes, encoding: .utf8) else {
            throw Failure.inference
        }
        let fields = line.split(whereSeparator: \.isWhitespace)
        let tokens = fields.compactMap { Int64($0) }
        guard !tokens.isEmpty, tokens.count <= SageTokenizer.maximumOutputTokens, tokens.count == fields.count,
              let result = try? tokenizer.decode(tokens),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.inference
        }
        return result
    }

    private func completeCorrection(_ job: Correction, result: Result<String, Error>) {
        guard correction === job else { return }
        correction = nil
        Self.deliver(result, job.completion)
    }

    private func cancelCorrection() {
        guard let job = correction else { return }
        stop(job.process)
        completeCorrection(job, result: .failure(CocoaError(.userCancelled)))
    }

    func shutdown() {
        queue.sync {
            discardDownload()
            cancelCorrection()
            update(installedState())
        }
    }

    private func stop(_ process: Process?) {
        if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    private static func deliver(_ result: Result<String, Error>,
                                _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: State

    private func installedState() -> State {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return .unavailable }
        guard artifacts.allSatisfy({ Self.size(of: directory.appendingPathComponent($0.filename)) == $0.bytes })
        else { return .missing }
        return .ready
    }

    private func update(_ state: State) {
        guard stateValue != state else { return }
        stateValue = state
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private static func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop/sage-distilled-95m-v1", isDirectory: true)
    }

    private static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sage/KeyboopSage")
    }
}
