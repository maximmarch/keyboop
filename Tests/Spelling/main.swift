import Foundation

let full = SystemWordQuery("макет", mode: .completion)!
let partial = SystemWordQuery("маке", mode: .completion)!
let typo = SystemWordQuery("makte", mode: .previous)!
let name = SystemWordQuery("Makev", mode: .previous)!
precondition(SystemWordQuery("api_foo", mode: .completion) == nil)
precondition(SystemWordQuery("apiф", mode: .completion) == nil)
precondition(full.language(in: ["en_US", "ru-RU"]) == "ru-RU")
precondition(typo.language(in: ["tr_TR", "en_GB", "en_US"]) == "en_GB")
precondition(full.language(in: ["en_US"]) == nil)

precondition(full.assess(spelled: true, completions: [], guesses: []) == .complete)
precondition(partial.assess(spelled: false, completions: ["Макет"], guesses: []) == .prefix)
precondition(typo.assess(spelled: false, completions: [], guesses: ["make"]) == .likelyTypo)
precondition(typo.assess(spelled: false, completions: [], guesses: ["make", "mate"]) == .unknown)
precondition(name.assess(spelled: false, completions: [], guesses: ["makes"]) == .unknown)
precondition(partial.assess(spelled: false, completions: nil, guesses: ["макет"]) == .unknown)
let completion = PredictionDecision.Choice.dictionary(prefix: "макет", suffix: "ирование")
let follow = PredictionDecision.Choice.dictionary(prefix: "", suffix: "сегодня")
let glossary = PredictionDecision.Choice.reference(prefix: "мак", suffix: "ет", source: .glossary)
let personal = PredictionDecision.Choice.personal(prefix: "мак", suffix: "ет")
precondition(full.gate(completion, finding: .complete) == .skip(.spellcheck))
precondition(full.gate(completion, finding: .unavailable) == completion)
precondition(partial.gate(completion, finding: .prefix) == completion)
precondition(typo.gate(follow, finding: .likelyTypo) == .skip(.spellcheck))
precondition(SystemWordQuery("макет", mode: .previous)!.gate(follow, finding: .complete) == follow)
precondition(full.gate(glossary, finding: .likelyTypo) == glossary)
precondition(full.gate(personal, finding: .likelyTypo) == personal)
precondition(glossary.systemQuery(before: "мак", startsAtFieldStart: true) == nil)
precondition(personal.systemQuery(before: "мак", startsAtFieldStart: true) == nil)
precondition(follow.systemQuery(before: "Пришлю макет ", startsAtFieldStart: true)?.word == "макет")

let queue = DispatchQueue(label: "test.spell.results")
let probes = DispatchQueue(label: "test.spell.probes")
let recognition = SystemWordRecognizer(probeQueue: probes, minIntervalMS: 0, budgetMS: 40) { query in
    if query == typo { Thread.sleep(forTimeInterval: 0.1) }
    return .complete
}
func probe(_ query: SystemWordQuery, using recognizer: SystemWordRecognizer,
           cancelled: Bool = false) -> SystemWordFinding {
    let done = DispatchSemaphore(value: 0)
    var received: SystemWordFinding = .unavailable
    recognizer.recognize(query, replyOn: queue, isCancelled: { cancelled }) { result in
        received = result
        done.signal()
    }
    precondition(done.wait(timeout: .now() + .seconds(1)) == .success)
    return received
}
precondition(probe(full, using: recognition) == .complete)
precondition(probe(typo, using: recognition) == .unavailable)
precondition(probe(full, using: recognition) == .complete)
probes.sync {}
precondition(probe(typo, using: recognition, cancelled: true) == .unavailable)
let limited = SystemWordRecognizer(probeQueue: probes, minIntervalMS: 500, budgetMS: 40) { _ in .complete }
precondition(probe(full, using: limited) == .complete)
precondition(probe(partial, using: limited) == .unavailable)
precondition(probe(full, using: limited) == .complete)

let index = SymmetricDeleteIndex(knownWords: ["макет", "макеты", "программа", "программный"], frequencies: [
    "макет": 200, "макеты": 30, "программа": 400, "программный": 200
])
for bad in ["мкает", "макект", "макту", "мкет", "мокет"] {
    if bad == "макту" { precondition(index.suggest(bad) == nil) }
    else { precondition(index.suggest(bad) == "макет", bad) }
}
precondition(index.suggest("макеты") == nil)
precondition(index.suggest("Макет") == nil)
precondition(index.suggest("прогрмма") == "программа")
precondition(index.suggest("программныи") == "программный")
precondition(index.suggest("мак_et") == nil)
let ambiguous = SymmetricDeleteIndex(knownWords: ["sleep", "sleet"], frequencies: ["sleep": 100, "sleet": 80])
precondition(ambiguous.suggest("sleee") == nil)
print("System spelling, timeout/cache and symmetric delete tests passed")
