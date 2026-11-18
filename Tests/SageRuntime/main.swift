import Foundation

// Exercise the production state machine and real Process I/O independently of the ONNX weights.
// The actual BPE implementation is exercised by Tests/SageTokenizer.
enum L10n { static func t(_ key: String) -> String { key } }
enum ModelDownloader { static func sha256(ofFileAt url: URL) -> String? { nil } }
struct SageTokenizer {
    static let maximumInputTokens = 512
    static let maximumOutputTokens = 768
    enum Failure: Error { case inputTooLong, invalidOutput }

    init(vocabulary: URL, merges: URL) throws {}

    func encode(_ text: String) throws -> [Int64] {
        if text == "token budget" { throw Failure.inputTooLong }
        return text.utf8.map(Int64.init)
    }

    func decode(_ ids: [Int64]) throws -> String {
        let bytes = ids.compactMap { UInt8(exactly: $0) }
        guard bytes.count == ids.count, let text = String(bytes: bytes, encoding: .utf8) else {
            throw Failure.invalidOutput
        }
        return text
    }
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Keyboop-Sage-Tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let model = temp.appendingPathComponent("model files", isDirectory: true)
let helper = temp.appendingPathComponent("KeyboopSage")
let files = ["encoder_model.onnx", "decoder_model.onnx", "vocab.json", "merges.txt"]
let artifacts = files.map { name in
    SageRuntime.Artifact(filename: name, repository: "fixture/unused", revision: "fixture",
                         bytes: 1, sha256: "")
}

func waitFor(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(predicate())
}

func helperScript(_ text: String) throws {
    try ("#!/bin/sh\n" + text + "\n").write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
}

func checkFailure(_ result: Result<String, Error>, _ expected: SageRuntime.Failure) {
    guard case let .failure(error) = result else { fatalError("expected \(expected)") }
    precondition(error as? SageRuntime.Failure == expected, String(describing: error))
}

func check(_ runtime: SageRuntime, _ text: String, _ assertion: (Result<String, Error>) -> Void) {
    var result: Result<String, Error>?
    runtime.correct(text) {
        precondition(Thread.isMainThread)
        result = $0
    }
    waitFor { result != nil }
    assertion(result!)
}

precondition(SageRuntime.modelArtifacts.reduce(0, { $0 + $1.bytes }) == 263_097_087)
let unavailable = SageRuntime(directory: model, helper: helper, artifacts: artifacts)
precondition(unavailable.state == .unavailable)
check(unavailable, "тест") { checkFailure($0, .unavailable) }

try helperScript("""
    [ -f "$1" ] && [ -f "$2" ] || exit 3
    exec /bin/cat
    """)
let missing = SageRuntime(directory: model, helper: helper, artifacts: artifacts)
precondition(missing.state == .missing)
check(missing, "тест") { checkFailure($0, .missing) }

try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
for file in files { try Data([1]).write(to: model.appendingPathComponent(file)) }
let runtime = SageRuntime(directory: model, helper: helper, artifacts: artifacts, timeout: 1)
precondition(runtime.state == .ready)
check(runtime, "   \n ") { checkFailure($0, .empty) }
check(runtime, String(repeating: "я", count: 4096)) { checkFailure($0, .tooLong) }
check(runtime, "token budget") { checkFailure($0, .tooLong) }
check(runtime, "Я не знал, что ты придёшь.") {
    precondition(try! $0.get() == "Я не знал, что ты придёшь.")
}

try helperScript("exit 3")
check(runtime, "тест") { checkFailure($0, .inference) }
try helperScript("printf '2 unexpected\\n'")
check(runtime, "тест") { checkFailure($0, .inference) }

try helperScript("exec /bin/sleep 10")
var timed: Result<String, Error>?
runtime.correct("длинный запрос") { timed = $0 }
check(runtime, "второй запрос") { checkFailure($0, .busy) }
waitFor { timed != nil }
checkFailure(timed!, .timeout)

let typingID = UUID()
var typingResult: Result<String, Error>?
runtime.correct("проверка набранного текста", requestID: typingID) { typingResult = $0 }
runtime.cancelTypingCorrection(UUID())
check(runtime, "второй запрос") { checkFailure($0, .busy) }
runtime.cancelTypingCorrection(typingID)
waitFor { typingResult != nil }
guard case let .failure(typingError) = typingResult else { fatalError("expected typing cancellation") }
precondition((typingError as? CocoaError)?.code == .userCancelled)

var cancelled: Result<String, Error>?
runtime.correct("тест завершения") { cancelled = $0 }
runtime.shutdown()
waitFor { cancelled != nil }
guard case let .failure(error) = cancelled else { fatalError("expected cancellation") }
precondition((error as? CocoaError)?.code == .userCancelled)

runtime.deleteModel()
waitFor { runtime.state == .missing }
precondition(!FileManager.default.fileExists(atPath: model.path))
print("SAGE runtime: model state, process protocol, bounded inputs, timeout, shutdown and deletion passed")
