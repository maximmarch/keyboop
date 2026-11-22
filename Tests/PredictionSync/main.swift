import Foundation

func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "Timed out waiting for sync")
}

struct Mac {
    let id = UUID()
    let domain: String
    let prefs: UserDefaults
    let history: PersonalPredictionStore
    let sync: PredictionSync

    init(_ root: URL) {
        domain = "keyboop.sync.test." + id.uuidString
        prefs = UserDefaults(suiteName: domain)!
        history = PersonalPredictionStore(url: root.appendingPathComponent(id.uuidString + "/local.json"))
        sync = PredictionSync(defaults: prefs, history: history, writer: id)
    }

    func done() { wait { sync.status == "sync.done" } }
    func run() { sync.syncNow(); done() }
    var terms: Set<String> { Set((prefs.string(forKey: "predictionGlossary") ?? "").split(separator: "\n").map(String.init)) }
    func glossary(_ value: String) { prefs.set(value, forKey: "predictionGlossary") }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let a = Mac(root), b = Mac(root)
defer {
    for mac in [a, b] { mac.sync.setEnabled(false); mac.prefs.removePersistentDomain(forName: mac.domain) }
}
let fm = FileManager.default
let aFolder = root.appendingPathComponent("A"), bFolder = root.appendingPathComponent("B")
for path in [aFolder,bFolder] { try fm.createDirectory(at: path, withIntermediateDirectories: false) }
let aFiles = aFolder.appendingPathComponent("Keyboop Sync"), bFiles = bFolder.appendingPathComponent("Keyboop Sync")
func deliver(from source: URL, to dest: URL, mac: Mac) throws {
    // Only the origin's own files are transferred, just like two offline mirrors reconnecting.
    for suffix in [".preferences.json", ".personal.json"] {
        let name = mac.id.uuidString + suffix
        let from = source.appendingPathComponent(name), to = dest.appendingPathComponent(name)
        if fm.fileExists(atPath: from.path) { try Data(contentsOf: from).write(to: to, options: .atomic) }
        else if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
    }
}

a.glossary("Общее\nАльфа")
a.prefs.set(true, forKey: "nextWordEnabled")
a.prefs.set("secret", forKey: "privateServerKey")
try a.sync.choose(aFolder); a.done()
b.glossary("Бета")
try b.sync.choose(bFolder); b.done()
try deliver(from: aFiles, to: bFiles, mac: a)
try deliver(from: bFiles, to: aFiles, mac: b)
a.run(); b.run()
precondition(a.terms == ["Общее","Альфа","Бета"] && b.terms == a.terms)
precondition(b.prefs.bool(forKey: "nextWordEnabled") && b.prefs.object(forKey: "privateServerKey") == nil)
let stale = try Data(contentsOf: bFiles.appendingPathComponent(b.id.uuidString + ".preferences.json"))
a.glossary("Альфа\nБета\nНезависимо")
b.glossary("Общее\nАльфа\nБета\nПараллельно")
b.prefs.set(true, forKey: "predictionSystemSpellingEnabled")
a.run(); b.run()
try deliver(from: bFiles, to: aFiles, mac: b); try deliver(from: aFiles, to: bFiles, mac: a)
a.run(); b.run()
precondition(a.terms == ["Альфа","Бета","Независимо","Параллельно"] && a.terms == b.terms)
precondition(a.prefs.bool(forKey: "predictionSystemSpellingEnabled"))
try stale.write(to: aFiles.appendingPathComponent(b.id.uuidString + ".preferences.json"), options: .atomic)
a.run()
precondition(!a.terms.contains("Общее"))
let edited = PredictionSyncLedger.editedGlossary(original: "One\nTwo", edited: "Two\nThree", current: "One\nTwo\nFour")
precondition(Set(edited.split(separator: "\n")) == ["Two","Three","Four"])
let cases = PredictionSyncLedger.terms("US\nus\nCafe\u{301}\nCafé")
precondition(cases.count == 3)
let nested = try PredictionSyncFolder(root: aFiles, writer: a.id)
precondition(nested.directory.standardizedFileURL.path == aFiles.standardizedFileURL.path)
// Repeated and reversed delivery of concurrent operations converges.
let seed = PredictionSyncLedger.reconcile(previous: nil, peers: [], glossary: [:], preferences: [:], writer: a.id)
let first = PredictionSyncLedger.reconcile(previous: seed, peers: [], glossary: PredictionSyncLedger.terms("One"),
                                           preferences: ["nextWordEnabled": true], writer: a.id)
let second = PredictionSyncLedger.reconcile(previous: seed, peers: [], glossary: PredictionSyncLedger.terms("Two"),
                                            preferences: ["predictionInfillEnabled": true], writer: b.id)
var ab = first, ba = second
ab.merge(second); ba.merge(first); ba.merge(second)
precondition(ab == ba && ab.activeWords.count == 2)
let adopted = PredictionSyncLedger.reconcile(previous: nil, peers: [ab], glossary: [:], preferences: [:], writer: UUID())
precondition(adopted == ab)
let all = try fm.contentsOfDirectory(atPath: aFiles.path)
precondition(!all.contains { $0.contains("personal") })
let published = try String(contentsOf: aFiles.appendingPathComponent(a.id.uuidString + ".preferences.json"), encoding: .utf8)
precondition(!published.contains("secret") && !published.lowercased().contains("общее"))
print("PASS independent edits, deletions, stale delivery, preference isolation and edits while the glossary is open")

a.prefs.set(true, forKey: "personalPredictionEnabled"); b.prefs.set(true, forKey: "personalPredictionEnabled")
a.history.setEnabled(true); b.history.setEnabled(true)
wait { a.history.session != nil && b.history.session != nil }
for _ in 0..<4 {
    a.history.record(PersonalPredictionObservation(word: "Кассиопея", context: ["проект"])!, session: a.history.session!)
}
a.sync.setSharesPersonal(true); a.done()
try deliver(from: aFiles, to: bFiles, mac: a); b.run()
precondition(b.history.snapshot()?.nextWord(after: ["проект"]) == nil)
b.sync.setSharesPersonal(true); b.done()
precondition(b.history.snapshot()?.nextWord(after: ["проект"]) == "Кассиопея")
precondition(b.history.localSnapshot()?.nextWord(after: ["проект"]) == nil)
let bPersonal = bFiles.appendingPathComponent(b.id.uuidString + ".personal.json")
let exported = try String(contentsOf: bPersonal, encoding: .utf8)
precondition(!exported.contains("Кассиопея"))
b.sync.setSharesPersonal(false); b.done()
precondition(b.history.snapshot()?.nextWord(after: ["проект"]) == nil && !fm.fileExists(atPath: bPersonal.path))
a.sync.setSharesPersonal(false); a.done()
try deliver(from: aFiles, to: bFiles, mac: a)
b.sync.setSharesPersonal(true); b.done()
precondition(b.history.snapshot()?.nextWord(after: ["проект"]) == nil)
print("PASS personal examples require opt-in on both Macs, imports stay separate and withdrawal propagates")

let file = aFiles.appendingPathComponent(b.id.uuidString + ".preferences.json")
try Data("broken".utf8).write(to: file, options: .atomic)
let before = a.terms
a.sync.syncNow(); wait { a.sync.status == "sync.retry" }
precondition(a.terms == before)
try deliver(from: bFiles, to: aFiles, mac: b); a.run()
a.sync.setEnabled(false)
a.glossary("Пауза")
a.sync.syncNow()
precondition(a.sync.status == "sync.off")
a.sync.setEnabled(true); a.done()
precondition(a.terms == ["Пауза"])
let resumed = PredictionSync(defaults: a.prefs, history: a.history, writer: a.id)
resumed.start(); wait { resumed.status == "sync.done" }
precondition(a.terms == ["Пауза"])
resumed.setEnabled(false)
print("PASS corrupted input, safe retry, offline edits, pause and restart")
