import Foundation
import CryptoKit

/// Загрузка, верификация и каталог локальных ASR-моделей для `transcribe.cpp`.
/// Каталог ограничен моделями с поддержкой русского языка (GigaAM v3, Parakeet, Whisper, Qwen3-ASR и др.).
/// Сеть используется ТОЛЬКО по явному действию пользователя (скачать модель или обновить каталог).
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    /// Текущая встроенная версия `transcribe.cpp` — не предлагаем модели, требующие более новый движок.
    static let engineVersion = "0.4.2"
    static let recommendedOrder = ["gigaam-v3-e2e-rnnt", "parakeet-tdt-0.6b-v3", "whisper-large-v3-turbo"]
    static let defaultModelId = "gigaam-v3-e2e-rnnt"
    static let defaultOnboardingModelId = "gigaam-v3-e2e-rnnt"
    static let upstreamCatalogURL = URL(string: "https://raw.githubusercontent.com/cjpais/Handy/main/src-tauri/src/catalog/catalog.json")!
    private static let mirrorBase = "https://blob.handy.computer"

    struct Capabilities: Codable, Equatable {
        let streaming: Bool
        let translate: Bool
        let languageDetection: Bool
        let timestamps: Bool

        init(streaming: Bool = false, translate: Bool = false, languageDetection: Bool = false, timestamps: Bool = false) {
            self.streaming = streaming
            self.translate = translate
            self.languageDetection = languageDetection
            self.timestamps = timestamps
        }
    }

    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let englishDescription: String
        let repository: String
        let revision: String
        let family: String
        let parameters: String?
        let languages: [String]
        let capabilities: Capabilities
        let quant: String
        let curated: Bool
        let minEngine: String?
        let filename: String
        let sizeBytes: Int64
        let sha256: String
        let ruErrorPercent: Double?
        let accelRtf: Double?
        let cpuRtf: Double?

        var supportsRussian: Bool {
            languages.contains { $0 == "ru" || $0.hasPrefix("ru-") }
        }

        var isRussianOnly: Bool {
            languages.count == 1 && supportsRussian
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }

        var hfURL: URL? {
            guard !repository.isEmpty, !revision.isEmpty, !filename.isEmpty else { return nil }
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")
        }

        var mirrorURL: URL? {
            guard !repository.isEmpty, !revision.isEmpty, !filename.isEmpty else { return nil }
            return URL(string: "\(ModelDownloader.mirrorBase)/\(repository)/\(revision)/\(filename)")
        }

        var downloadURLs: [URL] {
            [hfURL, mirrorURL].compactMap { $0 }
        }
    }

    // MARK: - Raw JSON Schema (compatible with Handy catalog schema v2)

    private struct RawCatalogRoot: Decodable {
        let schema: Int
        let transcribeCpp: String?
        let models: [RawCatalogModel]
        let results: [String: RawBenchmarkResult]?
    }

    private struct RawCatalogModel: Decodable {
        let id: String
        let name: String
        let description: String?
        let repository: String
        let revision: String
        let family: String
        let parameters: String?
        let languages: [String]
        let capabilities: Capabilities
        let quant: String
        let role: String
        let curated: Bool?
        let minEngine: String?
        let files: [String: RawCatalogFile]
    }

    private struct RawCatalogFile: Decodable {
        let filename: String
        let size: Int64
        let sha256: String
    }

    private struct RawBenchmarkResult: Decodable {
        let accuracy: [String: RawAccuracyCell]?
        let performance: RawPerformance?
    }

    private struct RawAccuracyCell: Decodable {
        let error: Double
    }

    private struct RawPerformance: Decodable {
        let accelerated: Double?
        let cpu: Double?
    }

    // MARK: - Catalog Loading & Filtering

    private static var cachedCatalog: [Model]?

    /// Каталог ASR-моделей с поддержкой русского языка.
    /// Сначала берём пользовательски обновлённый `Application Support/Keyboop/models-catalog.json`,
    /// иначе — бандловый `Resources/models-catalog.json`.
    static var catalog: [Model] {
        if let cachedCatalog { return cachedCatalog }
        let loaded = loadCatalogFromDiskOrBundle()
        cachedCatalog = loaded
        return loaded
    }

    static var cachedCatalogURL: URL {
        VoiceController.modelsDir.deletingLastPathComponent().appendingPathComponent("models-catalog.json")
    }

    private static func loadCatalogFromDiskOrBundle() -> [Model] {
        if let data = try? Data(contentsOf: cachedCatalogURL),
           let parsed = decodeRussianASRModels(from: data), !parsed.isEmpty {
            return parsed
        }
        if let url = Bundle.main.url(forResource: "models-catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = decodeRussianASRModels(from: data), !parsed.isEmpty {
            return parsed
        }
        return fallbackCatalog
    }

    static func invalidateCatalogCache() {
        cachedCatalog = nil
    }

    /// Разбирает JSON каталога (schema v2), оставляя только ASR-модели с поддержкой русского языка
    /// и совместимые с текущей версией `transcribe.cpp`.
    static func decodeRussianASRModels(from data: Data, maxEngineVersion: String = engineVersion) -> [Model]? {
        guard let root = try? JSONDecoder().decode(RawCatalogRoot.self, from: data),
              root.schema == 2 else { return nil }

        let results = root.results ?? [:]
        let filtered: [Model] = root.models.compactMap { raw in
            guard raw.role == "asr" else { return nil }
            guard raw.languages.contains(where: { $0 == "ru" || $0.hasPrefix("ru-") }) else { return nil }
            if let minEngine = raw.minEngine, compareSemver(minEngine, maxEngineVersion) == .orderedDescending {
                return nil
            }
            guard let file = raw.files[raw.quant] ?? raw.files["Q8_0"] ?? raw.files.values.first else {
                return nil
            }
            guard !file.filename.contains("/"), file.size > 0, file.sha256.count == 64 else {
                return nil
            }
            let bench = results[raw.id]
            let ruErr = bench?.accuracy?["ru"]?.error
            return Model(
                id: raw.id,
                name: raw.name,
                englishDescription: raw.description ?? "",
                repository: raw.repository,
                revision: raw.revision,
                family: raw.family,
                parameters: raw.parameters,
                languages: raw.languages,
                capabilities: raw.capabilities,
                quant: raw.quant,
                curated: raw.curated ?? false,
                minEngine: raw.minEngine,
                filename: file.filename,
                sizeBytes: file.size,
                sha256: file.sha256,
                ruErrorPercent: ruErr,
                accelRtf: bench?.performance?.accelerated,
                cpuRtf: bench?.performance?.cpu
            )
        }
        return sortModels(filtered)
    }

    private static func sortModels(_ models: [Model]) -> [Model] {
        models.sorted { a, b in
            let ra = recommendedOrder.firstIndex(of: a.id)
            let rb = recommendedOrder.firstIndex(of: b.id)
            switch (ra, rb) {
            case let (ia?, ib?): return ia < ib
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.curated != b.curated { return a.curated && !b.curated }
            let ea = a.ruErrorPercent ?? 999
            let eb = b.ruErrorPercent ?? 999
            if abs(ea - eb) > 0.05 { return ea < eb }
            return a.sizeBytes < b.sizeBytes
        }
    }

    private static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
                .prefix(3)
                .map { Int($0) ?? 0 }
        }
        let a = parts(lhs)
        let b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Аварийный минимальный каталог на случай запуска вне `.app`-бандла (например, из CLI-тестов).
    private static let fallbackCatalog: [Model] = [
        Model(
            id: "gigaam-v3-e2e-rnnt",
            name: "GigaAM v3 E2E-RNN-T",
            englishDescription: "Best for Russian dictation. English may be unreliable.",
            repository: "handy-computer/gigaam-v3-e2e-rnnt-gguf",
            revision: "f719d70812344f4d0fb8c11c0887b190501a7465",
            family: "gigaam",
            parameters: "223M",
            languages: ["ru"],
            capabilities: Capabilities(streaming: false, translate: false, languageDetection: false, timestamps: true),
            quant: "Q8_0",
            curated: true,
            minEngine: "0.2.4",
            filename: "gigaam-v3-e2e-rnnt-Q8_0.gguf",
            sizeBytes: 273724832,
            sha256: "78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a",
            ruErrorPercent: 5.35,
            accelRtf: 15.02,
            cpuRtf: 7.875
        ),
        Model(
            id: "parakeet-tdt-0.6b-v3",
            name: "Parakeet TDT 0.6B v3",
            englishDescription: "Fast and accurate, great overall multilingual pick",
            repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            family: "parakeet",
            parameters: "627M",
            languages: ["en", "ru"],
            capabilities: Capabilities(streaming: false, translate: false, languageDetection: true, timestamps: true),
            quant: "Q8_0",
            curated: true,
            minEngine: "0.2.4",
            filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            sizeBytes: 739508576,
            sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
            ruErrorPercent: 6.54,
            accelRtf: 25.065,
            cpuRtf: 13.655
        ),
        Model(
            id: "whisper-large-v3-turbo",
            name: "Whisper Large v3 Turbo",
            englishDescription: "Accurate in many languages. Slow without a GPU",
            repository: "handy-computer/whisper-large-v3-turbo-gguf",
            revision: "5eaf945c7978e564bae5b28a5b1639dd93c2bfb1",
            family: "whisper",
            parameters: "809M",
            languages: ["ru", "en"],
            capabilities: Capabilities(streaming: false, translate: false, languageDetection: true, timestamps: true),
            quant: "Q8_0",
            curated: true,
            minEngine: "0.2.4",
            filename: "whisper-large-v3-turbo-Q8_0.gguf",
            sizeBytes: 886381760,
            sha256: "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183",
            ruErrorPercent: 5.93,
            accelRtf: 3.095,
            cpuRtf: 1.43
        ),
    ]

    static func model(id: String) -> Model? {
        catalog.first(where: { $0.id == id })
    }

    static func filename(for id: String) -> String {
        if let entry = model(id: id) { return entry.filename }
        return "\(id).gguf"
    }

    static func resolvedModelPath(for id: String) -> String {
        let dir = VoiceController.modelsDir
        if let entry = model(id: id) {
            let candidate = dir.appendingPathComponent(entry.filename).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        let gguf = dir.appendingPathComponent("\(id).gguf").path
        if FileManager.default.fileExists(atPath: gguf) { return gguf }
        let legacyBin = dir.appendingPathComponent("ggml-\(id).bin").path
        if FileManager.default.fileExists(atPath: legacyBin) { return legacyBin }
        if let entry = model(id: id) {
            return dir.appendingPathComponent(entry.filename).path
        }
        return gguf
    }

    /// Любая совместимая модель на диске (для автоматического восстановления при смене ID).
    static func firstInstalledModelId() -> String? {
        if let match = catalog.first(where: { FileManager.default.fileExists(atPath: VoiceController.modelsDir.appendingPathComponent($0.filename).path) }) {
            return match.id
        }
        // Наследие прошлых версий: ggml-<id>.bin
        if let legacy = ["large-v3-turbo", "medium", "small", "base", "tiny"].first(where: {
            FileManager.default.fileExists(atPath: VoiceController.modelsDir.appendingPathComponent("ggml-\($0).bin").path)
        }) {
            return legacy
        }
        return nil
    }

    func isInstalled(_ id: String) -> Bool {
        let dir = VoiceController.modelsDir
        if let entry = Self.model(id: id) {
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.filename).path)
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id).gguf").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("ggml-\(id).bin").path)
    }

    // MARK: - Online Catalog Refresh (Explicit User Action Only)

    /// Обновляет список русских ASR-моделей из upstream-каталога Handy, сохраняя отфильтрованную
    /// копию в `Application Support/Keyboop/models-catalog.json`. Запускается ТОЛЬКО по кнопке.
    func refreshCatalog(completion: @escaping (Result<Int, Error>) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        let session = URLSession(configuration: cfg)
        session.dataTask(with: Self.upstreamCatalogURL) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let err = NSError(domain: "Keyboop.Catalog", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            guard let data,
                  let decoded = Self.decodeRussianASRModels(from: data), !decoded.isEmpty,
                  let rawRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = rawRoot["models"] as? [[String: Any]] else {
                let err = NSError(domain: "Keyboop.Catalog", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Неверный формат каталога моделей"])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            // Сохраняем в кэш только русскоязычные ASR-модели (экономим место и парсинг на старте).
            let ruIds = Set(decoded.map(\.id))
            let filteredModels = models.filter { ($0["id"] as? String).map(ruIds.contains) == true }
            var compact: [String: Any] = [
                "schema": rawRoot["schema"] ?? 2,
                "transcribeCpp": rawRoot["transcribeCpp"] ?? Self.engineVersion,
                "models": filteredModels
            ]
            if let rawResults = rawRoot["results"] as? [String: Any] {
                compact["results"] = rawResults.filter { ruIds.contains($0.key) }
            }
            do {
                let encoded = try JSONSerialization.data(withJSONObject: compact, options: [.prettyPrinted])
                let dst = Self.cachedCatalogURL
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: dst, options: .atomic)
                Self.invalidateCatalogCache()
                let count = Self.catalog.count
                kbLog("catalog refreshed: \(count) Russian ASR models")
                DispatchQueue.main.async { completion(.success(count)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    // MARK: - Model Downloading

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var targetId = ""
    private var candidateURLs: [URL] = []
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Bool) -> Void)?
    var downloadingName: String? { task != nil ? targetId : nil }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func download(_ id: String, progress: @escaping (Double) -> Void, done: @escaping (Bool) -> Void) {
        guard let model = Self.model(id: id), !model.downloadURLs.isEmpty else {
            kbLog("model download unknown id: \(id)")
            DispatchQueue.main.async { done(false) }
            return
        }
        task?.cancel()
        targetId = id
        candidateURLs = model.downloadURLs
        onProgress = progress
        onDone = done
        startNextCandidate()
    }

    private func startNextCandidate() {
        guard !candidateURLs.isEmpty else {
            kbLog("model download FAILED \(targetId): all sources exhausted")
            task = nil
            DispatchQueue.main.async { self.onDone?(false) }
            return
        }
        let url = candidateURLs.removeFirst()
        kbLog("model download start: \(targetId) -> \(url.host ?? "?")")
        task = session.downloadTask(with: url)
        task?.resume()
    }

    private func failOrFallback(_ reason: String) {
        if !candidateURLs.isEmpty {
            kbLog("model source failed (\(targetId), \(reason)) -> trying fallback mirror")
            startNextCandidate()
            return
        }
        kbLog("model download error \(targetId): \(reason)")
        task = nil
        DispatchQueue.main.async { self.onDone?(false) }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func delete(_ id: String, completion: @escaping (Bool) -> Void) {
        let dir = VoiceController.modelsDir
        var paths = [Self.resolvedModelPath(for: id)]
        paths.append(dir.appendingPathComponent("\(id).gguf").path)
        paths.append(dir.appendingPathComponent("ggml-\(id).bin").path)
        let uniquePaths = Array(Set(paths))
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            for path in uniquePaths where FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    kbLog("model deleted: \(URL(fileURLWithPath: path).lastPathComponent)")
                } catch {
                    ok = false
                    kbLog("model delete error \(id): \(error)")
                }
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask == self.task else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (Self.model(id: targetId)?.sizeBytes ?? 0)
        guard expected > 0 else { return }
        let p = min(1.0, Double(totalBytesWritten) / Double(expected))
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask == self.task else { return }
        let id = targetId
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            failOrFallback("HTTP \(http.statusCode)")
            return
        }
        if let expected = Self.model(id: id)?.sha256,
           let actual = Self.sha256(ofFileAt: location), actual != expected {
            kbLog("model integrity FAIL \(id): hash mismatch")
            try? FileManager.default.removeItem(at: location)
            failOrFallback("sha256 mismatch")
            return
        }
        let filename = Self.filename(for: id)
        let dest = VoiceController.modelsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        kbLog(ok ? "model downloaded+verified: \(id) (\(filename))" : "model install error \(id): move failed")
        task = nil
        DispatchQueue.main.async { self.onDone?(ok) }
    }

    static func sha256(ofFileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fh.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == self.task, let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            self.task = nil
            return
        }
        failOrFallback(error.localizedDescription)
    }
}
