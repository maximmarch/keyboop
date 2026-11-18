import Foundation

let now = Date(timeIntervalSince1970: 1_800_000_000)
func heard(_ word: String, after context: [String], at date: Date = now, id: UUID = UUID()) -> PersonalPredictionObservation {
    PersonalPredictionObservation(id: id, word: word, context: context, at: date)!
}

var first = PersonalPredictionHistory()
first.record(heard("макет", after: ["завтра", "пришлю"]))
precondition(first.nextWord(after: ["завтра", "пришлю"], at: now) == nil)
first.record(heard("макет", after: ["завтра", "пришлю"]))
precondition(first.nextWord(after: ["завтра", "пришлю"], at: now) == "макет")
precondition(first.nextWord(after: ["пришлю"], at: now) == nil)

var second = PersonalPredictionHistory()
for _ in 0..<3 {
    second.record(heard("смету", after: ["сегодня", "пришлю"]))
    second.record(heard("макет", after: ["завтра", "пришлю"]))
}
precondition(second.nextWord(after: ["сегодня", "пришлю"], at: now) == "смету")
precondition(second.nextWord(after: ["завтра", "пришлю"], at: now) == "макет")
precondition(second.nextWord(after: ["пришлю"], at: now) == nil)
precondition(second.completion(for: "мак", after: [], at: now) == "ет")
for _ in 0..<3 { second.record(heard("макетирование", after: [])) }
precondition(second.completion(for: "мак", after: [], at: now) == nil)
precondition(second.completion(for: "мак", after: ["завтра", "пришлю"], at: now) == "ет")
precondition(second.completion(for: "макет", after: [], at: now) == nil)
precondition(first.nextWord(after: ["завтра", "пришлю"], at: now.addingTimeInterval(90 * 86_400)) == nil)

let boundary = PersonalPredictionObservation.manual("макет", in: "Завтра пришлю макет\u{00A0}",
                                                    startsAtFieldStart: true, at: now)
precondition(boundary?.word == "макет" && boundary?.context == ["завтра", "пришлю"] && boundary?.language == .russian)
precondition(PersonalPredictionObservation.manual("макет", in: "пришлю макет дизай",
                                                   startsAtFieldStart: true, followedBy: "дизай", at: now)?.word == "макет")
precondition(PersonalPredictionObservation.manual("макет", in: "пришлю макетдизай",
                                                   startsAtFieldStart: true, followedBy: "дизай", at: now) == nil)
precondition(PersonalPredictionObservation.manual("кет", in: "пришлю макет ", startsAtFieldStart: true, at: now) == nil)
precondition(PersonalPredictionObservation.manual("макет", in: "макет ", startsAtFieldStart: false, at: now) == nil)
precondition(PersonalPredictionObservation.manual("макет", in: "пришлю `let макет ", startsAtFieldStart: true, at: now) == nil)
precondition(PersonalPredictionObservation.context(before: "завтра\nпришлю ", startsAtFieldStart: true) == ["пришлю"])
precondition(PersonalPredictionObservation.context(before: "автра пришлю ", startsAtFieldStart: false) == ["пришлю"])

var pending = PendingPredictionLearning<Int>()
let accepted = heard("макет", after: ["пришлю"])
let following = heard("завтра", after: ["пришлю", "макет"])
precondition(pending.accepted(accepted, at: 10, follows: { $0 == 9 }) == nil)
precondition(pending.accepted(accepted, at: 10, follows: { $0 == 10 }) == nil)
precondition(pending.accepted(following, at: 17, follows: { $0 == 10 })?.id == accepted.id)
precondition(pending.advance(following.id, verified: true)?.id == following.id)
precondition(pending.advance(following.id, verified: true) == nil)
let other = heard("смету", after: ["пришлю"])
_ = pending.accepted(other, at: 20, follows: { _ in true })
pending.cancel()
precondition(pending.advance(other.id, verified: true) == nil)
let wrongField = heard("смету", after: ["пришлю"])
_ = pending.accepted(wrongField, at: 21, follows: { _ in true })
precondition(pending.advance(wrongField.id, verified: false) == nil)
precondition(pending.advance(wrongField.id, verified: true) == nil)

let location = FileManager.default.temporaryDirectory.appendingPathComponent("keyboop-personal-tests-\(UUID())")
defer { try? FileManager.default.removeItem(at: location) }
try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
let url = location.appendingPathComponent("history.json")
try Data("broken JSON".utf8).write(to: url)
let queue = DispatchQueue(label: "test.personal-prediction")
let store = PersonalPredictionStore(url: url, queue: queue, saveDelay: .milliseconds(25))
store.setEnabled(true)
queue.sync {}
precondition(store.snapshot()?.nextWord(after: ["завтра", "пришлю"], at: now) == nil)
let revision = store.session!
let duplicate = heard("макет", after: ["завтра", "пришлю"])
store.record(duplicate, session: revision)
store.record(duplicate, session: revision)
precondition(store.snapshot()?.nextWord(after: ["завтра", "пришлю"], at: now) == nil)
store.record(heard("макет", after: ["завтра", "пришлю"]), session: revision)
let saved = DispatchSemaphore(value: 0)
queue.asyncAfter(deadline: .now() + .milliseconds(50)) { saved.signal() }
precondition(saved.wait(timeout: .now() + .seconds(2)) == .success)
let reloaded = PersonalPredictionStore(url: url, queue: queue)
reloaded.setEnabled(true)
queue.sync {}
precondition(reloaded.snapshot()?.nextWord(after: ["завтра", "пришлю"], at: now) == "макет")
store.record(heard("смету", after: ["сегодня", "пришлю"]), session: revision)
store.reset()
store.record(heard("макет", after: ["завтра", "пришлю"]), session: revision)
precondition(store.snapshot()?.nextWord(after: ["завтра", "пришлю"], at: now) == nil)
queue.asyncAfter(deadline: .now() + .milliseconds(50)) { saved.signal() }
precondition(saved.wait(timeout: .now() + .seconds(2)) == .success)
precondition(!FileManager.default.fileExists(atPath: url.path))
let nextRevision = store.session!
store.record(heard("макет", after: ["завтра", "пришлю"]), session: nextRevision)
store.setEnabled(false)
precondition(store.snapshot() == nil && store.session == nil)
queue.asyncAfter(deadline: .now() + .milliseconds(50)) { saved.signal() }
precondition(saved.wait(timeout: .now() + .seconds(2)) == .success)
precondition(!FileManager.default.fileExists(atPath: url.path))
print("Personal prediction: context, decay, verified input, deduplication, restart, off and reset checks passed")
