import Foundation

typealias Usage = PredictionUsage
precondition(Usage.Language(suggestion: "25 ноября") == .ru)
precondition(Usage.Language(suggestion: "… Report") == .en)
precondition(Usage.Language(suggestion: "123") == nil)
precondition(Usage.Language.infer(from: "25.11", after: "Meeting. Встреча ") == .ru)
precondition(Usage.Language.infer(from: "25.11", after: "Встреча. Meeting ") == .en)
precondition(Usage.savedKeys(for: "ение ") == 4)
precondition(Usage.savedKeys(for: "e\u{301} ") == 1)
precondition(Usage.savedKeys(for: "") == 0)
precondition(UUID(uuidString: Usage.Build.current.id) != nil)
var counts = Usage.Counts()
precondition(counts.meanMS == nil && counts.acceptancePercent == nil)
for sample: Double? in [100, nil, 50, -1, .nan] { counts.record(.shown(latencyMS: sample)) }
counts.record(.accepted(saved: 5))
counts.record(.accepted(saved: 4))
counts.record(.undone(saved: 4))
precondition(counts.shown == 5 && counts.accepted == 2 && counts.undone == 1)
precondition(counts.saved == 5 && counts.acceptancePercent == 40 && counts.meanMS == 75 && counts.timed == 2)

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let a = Usage.Build(id: "build-a", version: "0.6.1")
let b = Usage.Build(id: "build-b", version: "0.6.1")
let first = PredictionUsageStore(directory: directory, build: a)
let second = PredictionUsageStore(directory: directory, build: a)
let previous = PredictionUsageStore(directory: directory, build: b)
let report = directory.appendingPathComponent(PredictionUsageStore.filename)
let empty = try PredictionUsageStore.read(report)
precondition(empty.isEmpty)
for _ in 0..<20 {
    first.record(.shown(latencyMS: 60), language: .ru)
    second.record(.shown(latencyMS: nil), language: .ru)
}
first.record(.accepted(saved: 5), language: .ru)
first.record(.undone(saved: 5), language: .ru)
previous.record(.shown(latencyMS: 30), language: .en)
previous.record(.accepted(saved: 3), language: .en)
var finished = 0
for store in [first, second, previous] {
    store.load { result in
        guard case .success = result else { fatalError("Could not reload metrics") }
        finished += 1
    }
}
let deadline = Date().addingTimeInterval(10)
while finished != 3 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(finished == 3)
let rows = try PredictionUsageStore.read(report)
precondition(rows.count == 2)
let current = rows.first { $0.id == a.id }!
let baseline = rows.first { $0.id == b.id }!
precondition(current.ru.shown == 40 && current.ru.accepted == 1 && current.ru.undone == 1)
precondition(current.ru.timed == 20 && current.ru.meanMS == 60 && current.ru.saved == 0 && current.en == Usage.Counts())
precondition(baseline.en.accepted == 1 && baseline.en.saved == 3 && baseline.ru == Usage.Counts())
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as! [[String: Any]]
precondition(json.allSatisfy { Set($0.keys) == ["id", "version", "ru", "en"] })
let numeric = json[0]["ru"] as! [String: Any]
precondition(numeric.count == 6 && numeric.values.allSatisfy { $0 is NSNumber })
let corrupt = Data("broken".utf8)
try corrupt.write(to: report)
first.record(.shown(latencyMS: 1), language: .en)
var refused = false
first.load { if case .failure = $0 { refused = true } }
let until = Date().addingTimeInterval(3)
while !refused && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
let preserved = try Data(contentsOf: report)
precondition(refused && preserved == corrupt)
print("PASS: language, savings, latency, undo, persistence, concurrent writers and build comparison")
