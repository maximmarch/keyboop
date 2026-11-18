import AppKit
import Foundation

enum SystemWordFinding: String, Equatable {
    case complete, prefix, likelyTypo, unknown, unavailable
}

struct SystemWordQuery: Hashable {
    enum Mode: Hashable { case completion, previous }

    let word: String
    let mode: Mode
    private let languageCode: String

    init?(_ word: String, mode: Mode) {
        let key = WordCompletionIndex.key(word)
        guard (3...32).contains(key.count), WordCompletionIndex.isWord(key) else { return nil }
        self.word = word.precomposedStringWithCanonicalMapping
        self.mode = mode
        self.languageCode = key.utf8.first! < 128 ? "en" : "ru"
    }

    func language(in available: [String]) -> String? {
        available.first {
            let code = $0.lowercased().prefix { $0 != "_" && $0 != "-" }
            return code == languageCode
        }
    }

    func assess(spelled: Bool, completions: [String]?, guesses: [String]?) -> SystemWordFinding {
        if spelled { return .complete }
        let key = WordCompletionIndex.key(word)
        if mode == .completion {
            guard let completions else { return .unknown }
            if completions.contains(where: { WordCompletionIndex.key($0).hasPrefix(key) }) { return .prefix }
        }
        guard word == key, key.count >= 4, let guesses else { return .unknown }
        let close = Set(guesses.lazy.map(WordCompletionIndex.key).filter {
            WordCompletionIndex.isWord($0) && $0.utf8.first.map { $0 < 128 } == key.utf8.first.map { $0 < 128 } &&
                !$0.hasPrefix(key) && SymmetricDeleteIndex.isOneEdit(key, $0)
        })
        return close.count == 1 ? .likelyTypo : .unknown
    }

    func gate(_ choice: PredictionDecision.Choice, finding: SystemWordFinding) -> PredictionDecision.Choice {
        switch choice {
        case .dictionary, .model:
            if finding == .likelyTypo || (mode == .completion && finding == .complete) {
                return .skip(.spellcheck)
            }
            return choice
        case .skip, .reference, .personal:
            return choice
        }
    }
}

extension PredictionDecision.Choice {
    func systemQuery(before: String, startsAtFieldStart: Bool) -> SystemWordQuery? {
        let prefix: String
        switch self {
        case let .dictionary(stem, _), let .model(_, stem, _): prefix = stem
        case .skip, .reference, .personal: return nil
        }
        if !prefix.isEmpty { return SystemWordQuery(prefix, mode: .completion) }
        let normalized = before.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard normalized.last == " ",
              let word = WordCompletionIndex.prefix(before: String(normalized.dropLast()), after: "",
                                                    startsAtFieldStart: startsAtFieldStart) else { return nil }
        return SystemWordQuery(word, mode: .previous)
    }
}

/// Keeps the synchronous AppKit probe on the main queue and lets the prediction worker fail open.
final class SystemWordRecognizer {
    static let shared = SystemWordRecognizer(probe: appleProbe)

    private let probeQueue: DispatchQueue
    private let minInterval: UInt64
    private let budgetMS: Int
    private let probe: (SystemWordQuery) -> SystemWordFinding
    private let lock = NSLock()
    private var cache: [SystemWordQuery: (finding: SystemWordFinding, time: UInt64)] = [:]
    private var lastProbe: UInt64?
    private var inFlight = false

    init(probeQueue: DispatchQueue = .main, minIntervalMS: Int = 400, budgetMS: Int = 45,
         probe: @escaping (SystemWordQuery) -> SystemWordFinding) {
        self.probeQueue = probeQueue
        self.minInterval = UInt64(minIntervalMS) * 1_000_000
        self.budgetMS = budgetMS
        self.probe = probe
    }

    func recognize(_ query: SystemWordQuery, replyOn queue: DispatchQueue,
                   isCancelled: @escaping () -> Bool,
                   completion: @escaping (SystemWordFinding) -> Void) {
        let decision: ProbeDecision = lock.withLock {
            let now = DispatchTime.now()
            guard !isCancelled() else { return .answer(.unavailable) }
            if let entry = cache[query], now.uptimeNanoseconds - entry.time < 120_000_000_000 {
                return .answer(entry.finding)
            }
            guard !inFlight, lastProbe.map({ now.uptimeNanoseconds - $0 >= minInterval }) ?? true else {
                return .answer(.unavailable)
            }
            inFlight = true
            lastProbe = now.uptimeNanoseconds
            return .read(until: now + .milliseconds(budgetMS))
        }
        guard case let .read(deadline) = decision else {
            if case let .answer(finding) = decision {
                queue.async { completion(isCancelled() ? .unavailable : finding) }
            }
            return
        }
        let result = RecognitionResult()
        queue.asyncAfter(deadline: deadline) {
            result.finish(.unavailable, completion: completion)
        }
        probeQueue.async { [self] in
            let finding = DispatchTime.now() < deadline && !isCancelled() ? probe(query) : .unavailable
            let end = DispatchTime.now()
            let timely = end < deadline && !isCancelled()
            lock.withLock {
                inFlight = false
                if timely, finding != .unavailable {
                    if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
                    cache[query] = (finding, end.uptimeNanoseconds)
                }
            }
            queue.async {
                result.finish(timely && !isCancelled() ? finding : .unavailable, completion: completion)
            }
        }
    }

    private enum ProbeDecision {
        case answer(SystemWordFinding)
        case read(until: DispatchTime)
    }

    private final class RecognitionResult {
        private let lock = NSLock()
        private var finished = false
        func finish(_ finding: SystemWordFinding, completion: (SystemWordFinding) -> Void) {
            let deliver = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            if deliver { completion(finding) }
        }
    }

    static func appleProbe(_ query: SystemWordQuery) -> SystemWordFinding {
        let checker = NSSpellChecker.shared
        guard let language = query.language(in: checker.availableLanguages) else { return .unavailable }
        var wordCount = 0
        let misspelling = checker.checkSpelling(of: query.word, startingAt: 0, language: language, wrap: false,
                                               inSpellDocumentWithTag: 0, wordCount: &wordCount)
        guard wordCount > 0 else { return .unavailable }
        if misspelling.location == NSNotFound { return .complete }
        let range = NSRange(location: 0, length: query.word.utf16.count)
        let completions = query.mode == .completion
            ? (checker.completions(forPartialWordRange: range, in: query.word, language: language, inSpellDocumentWithTag: 0) ?? [])
            : nil
        let assessment = query.assess(spelled: false, completions: completions, guesses: nil)
        guard assessment == .unknown, query.word.count >= 4,
              query.word == WordCompletionIndex.key(query.word) else { return assessment }
        let guesses = checker.guesses(forWordRange: range, in: query.word, language: language, inSpellDocumentWithTag: 0)
        return query.assess(spelled: false, completions: completions, guesses: guesses)
    }
}
