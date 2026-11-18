import Foundation

/// Streams short, word-aligned completions from a loopback llama.cpp server.
final class PredictiveLocalModel {
    enum Event: Equatable {
        case partial(String)
        case finished(String?)
        case failed(String)
    }

    private let delegate = StreamDelegate()
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let queue = OperationQueue()
        queue.name = "ru.keyboop.prediction-stream"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func predict(before: String, contextWord: String, completing: Bool, endpoint: URL, apiKey: String?, cacheScope: UUID? = nil,
                 request: WordCompletionRequest, deadline: DispatchTime, receive: @escaping (Event) -> Void) {
        guard !request.isCancelled else { receive(.finished(nil)); return }
        guard DispatchTime.now() < deadline else { receive(.failed("prediction.timeout")); return }
        guard endpoint.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(endpoint.host ?? ""),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            receive(.failed("prediction.unavailable"))
            return
        }
        guard let input = Input(before: before, contextWord: contextWord, completing: completing) else {
            receive(.finished(nil))
            return
        }
        var outgoing = URLRequest(url: endpoint.appendingPathComponent("completion"))
        outgoing.httpMethod = "POST"
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey { outgoing.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let key = apiKey.flatMap { token in cacheScope.map { CacheKey(endpoint: endpoint, apiKey: token, scope: $0) } }
        let cache = delegate.begin(key)
        // Pre-sampling probabilities keep the confidence score meaningful even under a grammar.
        var body: [String: Any] = [
            "prompt": input.prompt, "grammar": input.grammar, "stream": true, "n_predict": 32,
            "temperature": 0, "n_probs": 1, "post_sampling_probs": false, "cache_prompt": cache.reuse
        ]
        if key != nil { body["id_slot"] = 0 }
        outgoing.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = session.dataTask(with: outgoing)
        let stream = Stream(input: input, request: request, deadline: deadline, cache: cache, receive: receive)
        delegate.register(stream, for: task)
        request.startInference(task)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak task] in task?.cancel() }
    }

    /// A rolling 128-unit suffix shifts its start after every keystroke. Advance it in
    /// 32-unit steps instead, keeping 96–127 units and preserving grapheme boundaries.
    static func stableContext(_ before: String, caretPosition: Int) -> String {
        let limit = 96 + max(caretPosition, 0) % 32
        var start = before.endIndex
        var count = 0
        while start > before.startIndex {
            let previous = before.index(before: start)
            let width = before[previous..<start].utf16.count
            guard count + width <= limit else { break }
            count += width
            start = previous
        }
        return String(before[start...])
    }

    private struct CacheKey: Equatable {
        let endpoint: URL
        let apiKey: String
        let scope: UUID
    }

    private struct CacheAccess {
        let key: CacheKey?
        let generation: UInt64
        let reuse: Bool
    }

    struct Input {
        let prompt: String
        let replay: String
        let grammar: String
        let contextWord: String
        let completing: Bool

        init?(before: String, contextWord: String, completing: Bool) {
            let key = WordCompletionIndex.key(contextWord)
            guard WordCompletionIndex.isWord(key) else { return nil }
            var left = before[...]
            var required = ""
            if completing {
                guard (3...32).contains(contextWord.count), before.hasSuffix(contextWord),
                      contextWord == key || contextWord == contextWord.uppercased()
                      || contextWord.dropFirst() == key.dropFirst() else { return nil }
                left = left.dropLast(contextWord.count)
                required = contextWord
            } else {
                guard left.last == " " else { return nil }
            }
            // Replay the preceding space too. BPE often encodes it and the following stem as one token.
            if left.last == " " {
                left = left.dropLast()
                required = " " + required
            }
            let alphabet = key.unicodeScalars.first!.isASCII ? "[A-Za-z]" : "[А-Яа-яЁё]"
            let first = completing ? "\(alphabet){0,24}" : "word"
            // Only RU/EN letters, optionally one space, can reach the quoted literal.
            grammar = "root ::= \"\(required)\" \(first) (\" \" word){0,2}\nword ::= [A-Za-zА-Яа-яЁё]{1,32}"
            prompt = left.isEmpty ? "\n" : String(left)
            replay = required
            self.contextWord = contextWord
            self.completing = completing
        }
    }

    /// All mutation after registration runs on the serial session delegate queue.
    private final class Stream {
        struct Chunk: Decodable {
            struct Probability: Decodable { let logprob: Double }
            let content: String
            let stop: Bool
            let stop_type: String?
            let completion_probabilities: [Probability]?
        }

        let input: Input
        let request: WordCompletionRequest
        let deadline: DispatchTime
        let cache: CacheAccess
        let receive: (Event) -> Void
        var pending = Data()
        var generated = ""
        var scores: [(bytes: Range<Int>, logprob: Double)] = []
        var visible: String?
        var terminal = false
        var confirmedPrompt = false

        init(input: Input, request: WordCompletionRequest, deadline: DispatchTime, cache: CacheAccess, receive: @escaping (Event) -> Void) {
            self.input = input
            self.request = request
            self.deadline = deadline
            self.cache = cache
            self.receive = receive
        }

        func finish(_ event: Event) {
            guard !terminal else { return }
            terminal = true
            receive(event)
        }

        func consume(_ chunk: Chunk) {
            let start = generated.utf8.count
            if !chunk.content.isEmpty {
                guard start + chunk.content.utf8.count <= 512,
                      let score = chunk.completion_probabilities?.first?.logprob,
                      score.isFinite, score <= 0 else { finish(.failed("prediction.invalidResponse")); return }
                generated += chunk.content
                scores.append((start..<generated.utf8.count, score))
            }
            let complete = chunk.stop && ["eos", "word"].contains(chunk.stop_type)
            guard generated.hasPrefix(input.replay) else {
                if !input.replay.hasPrefix(generated) { finish(.failed("prediction.invalidResponse")) }
                else if chunk.stop { finish(.finished(nil)) }
                return
            }
            let suffix = generated.dropFirst(input.replay.count)
            let words = suffix.split(separator: " ", omittingEmptySubsequences: false)
            let completeWords = complete ? words[...] : words.dropLast()
            var parts: [String] = []
            var offset = input.replay.utf8.count
            for word in completeWords {
                let key = WordCompletionIndex.key(String(word))
                // A clean boundary immediately after the typed stem is an abstention.
                guard WordCompletionIndex.isWord(key), parts.count < 3 else { break }
                if parts.isEmpty {
                    guard key != WordCompletionIndex.key(input.contextWord) else { break }
                    if input.completing {
                        guard word.count >= 2,
                              key.unicodeScalars.first?.isASCII == input.contextWord.unicodeScalars.first?.isASCII
                        else { break }
                    }
                }
                let span = offset..<(offset + word.utf8.count)
                let relevant = scores.filter { $0.bytes.overlaps(span) }
                // Length-normalized across subword tokens so Cyrillic tokenization is not penalized.
                // Initial thresholds, to be tuned with the RU/EN replay benchmark.
                let threshold = parts.isEmpty ? (input.completing ? 0.08 : 0.15) : 0.22
                guard !relevant.isEmpty,
                      relevant.map(\.logprob).reduce(0, +) / Double(relevant.count) >= log(threshold) else { break }
                let uppercaseSuffix = parts.isEmpty && input.completing && input.contextWord == input.contextWord.uppercased()
                parts.append(uppercaseSuffix ? key.uppercased() : String(word))
                offset = span.upperBound + 1
            }
            let phrase = parts.joined(separator: " ")
            if phrase.count >= 2, phrase != visible {
                visible = phrase
                if !chunk.stop { receive(.partial(phrase)) }
            }
            if chunk.stop || parts.count < completeWords.count {
                finish(visible.map { .finished($0) } ?? .failed("prediction.lowConfidence"))
            }
        }
    }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [Int: Stream] = [:]
        private var generation: UInt64 = 0
        private var warmKey: CacheKey?

        func begin(_ key: CacheKey?) -> CacheAccess {
            lock.withLock {
                generation &+= 1
                if key != warmKey { warmKey = nil }
                return CacheAccess(key: key, generation: generation, reuse: warmKey != nil)
            }
        }

        private func confirmPrompt(_ stream: Stream) {
            guard !stream.confirmedPrompt, let key = stream.cache.key else { return }
            stream.confirmedPrompt = true
            lock.withLock {
                // A delayed packet from a cancelled request cannot warm a different scope.
                if generation == stream.cache.generation { warmKey = key }
            }
        }

        func register(_ stream: Stream, for task: URLSessionTask) {
            lock.withLock { streams[task.taskIdentifier] = stream }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let stream = lock.withLock { streams[dataTask.taskIdentifier] }
                stream?.finish(.failed("prediction.unavailable"))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let stream = lock.withLock({ streams[dataTask.taskIdentifier] }), !stream.terminal,
                  !stream.request.isCancelled, DispatchTime.now() < stream.deadline else { return }
            stream.pending.append(data)
            // Native /completion sends one JSON object per "data:" line, followed by a blank line.
            while !stream.request.isCancelled, DispatchTime.now() < stream.deadline,
                  let newline = stream.pending.firstIndex(of: 10) {
                let line = stream.pending[..<newline]
                stream.pending.removeSubrange(...newline)
                guard line.starts(with: "data:".utf8) else { continue }
                let json = Data(line.dropFirst(5))
                guard let chunk = try? JSONDecoder().decode(Stream.Chunk.self, from: json) else {
                    stream.finish(.failed("prediction.invalidResponse"))
                    break
                }
                if chunk.stop || !chunk.content.isEmpty { confirmPrompt(stream) }
                stream.consume(chunk)
                if stream.terminal { break }
            }
            if stream.pending.count > 65_536 { stream.finish(.failed("prediction.invalidResponse")) }
            if stream.terminal { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let stream = lock.withLock({ streams.removeValue(forKey: task.taskIdentifier) }),
                  !stream.terminal else { return }
            if stream.request.isCancelled { stream.finish(.finished(nil)) }
            else if let visible = stream.visible { stream.finish(.finished(visible)) }
            else if DispatchTime.now() >= stream.deadline { stream.finish(.failed("prediction.timeout")) }
            else { stream.finish(.failed(error == nil ? "prediction.invalidResponse" : "prediction.unavailable")) }
        }
    }
}
