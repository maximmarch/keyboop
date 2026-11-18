import Foundation

let index = WordCompletionIndex(words: [
    "пожалуйста", "подтверждение", "schedule", "school", "отчётность", "отчет", "своими", "свойство"
])

let suffixCases: [(prefix: String, expected: String?)] = [
    ("пожалу", "йста"), ("Пожалу", "йста"), ("ПОЖАЛУ", "ЙСТА"), ("ПоЖалу", nil),
    ("подтвержд", "ение"), ("sched", "ule"), ("SCH", nil), ("schedu", nil), ("пoжалу", nil),
    ("по", nil), ("пожалуйста", nil), ("отчет", nil), ("отче\u{0308}т", "ность"),
    ("свой", "ство"), ("свои", nil)
]

let prefixCases: [(before: String, after: String, atStart: Bool, expected: String?)] = [
    ("пожалу", "", true, "пожалу"), ("скажи «пожалу", "», потом", false, "пожалу"),
    ("example.com/пожалу", "", true, nil), ("user@пожалу", "", true, nil),
    ("пожалу", ".com", true, nil), ("пожалу", ",", true, "пожалу"),
    ("подтве", "рждение", true, nil), ("value_pojalu", "", true, nil),
    ("some/fi", "", true, nil), ("пожалу", "", false, nil), ("пoжалу", "", true, nil)
]

for test in suffixCases {
    let actual = index.suffix(for: test.prefix)
    precondition(actual == test.expected, "suffix(for: \(test.prefix)) returned \(String(describing: actual))")
}
for test in prefixCases {
    let actual = WordCompletionIndex.prefix(before: test.before, after: test.after, startsAtFieldStart: test.atStart)
    precondition(actual == test.expected, "Unexpected prefix at \(test.before)|\(test.after)")
}
precondition(WordCompletionIndex(words: ["отправить", "отправляю"]).suffix(for: "отправ") == nil)
precondition(WordCompletionIndex(words: ["пожалу", "пожалуйста"]).suffix(for: "пожалу") == nil)

let layoutData = LayoutData.shared
precondition(layoutData.isLoaded, "Set KEYBOOP_DATA_DIR to Sources/Keyboop/Resources")
let bundled = WordCompletionIndex(words: layoutData.wordsRu.union(layoutData.wordsEn))
precondition(bundled.suffix(for: "пожалу") == "йста")
precondition(bundled.suffix(for: "подтвержд") == nil)
precondition(bundled.suffix(for: "reluctan") == "tly")

let tableURL = URL(fileURLWithPath: "Sources/Keyboop/Resources/next_words.json")
let next = try JSONDecoder().decode(NextWordIndex.self, from: Data(contentsOf: tableURL))
let fixture = NextWordIndex(one: ["заранее": "спасибо"], two: [
    "за обратную": "связь", "отправлю на": "согласование", "let me": "know", "на всякий": "случай"
])
let nextCases: [(before: String, atStart: Bool, expected: String?)] = [
    ("Спасибо за обратную ", true, "связь"), ("ОТПРАВЛЮ НА ", true, "согласование"),
    ("Let me ", true, "know"), ("заранее ", true, "спасибо"), ("заранее ", false, nil),
    ("на всякий ", false, nil), (" на всякий ", false, "случай"),
    ("за\nобратную ", true, nil), ("за обратную, ", true, nil),
    ("за обратную  ", true, nil), ("за обратную", true, nil), ("неизвестное сочетание ", true, nil),
    ("на всякий\t", true, nil), ("какое-то слово ", true, nil), ("https://example.com ", true, nil)
]
for test in nextCases {
    let actual = fixture.predict(before: test.before, startsAtFieldStart: test.atStart)
    precondition(actual == test.expected, "Unexpected continuation for \(test.before): \(String(describing: actual))")
}
let custom = NextWordIndex(one: ["обратную": "реакцию", "тест": "test"], two: ["за обратную": "связь"])
precondition(custom.predict(before: "за обратную ", startsAtFieldStart: true) == "связь")
precondition(custom.predict(before: "и обратную ", startsAtFieldStart: true) == "реакцию")
precondition(custom.predict(before: "тест ", startsAtFieldStart: true) == nil)
precondition(next.predict(before: "Спасибо за обратную ", startsAtFieldStart: true, expectedLastWord: "ратную") == nil)
let preferred = next.predict(before: "отправлю на ", startsAtFieldStart: true)
precondition(bundled.suffix(for: "согласова", preferredWord: preferred) == "ние")
precondition(bundled.suffix(for: "согласова", preferredWord: "schedule") == nil)

let countsURL = tableURL.deletingLastPathComponent().appendingPathComponent("word_frequencies.json")
let counts = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: countsURL))
let ranked = WordCompletionIndex(words: layoutData.wordsRu.union(layoutData.wordsEn), frequencies: counts)
let rankedCases = [("спас", "ибо"), ("прив", "ет"), ("докум", "енты"), ("sched", "ule"),
                   ("СООБЩ", "ЕНИЕ"), ("пожалу", "йста")]
for (prefix, suffix) in rankedCases {
    precondition(ranked.suffix(for: prefix) == suffix, "Unexpected ranked completion for \(prefix)")
}
let corpusCases = [("Потому ", "что"), ("До сих ", "пор"), ("что делать ", "дальше"),
                   ("Как можно ", "скорее"), ("as soon ", "as"), ("in order ", "to"),
                   ("Спасибо за обратную ", "связь"), ("Let me ", "know")]
for (context, word) in corpusCases {
    let last = String(context.dropLast().split(separator: " ").last!).lowercased()
    precondition(next.predict(before: context, startsAtFieldStart: true, expectedLastWord: last) == word)
}
precondition(custom.predict(before: "за\nобратную ", startsAtFieldStart: true) == "реакцию")

func route(_ before: String, after: String = "", startsAtFieldStart: Bool = true,
           trigger: PredictionDecision.Trigger) -> PredictionDecision.Choice {
    PredictionDecision.resolve(before: before, after: after, startsAtFieldStart: startsAtFieldStart,
                               trigger: trigger, index: ranked, next: next)
}
precondition(route("до сих ", trigger: .nextWord) == .dictionary(prefix: "", suffix: "пор"))
precondition(route("Прикрепляю изобра", trigger: .completion(useContext: false)) ==
             .dictionary(prefix: "изобра", suffix: "жение"))
precondition(route("Я согласова", after: " документ", trigger: .completion(useContext: true)) == .skip(.rightText))
precondition(route("example.test/sched", trigger: .completion(useContext: true)) == .skip(.noMatch))
precondition(route("abc", startsAtFieldStart: false, trigger: .completion(useContext: true)) == .skip(.noMatch))
precondition(route("Сегодня встреча в ", trigger: .nextWord) ==
             .model(before: "Сегодня встреча в ", prefix: "", contextWord: "в"))
precondition(route("До сих\u{00A0}", trigger: .nextWord) == .dictionary(prefix: "", suffix: "пор"))

let stale = WordCompletionRequest()
precondition(stale.insert(readTarget: { stale.cancel(); return 1 }, write: { _ in
    preconditionFailure("A request cancelled during AX validation must never write")
}, verify: { false }) == .skipped)
let failed = WordCompletionRequest()
var writes = 0
precondition(failed.insert(readTarget: { 1 }, write: { _ in writes += 1; return false }, verify: {
    preconditionFailure("A failed write must not trigger verification or retry")
}) == .unconfirmed && writes == 1)
let changedAfterWrite = WordCompletionRequest()
precondition(changedAfterWrite.insert(readTarget: { 1 }, write: { _ in
    changedAfterWrite.cancel()
    return true
}, verify: { preconditionFailure("A cancelled verification must not read the field") }) == .unconfirmed)
let success = WordCompletionRequest()
precondition(success.insert(readTarget: { 1 }, write: { $0 == 1 }, verify: { true }) == .confirmed)
// Native llama.cpp SSE fixtures. Split within event names, JSON and UTF-8 code points.
final class LocalModelProtocol: URLProtocol {
    static var body: Data?
    static var status = 200
    static var expectedCache = false
    static var cancellation: DispatchSemaphore?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        precondition(request.url?.absoluteString == "http://127.0.0.1:19217/completion")
        precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        var payload = request.httpBody ?? Data()
        if payload.isEmpty, let input = request.httpBodyStream {
            input.open()
            defer { input.close() }
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = input.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0)
                if count == 0 { break }
                payload.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
        precondition(body["cache_prompt"] as? Bool == Self.expectedCache)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard let body = Self.body else { return } // leave the connection open for cancellation/timeout tests
        for start in stride(from: 0, to: body.count, by: 7) {
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + 7, body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.cancellation?.signal() }
}

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [LocalModelProtocol.self]
let model = PredictiveLocalModel(configuration: configuration)
let loopback = URL(string: "http://127.0.0.1:19217")!
typealias ModelEvent = PredictiveLocalModel.Event
var modelChecks = 0

func checkStream(_ before: String, _ context: String, _ completing: Bool,
                 pieces: [(String, Double)] = [], stop: String = "eos", expected: [ModelEvent],
                 status: Int = 200, malformed: Bool = false, stall: Bool = false,
                 cancelAfter: DispatchTimeInterval? = nil, endpoint: URL = loopback,
                 cacheScope: UUID? = nil, expectCache: Bool = false) {
    var wire = Data(": keep-alive\r\n\r\n".utf8)
    func appendEvent(_ event: [String: Any]) {
        wire.append(contentsOf: "data: ".utf8)
        wire.append(try! JSONSerialization.data(withJSONObject: event))
        wire.append(contentsOf: "\r\n\r\n".utf8)
    }
    for (text, probability) in pieces {
        appendEvent(["stop": false, "content": text, "completion_probabilities": [["logprob": log(probability)]]])
    }
    if malformed {
        wire.append(contentsOf: "data: oops\n\n".utf8)
    } else {
        appendEvent(["stop": true, "stop_type": stop, "content": ""])
    }
    LocalModelProtocol.body = stall ? nil : wire
    LocalModelProtocol.status = status
    LocalModelProtocol.expectedCache = expectCache
    let transportCancelled = cancelAfter.map { _ in DispatchSemaphore(value: 0) }
    LocalModelProtocol.cancellation = transportCancelled
    let request = WordCompletionRequest()
    let done = DispatchSemaphore(value: 0)
    var events: [ModelEvent] = []
    let deadline = DispatchTime.now() + .milliseconds(stall && cancelAfter == nil ? 40 : 1500)
    model.predict(before: before, contextWord: context, completing: completing,
                  endpoint: endpoint, apiKey: "fixture", cacheScope: cacheScope, request: request, deadline: deadline) { event in
        events.append(event)
        switch event {
        case .partial: break
        case .finished, .failed: done.signal()
        }
    }
    if let cancelAfter { DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { request.cancel() } }
    precondition(done.wait(timeout: .now() + .seconds(2)) == .success, "Missing end-of-stream event")
    precondition(events == expected, "Expected \(expected), got \(events)")
    if let transportCancelled {
        precondition(transportCancelled.wait(timeout: .now() + .seconds(1)) == .success)
    }
    LocalModelProtocol.cancellation = nil
    modelChecks += 1
}

// A new field is cold until the server has processed a prompt from it.
let editor = UUID()
let secondEditor = UUID()
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")], cacheScope: editor)
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")], cacheScope: editor, expectCache: true)
checkStream("мы ", "мы", false, expected: [.finished(nil)], stall: true, cancelAfter: .milliseconds(50), cacheScope: secondEditor)
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")], cacheScope: secondEditor)
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")], cacheScope: secondEditor, expectCache: true)
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")])
checkStream("мы ", "мы", false, pieces: [(" дома", 0.9)], expected: [.finished("дома")], cacheScope: secondEditor)
let largePrefix = String(repeating: "д", count: 138)
let stable1 = PredictiveLocalModel.stableContext(String(largePrefix.suffix(128)), caretPosition: 138)
let stable2 = PredictiveLocalModel.stableContext(String((largePrefix + "о").suffix(128)), caretPosition: 139)
precondition(stable2 == stable1 + "о" && stable1.utf16.count <= 128)
let composedPrefix = String(repeating: "🙂", count: 65)
precondition(PredictiveLocalModel.stableContext(composedPrefix, caretPosition: 130).allSatisfy { $0 == "🙂" })

let healed = PredictiveLocalModel.Input(before: "после согласова", contextWord: "согласова", completing: true)!
precondition(healed.prompt == "после" && healed.replay == " согласова" && healed.grammar.contains("\" согласова\""))
precondition(PredictiveLocalModel.Input(before: "согла", contextWord: "другая", completing: true) == nil)
precondition(PredictiveLocalModel.Input(before: "соГла", contextWord: "соГла", completing: true) == nil)
modelChecks += 3

checkStream("после согласова", "согласова", true,
            pieces: [(" согла", 0.001), ("сован", 0.9), ("ия", 0.8), (" сразу", 0.8)],
            expected: [.partial("ния"), .finished("ния сразу")])
checkStream("отправлю ", "отправлю", false, pieces: [(" PR", 0.8), (" сегодня", 0.6)],
            expected: [.partial("PR"), .finished("PR сегодня")])
checkStream("use ", "use", false, pieces: [(" обычный", 0.8), (" текст", 0.8)],
            expected: [.partial("обычный"), .finished("обычный текст")])
checkStream("нажм", "нажм", true, pieces: [("нажм", 0.8), ("ём", 0.10)], expected: [.finished("ём")])
checkStream("кто ", "кто", false, pieces: [(" там", 0.10)], expected: [.failed("prediction.lowConfidence")])
checkStream("нажм", "нажм", true, pieces: [("нажм", 0.1), ("its", 0.99)], expected: [.failed("prediction.lowConfidence")])
checkStream("сохрани ", "сохрани", false, pieces: [(" файл", 0.99), (" сейчас", 0.07), (" или", 0.8)],
            expected: [.partial("файл"), .finished("файл")])
checkStream("зав", "зав", true, pieces: [("завер", 0.8)], stop: "limit", expected: [.failed("prediction.lowConfidence")])
checkStream("зав", "зав", true, pieces: [("совсем", 0.99)], expected: [.failed("prediction.invalidResponse")])
checkStream("куда ", "куда", false, expected: [.failed("prediction.invalidResponse")], malformed: true)
checkStream("куда ", "куда", false, expected: [.failed("prediction.unavailable")], status: 503)
checkStream("куда ", "куда", false, expected: [.failed("prediction.timeout")], stall: true)
checkStream("куда ", "куда", false, expected: [.finished(nil)], stall: true, cancelAfter: .milliseconds(30))
checkStream("куда ", "куда", false, expected: [.failed("prediction.unavailable")], endpoint: URL(string: "https://example.com")!)
print("Word suggestions: \(suffixCases.count + prefixCases.count + nextCases.count + rankedCases.count + corpusCases.count + modelChecks + 23) checks passed")
