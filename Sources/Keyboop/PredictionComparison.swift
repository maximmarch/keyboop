import Foundation

private struct Trace: Decodable {
    let id: String
    let group: String
    let text: String
    let nextKeyMS: Double?

    var prompt: String { String(text.prefix(while: { $0 != "|" })) }
    var reference: String { String(text.dropFirst(prompt.count + 1)) }
    var completing: Bool { prompt.last != " " }
    var word: String { String(prompt.split(whereSeparator: \.isWhitespace).last ?? "") }
}

private struct Sample {
    let trace: Trace
    var first: String?
    var latest: String?
    var firstWordMS: Double?
    var lookupMS: Double?
    var failure: String?
    var interrupted = false

    // Score only complete chunks. Each accepted word costs one invocation of the shortcut.
    var savedKeys: Int {
        guard let latest else { return 0 }
        var accepted = ""
        var count = 0
        for word in latest.split(separator: " ") {
            let next = accepted.isEmpty ? String(word) : accepted + " " + word
            guard trace.reference.hasPrefix(next) else { break }
            let rest = trace.reference.dropFirst(next.count)
            guard rest.first?.isLetter != true else { break }
            accepted = next
            count += 1
        }
        return max(0, accepted.count - count)
    }

    var hit: Bool {
        guard let word = first?.split(separator: " ").first, trace.reference.hasPrefix(word) else { return false }
        return trace.reference.dropFirst(word.count).first?.isLetter != true
    }
}

private let appDebounceMS = 120.0
private let modelBudgetMS = 650.0

private func elapsedMS(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private struct DictionaryPredictor {
    private struct CompletionData: Decodable {
        let words: Set<String>
        let frequencies: [String: Int]
    }

    let index: WordCompletionIndex
    let next: NextWordIndex

    init(resources: URL, completionData: URL? = nil) throws {
        let decoder = JSONDecoder()
        let completion: CompletionData
        if let completionData {
            completion = try decoder.decode(CompletionData.self, from: Data(contentsOf: completionData))
            guard completion.frequencies.values.allSatisfy({ (1...1_000_000_000).contains($0) }) else {
                throw EvalError("Completion frequencies must be positive counts per billion")
            }
        } else {
            let path = resources.appendingPathComponent("word_frequencies.json")
            let frequencies = try decoder.decode([String: Int].self, from: Data(contentsOf: path))
            completion = CompletionData(words: [], frequencies: frequencies)
        }
        let data = LayoutData.shared
        guard data.isLoaded else { throw EvalError("Missing layout dictionaries") }
        index = WordCompletionIndex(words: data.wordsRu.union(data.wordsEn).union(completion.words),
                                    frequencies: completion.frequencies)
        next = try decoder.decode(NextWordIndex.self, from: Data(contentsOf: resources.appendingPathComponent("next_words.json")))
    }

    func sample(_ trace: Trace) -> Sample {
        var result = Sample(trace: trace)
        if let nextKey = trace.nextKeyMS, nextKey <= appDebounceMS {
            result.interrupted = true
            return result
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let suffix: String?
        if trace.completing {
            let preferred = next.predict(before: String(trace.prompt.dropLast(trace.word.count)), startsAtFieldStart: true)
            suffix = index.suffix(for: trace.word, preferredWord: preferred)
        } else {
            suffix = next.predict(before: trace.prompt, startsAtFieldStart: true)
        }
        let duration = elapsedMS(start)
        result.lookupMS = duration
        if let nextKey = trace.nextKeyMS, duration + appDebounceMS >= nextKey {
            result.interrupted = true
        } else if let suffix {
            result.first = suffix
            result.latest = suffix
            result.firstWordMS = duration
        }
        return result
    }
}

private struct EvalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class ResultCollector {
    let done = DispatchSemaphore(value: 0)
    let start = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var row: Sample
    private var closed = false
    init(_ trace: Trace) { row = Sample(trace: trace) }

    func update(_ text: String?, final: Bool, failure: String? = nil) {
        lock.withLock {
            guard !closed else { return }
            let elapsed = elapsedMS(start)
            let expired = elapsed >= modelBudgetMS
            let interrupted = row.trace.nextKeyMS.map { elapsed + appDebounceMS >= $0 } ?? false
            if let text, !text.isEmpty, !expired, !interrupted {
                if row.first == nil { row.first = text; row.firstWordMS = elapsed }
                row.latest = text
            }
            if final || expired || interrupted {
                closed = true
                row.interrupted = interrupted
                row.failure = interrupted ? nil : (failure ?? (expired ? "timeout" : nil))
                done.signal()
            }
        }
    }

    func close(interrupted: Bool) -> Sample {
        lock.withLock {
            if !closed {
                closed = true
                row.interrupted = interrupted
                row.failure = interrupted ? nil : "timeout"
            }
            return row
        }
    }
}

private final class LoopbackDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class ModelComparison {
    let endpoint: URL
    let apiKey: String?
    let session: URLSession
    let model: PredictiveLocalModel

    init(endpoint: URL, apiKey: String?) throws {
        guard endpoint.scheme == "http", let host = endpoint.host, ["127.0.0.1", "::1", "[::1]"].contains(host),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.path.isEmpty || endpoint.path == "/", endpoint.query == nil, endpoint.fragment == nil else {
            throw EvalError("Expected a numeric loopback llama-server address")
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration, delegate: LoopbackDelegate(), delegateQueue: nil)
        model = PredictiveLocalModel(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    private func authorized(_ route: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(route))
        if let apiKey { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        return request
    }

    private struct Health: Decodable { let status: String }

    func requireReady() throws {
        let signal = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var ready = false
        let task = session.dataTask(with: authorized("health")) { data, response, _ in
            let health = data.flatMap { try? JSONDecoder().decode(Health.self, from: $0) }
            lock.withLock { ready = (response as? HTTPURLResponse)?.statusCode == 200 && health?.status == "ok" }
            signal.signal()
        }
        task.resume()
        guard signal.wait(timeout: .now() + 4) == .success, lock.withLock({ ready }) else {
            task.cancel()
            throw EvalError("llama-server is unavailable or loading at \(endpoint.absoluteString). No model results.")
        }
    }

    func sample(_ trace: Trace, constrained: Bool) -> Sample {
        let remaining = min(modelBudgetMS, (trace.nextKeyMS ?? .infinity) - appDebounceMS)
        guard remaining > 0 else { return Sample(trace: trace, interrupted: true) }
        let result = ResultCollector(trace)
        let request = WordCompletionRequest()
        let deadline = DispatchTime(uptimeNanoseconds: result.start) + .milliseconds(Int(remaining))
        if constrained {
            model.predict(before: trace.prompt, contextWord: trace.word, completing: trace.completing,
                          endpoint: endpoint, apiKey: apiKey, request: request, deadline: deadline) { event in
                switch event {
                case let .partial(text): result.update(text, final: false)
                case let .finished(text): result.update(text, final: true)
                case .failed("prediction.lowConfidence"): result.update(nil, final: true)
                case let .failed(reason): result.update(nil, final: true, failure: reason)
                }
            }
        } else {
            var http = authorized("completion")
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try! JSONSerialization.data(withJSONObject: [
                "prompt": trace.prompt, "n_predict": 8, "temperature": 0,
                "stream": false, "cache_prompt": false, "stop": ["\n"]
            ])
            let task = session.dataTask(with: http) { data, response, _ in
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let json = try? JSONDecoder().decode(DirectResponse.self, from: data) else {
                    result.update(nil, final: true, failure: "server")
                    return
                }
                result.update(json.suffix(trace), final: true)
            }
            request.startInference(task)
        }
        _ = result.done.wait(timeout: deadline)
        let row = result.close(interrupted: remaining < modelBudgetMS)
        request.cancel()
        return row
    }
}

// Frozen single-word baseline from the previous prototype, including the old mixed-script restriction.
private struct DirectResponse: Decodable {
    let content: String
    let stop_type: String

    func suffix(_ trace: Trace) -> String? {
        let text = trace.completing ? content[...] : content.drop(while: { $0 == " " })
        let token = text.prefix(while: \.isLetter)
        guard (2...24).contains(token.count) else { return nil }
        if let boundary = text.dropFirst(token.count).first {
            guard boundary.isWhitespace || ",.!?;:)]»”\"’".contains(boundary) else { return nil }
        } else if !["eos", "word"].contains(stop_type) { return nil }
        let key = WordCompletionIndex.key(String(token))
        let prior = WordCompletionIndex.key(trace.word)
        guard WordCompletionIndex.isWord(key), key != prior,
              key.utf8.first.map({ $0 < 128 }) == prior.utf8.first.map({ $0 < 128 }) else { return nil }
        if !trace.completing { return String(token) }
        guard trace.word.count >= 3 else { return nil }
        if trace.word == trace.word.uppercased() { return key.uppercased() }
        guard trace.word == prior || trace.word.dropFirst() == prior.dropFirst() else { return nil }
        return key
    }
}

/// Only built-in synthetic fixtures enter this runner. The UI keeps a run per model selection.
final class PredictionComparison {
    struct Summary {
        let mode: String
        let group: String
        let cases: Int
        let shown: Int
        let correct: Int
        let errors: Int
        let interrupted: Int
        let savedKeys: Int
        let firstP50MS: Double?
        let firstP95MS: Double?
        let lookupP95MS: Double?
        var modeledKeyP95MS: Double? { firstP95MS.map { $0 + appDebounceMS } }
    }

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private func checkCancelled() throws {
        if lock.withLock({ cancelled }) { throw CocoaError(.userCancelled) }
    }

    func start(baseURL: URL, apiKey: String?, progress: @escaping (Int, Int) -> Void,
               completion: @escaping (Result<[Summary], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result<[Summary], Error> {
                guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
                return try self.compare(resources: resources, baseURL: baseURL, apiKey: apiKey,
                                        progress: { finished, total in
                    DispatchQueue.main.async { progress(finished, total) }
                }, report: { _ in })
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous entry for the CLI and background worker. Publishes per-group results for the CLI.
    func compare(resources: URL, baseURL: URL?, apiKey: String?, tracesURL: URL? = nil,
                 completionCandidates: [URL] = [], progress: (Int, Int) -> Void = { _, _ in },
                 report: ([Summary]) -> Void) throws -> [Summary] {
        try checkCancelled()
        let url = tracesURL ?? resources.appendingPathComponent("prediction_benchmark.json")
        let traces = try JSONDecoder().decode([Trace].self, from: Data(contentsOf: url))
        guard !traces.isEmpty, Set(traces.map(\.id)).count == traces.count,
              traces.allSatisfy({ $0.text.filter { $0 == "|" }.count == 1 && !$0.reference.isEmpty }) else {
            throw EvalError("Malformed evaluation traces")
        }
        func measureDictionary(mode: String, completion: URL? = nil) throws -> Summary {
            let dictionary = try DictionaryPredictor(resources: resources, completionData: completion)
            try checkCancelled()
            if !completionCandidates.isEmpty {
                for trace in traces { _ = dictionary.sample(trace) }
            }
            let summaries = Self.summaries(mode: mode, samples: traces.map(dictionary.sample))
            report(summaries)
            return summaries[0]
        }
        let basic = try measureDictionary(mode: "dictionary")
        if !completionCandidates.isEmpty {
            return [basic] + (try completionCandidates.map { candidate in
                try measureDictionary(mode: candidate.deletingPathExtension().lastPathComponent, completion: candidate)
            })
        }
        guard let baseURL else { return [basic] }

        let comparison = try ModelComparison(endpoint: baseURL, apiKey: apiKey)
        do { try comparison.requireReady() } catch {
            try checkCancelled()
            throw error
        }
        var direct: [Sample] = []
        var constrained: [Sample] = []
        progress(0, traces.count)
        for (index, trace) in traces.enumerated() {
            // Alternate which client queries the already-loaded model first.
            try checkCancelled()
            if index.isMultiple(of: 2) { direct.append(comparison.sample(trace, constrained: false)) }
            try checkCancelled()
            constrained.append(comparison.sample(trace, constrained: true))
            if !index.isMultiple(of: 2) {
                try checkCancelled()
                direct.append(comparison.sample(trace, constrained: false))
            }
            try checkCancelled()
            progress(index + 1, traces.count)
        }
        let directStats = Self.summaries(mode: "direct", samples: direct)
        let constrainedStats = Self.summaries(mode: "constrained", samples: constrained)
        report(directStats)
        report(constrainedStats)
        return [basic, directStats[0], constrainedStats[0]]
    }

    private static func summaries(mode: String, samples: [Sample]) -> [Summary] {
        let groups = ["all"] + Set(samples.map(\.trace.group)).sorted()
        return groups.map { group in
            let rows = samples.filter { group == "all" || $0.trace.group == group }
            func percentile(_ fraction: Double, in latencies: [Double]) -> Double? {
                guard !latencies.isEmpty else { return nil }
                return latencies[Int(ceil(Double(latencies.count) * fraction)) - 1]
            }
            let firstWordLatencies = rows.compactMap(\.firstWordMS).sorted()
            return Summary(mode: mode, group: group, cases: rows.count, shown: rows.compactMap(\.first).count,
                           correct: rows.filter(\.hit).count, errors: rows.compactMap(\.failure).count,
                           interrupted: rows.filter(\.interrupted).count, savedKeys: rows.reduce(0) { $0 + $1.savedKeys },
                           firstP50MS: percentile(0.5, in: firstWordLatencies),
                           firstP95MS: percentile(0.95, in: firstWordLatencies),
                           lookupP95MS: percentile(0.95, in: rows.compactMap(\.lookupMS).sorted()))
        }
    }
}
