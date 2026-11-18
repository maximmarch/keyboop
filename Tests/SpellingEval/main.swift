import Foundation

// The standalone process uses the app's TypoFix and dictionaries with no user history.
enum AppSettings {
    static let shared = AppSettingsFixture()
    struct AppSettingsFixture { let typoFix = true }
}
enum ExceptionStore {
    static let shared = ExceptionFixture()
    struct ExceptionFixture {
        let ignored = Set<String>()
        let learned = Set<String>()
    }
}
enum UndoLearner {
    static let shared = UndoFixture()
    struct UndoFixture { func isSessionProtected(_ word: String) -> Bool { false } }
}
func kbLog(_ message: String) {}

struct Example {
    let typed: String
    let expected: String?
    let operation: String
}

struct Stats {
    var exact = 0
    var wrong = 0
    var missed = 0
    var falsePositives = 0
    var lookup = [Double]()

    mutating func test(_ example: Example, suggest: (String) -> String?) {
        let start = DispatchTime.now()
        let answer = suggest(example.typed)
        lookup.append(milliseconds(since: start))
        switch (example.expected, answer) {
        case (nil, .some): falsePositives += 1
        case (.some, nil): missed += 1
        case (.some(let expected), .some(let actual)):
            if expected == actual { exact += 1 } else { wrong += 1 }
        case (nil, nil): break
        }
    }
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

func p95(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

func singleEdits(_ words: [String], substitute: Character) -> [Example] {
    words.flatMap { word in
        let letters = Array(word)
        let middle = letters.count / 2
        var insertion = letters
        insertion.insert(letters[middle], at: middle)
        var deletion = letters
        deletion.remove(at: middle)
        var replacement = letters
        replacement[middle] = replacement[middle] == substitute ? letters[0] : substitute
        var swap = letters
        if let i = (1..<(letters.count - 1)).first(where: { letters[$0] != letters[$0 + 1] }) {
            swap.swapAt(i, i + 1)
        }
        return [("insert", insertion), ("delete", deletion), ("replace", replacement), ("transpose", swap)]
            .filter { String($0.1) != word }
            .map { Example(typed: String($0.1), expected: word, operation: $0.0) }
    }
}

let en = ["address", "because", "available", "receive", "program", "monday", "message", "project",
          "person", "together", "weather", "meeting", "change", "modern", "marked", "correct",
          "question", "coffee", "reason", "document"]
let ru = ["привет", "сегодня", "программа", "пожалуйста", "договор", "макет", "опечатка", "встреча",
          "вопрос", "система", "конечно", "работа", "проект", "информация", "сообщение", "понятно",
          "документ", "ссылка", "точность", "письмо"]

let data = LayoutData.shared
precondition(data.isLoaded)
let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYBOOP_DATA_DIR"]!)
let frequencies = try JSONDecoder().decode([String: Int].self,
    from: Data(contentsOf: directory.appendingPathComponent("word_frequencies.json")))
TypoFix.shared.load()

for (language, known, samples, replacement, controls) in [
    ("ru", data.wordsRu, ru, Character("ж"), ["мерч", "Гитхаб", "Маша", "кворум", "норм", "шо", "девопс", "фидбэк"]),
    ("en", data.wordsEn, en, Character("x"), ["Keyboop", "Annette", "GitHub", "lolz", "colorway", "minify", "debounce", "webhook"])
] {
    let counts = frequencies.filter { $0.key.hasCyrillic == (language == "ru") }
    let start = DispatchTime.now()
    let index = SymmetricDeleteIndex(knownWords: known, frequencies: counts)
    print(String(format: "%@ index: %.3f ms, %d frequency entries", language, milliseconds(since: start), counts.count))
    let cases = singleEdits(samples, substitute: replacement)
        + (samples + controls).map { Example(typed: $0, expected: nil, operation: "clean") }
    for (name, suggest) in [
        ("TypoFix", { TypoFix.shared.suggest($0, enabledOverride: true) }),
        ("SymSpell", index.suggest)
    ] {
        var totals = Stats()
        var byOperation: [String: Stats] = [:]
        for example in cases {
            totals.test(example, suggest: suggest)
            byOperation[example.operation, default: Stats()].test(example, suggest: suggest)
        }
        let operations = ["insert", "delete", "replace", "transpose"].map {
            "\($0)=\(byOperation[$0]?.exact ?? 0)"
        }.joined(separator: " ")
        print(String(format: "%@ %@: exact=%d/%d wrong=%d missed=%d clean_false=%d/%d p95=%.3f ms %@",
                     language, name, totals.exact, cases.count - samples.count - controls.count, totals.wrong,
                     totals.missed, totals.falsePositives, samples.count + controls.count, p95(totals.lookup), operations))
    }
}

for (word, mode) in [
    ("макет", SystemWordQuery.Mode.previous), ("маке", .completion), ("прогрмма", .previous),
    ("квантизация", .previous), ("program", .previous), ("progr", .completion),
    ("progrm", .previous), ("rendezvous", .previous), ("zzzz", .previous)
] {
    let query = SystemWordQuery(word, mode: mode)!
    let start = DispatchTime.now()
    let finding = SystemWordRecognizer.appleProbe(query)
    print(String(format: "NSSpellChecker %@: %@ %.3f ms", word, finding.rawValue, milliseconds(since: start)))
}
