import Foundation

struct PersonalPredictionObservation {
    enum Language { case russian, english }

    let id: UUID
    let word: String
    let context: [String]
    let language: Language
    let at: Date

    init?(id: UUID = UUID(), word: String, context: [String], at: Date = Date()) {
        let key = WordCompletionIndex.key(word)
        guard Self.validWord(key), at.timeIntervalSinceReferenceDate.isFinite else { return nil }
        self.id = id
        self.word = word.precomposedStringWithCanonicalMapping
        self.context = Array(context.map(WordCompletionIndex.key).reversed().prefix(2)
            .prefix(while: Self.validWord).reversed())
        language = key.utf8.first! < 128 ? .english : .russian
        self.at = at
    }

    static func validWord(_ key: String) -> Bool {
        (1...32).contains(key.count) && WordCompletionIndex.isWord(key)
    }

    static func manual(_ typed: String, in before: String, startsAtFieldStart: Bool,
                       followedBy laterTyping: String = "", at: Date = Date()) -> Self? {
        let completed: Substring
        if before.last == " " || before.last == "\u{00A0}" { completed = before[...] }
        else if !laterTyping.isEmpty, before.hasSuffix(laterTyping) { completed = before.dropLast(laterTyping.count) }
        else { return nil }
        guard completed.last == " " || completed.last == "\u{00A0}",
              !PredictionReferenceIndex.isInsideCode(String(completed)) else { return nil }
        let text = String(completed.dropLast())
        guard let word = WordCompletionIndex.prefix(before: text, after: "", startsAtFieldStart: startsAtFieldStart),
              word == typed, word.count >= 2 else { return nil }
        return Self(word: word, context: context(before: String(text.dropLast(word.count)),
                                                  startsAtFieldStart: startsAtFieldStart), at: at)
    }

    static func context(before: String, startsAtFieldStart: Bool) -> [String] {
        var tail = before[...]
        var words: [String] = []
        let horizontal: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }
        while words.count < 2 {
            while let last = tail.last, horizontal(last) { tail = tail.dropLast() }
            let word = tail.reversed().prefix(while: { !$0.isWhitespace }).reversed()
            guard !word.isEmpty, word.count < tail.count || startsAtFieldStart else { break }
            let key = WordCompletionIndex.key(String(word))
            guard validWord(key) else { break }
            words.append(key)
            tail = tail.dropLast(word.count)
        }
        return words.reversed()
    }
}

/// A confirmed acceptance is tentative until a verified later action starts from its anchor.
struct PendingPredictionLearning<Anchor> {
    private(set) var pending: (observation: PersonalPredictionObservation, anchor: Anchor)?
    private var lastAccepted: UUID?

    mutating func accepted(_ observation: PersonalPredictionObservation, at anchor: Anchor,
                           follows: (Anchor) -> Bool) -> PersonalPredictionObservation? {
        guard lastAccepted != observation.id else { return nil }
        lastAccepted = observation.id
        let previous = pending
        pending = (observation, anchor)
        return previous.flatMap { follows($0.anchor) ? $0.observation : nil }
    }

    mutating func advance(_ id: UUID, verified: Bool) -> PersonalPredictionObservation? {
        guard let previous = pending, previous.observation.id == id else { return nil }
        pending = nil
        return verified ? previous.observation : nil
    }

    mutating func cancel() { pending = nil }
}

struct PersonalPredictionHistory: Codable {
    private struct Evidence: Codable {
        let word: String
        let weight: Double
        let updated: Date

        func score(at date: Date) -> Double {
            let elapsed = max(0, date.timeIntervalSince(updated))
            return weight * exp2(-elapsed / (30 * 86_400))
        }

        static func adding(_ observation: PersonalPredictionObservation, to evidence: Self?) -> Self {
            let time = max(observation.at, evidence?.updated ?? observation.at)
            return Self(word: observation.word, weight: min(64, (evidence?.score(at: time) ?? 0) + 1), updated: time)
        }
    }

    var version = 1
    private var words: [String: Evidence] = [:]
    private var contexts: [String: [String: Evidence]] = [:]

    mutating func record(_ observation: PersonalPredictionObservation) {
        let key = WordCompletionIndex.key(observation.word)
        // A single-letter word can provide context but is not an actionable learned suggestion.
        guard key.count >= 2 else { return }
        words[key] = Evidence.adding(observation, to: words[key])
        for length in 1...2 where observation.context.count >= length {
            let context = observation.context.suffix(length).joined(separator: " ")
            var alternatives = contexts[context, default: [:]]
            alternatives[key] = Evidence.adding(observation, to: alternatives[key])
            if alternatives.count > 12, let oldest = alternatives.min(by: { $0.value.updated < $1.value.updated }) {
                alternatives.removeValue(forKey: oldest.key)
            }
            contexts[context] = alternatives
        }
        if words.count > 4_000, let oldest = words.min(by: { $0.value.updated < $1.value.updated }) {
            words.removeValue(forKey: oldest.key)
        }
        if contexts.count > 6_000 {
            let recent = contexts.map { (key: $0.key, value: $0.value,
                                         updated: $0.value.values.map(\.updated).max() ?? .distantPast) }
                .sorted { $0.updated > $1.updated }
            contexts = Dictionary(uniqueKeysWithValues: recent.prefix(5_500).map { ($0.key, $0.value) })
        }
    }

    func nextWord(after context: [String], at time: Date = Date()) -> String? {
        winner(after: context, prefix: "", at: time)?.word
    }

    func completion(for prefix: String, after context: [String], at time: Date = Date()) -> String? {
        let key = WordCompletionIndex.key(prefix)
        guard key.count >= 3, words[key] == nil else { return nil }
        let candidate = winner(after: context, prefix: key, at: time)
            ?? Self.winner(in: words, prefix: key, excluding: nil, minimum: 2.7, margin: 2, at: time)
        guard let candidate else { return nil }
        return PredictionReferenceIndex.renderSuffix(of: candidate.word, matching: prefix)
    }

    private func winner(after context: [String], prefix: String, at time: Date) -> Evidence? {
        for length in [2, 1] where context.count >= length {
            let key = context.suffix(length).joined(separator: " ")
            guard let evidence = contexts[key] else { continue }
            if let result = Self.winner(in: evidence, prefix: prefix, excluding: prefix.isEmpty ? context.last : nil,
                                       minimum: length == 2 ? 1.8 : 2.7, margin: length == 2 ? 1.5 : 2,
                                       at: time) { return result }
        }
        return nil
    }

    private static func winner(in entries: [String: Evidence], prefix: String, excluding: String?,
                               minimum: Double, margin: Double, at time: Date) -> Evidence? {
        var best: Evidence?
        var bestScore = 0.0
        var rival = 0.0
        for (key, evidence) in entries where key != excluding && key.hasPrefix(prefix) {
            guard prefix.isEmpty || key.count >= prefix.count + 2 else { continue }
            let score = evidence.score(at: time)
            if score > bestScore {
                rival = bestScore
                bestScore = score
                best = evidence
            } else {
                rival = max(rival, score)
            }
        }
        return bestScore >= minimum && bestScore >= rival * margin ? best : nil
    }

    var isValid: Bool {
        func valid(_ entries: [String: Evidence]) -> Bool {
            entries.allSatisfy { key, evidence in
                PersonalPredictionObservation.validWord(key) && key == WordCompletionIndex.key(evidence.word) &&
                    evidence.weight.isFinite && (0...64).contains(evidence.weight) &&
                    evidence.updated.timeIntervalSinceReferenceDate.isFinite
            }
        }
        return version == 1 && words.count <= 4_000 && contexts.count <= 6_000 && valid(words) &&
            contexts.allSatisfy { key, entries in
                let tokens = key.split(separator: " ")
                return (1...2).contains(tokens.count) && tokens.joined(separator: " ") == key &&
                    tokens.allSatisfy { PersonalPredictionObservation.validWord(String($0)) } &&
                    entries.count <= 12 && valid(entries)
            }
    }
}

final class PersonalPredictionStore {
    static let shared = PersonalPredictionStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("Keyboop/personal-prediction/history.json"))
    static let didReset = Notification.Name("KeyboopPersonalPredictionDidReset")

    private let url: URL
    private let queue: DispatchQueue
    private let saveDelay: DispatchTimeInterval
    private let lock = NSLock()
    private var enabled = false
    private var revision: UInt64 = 0
    private var history: PersonalPredictionHistory?
    private var pendingSave: DispatchWorkItem?
    private var recorded: Set<UUID> = []
    private var recent: [UUID] = []

    init(url: URL, queue: DispatchQueue = DispatchQueue(label: "ru.keyboop.personal-prediction", qos: .utility),
         saveDelay: DispatchTimeInterval = .seconds(2)) {
        self.url = url
        self.queue = queue
        self.saveDelay = saveDelay
    }

    var session: UInt64? { lock.withLock { history == nil ? nil : revision } }
    func snapshot() -> PersonalPredictionHistory? { lock.withLock { history } }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            guard enabled != self.enabled else { return }
            self.enabled = enabled
            cancelPending()
            history = nil
            let generation = revision
            if enabled {
                queue.async { [weak self] in self?.load(session: generation) }
            }
        }
    }

    func record(_ observation: PersonalPredictionObservation, session: UInt64) {
        lock.withLock {
            guard session == revision, history != nil, recorded.insert(observation.id).inserted else { return }
            recent.append(observation.id)
            if recent.count > 256 { recorded.remove(recent.removeFirst()) }
            history?.record(observation)
            pendingSave?.cancel()
            let write = DispatchWorkItem { [weak self] in self?.save(session: session) }
            pendingSave = write
            queue.asyncAfter(deadline: .now() + saveDelay, execute: write)
        }
    }

    func reset(completion: @escaping (Bool) -> Void = { _ in }) {
        lock.withLock {
            cancelPending()
            history = enabled ? PersonalPredictionHistory() : nil
            // Serial with writes already in progress and loads scheduled by re-enabling.
            queue.async { [url] in
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        }
    }

    private func cancelPending() {
        revision &+= 1
        pendingSave?.cancel()
        pendingSave = nil
        recorded.removeAll()
        recent.removeAll()
    }

    private func load(session: UInt64) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let decoded: PersonalPredictionHistory?
        if (1...16_000_000).contains(size), let file = try? Data(contentsOf: url) {
            decoded = try? JSONDecoder().decode(PersonalPredictionHistory.self, from: file)
        } else {
            decoded = nil
        }
        let usable = decoded.flatMap { $0.isValid ? $0 : nil }
        lock.withLock {
            guard session == revision, enabled else { return }
            history = usable ?? PersonalPredictionHistory()
        }
    }

    private func save(session: UInt64) {
        guard let snapshot = lock.withLock({ session == revision ? history : nil }) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Keyboop: could not save personal prediction history")
        }
    }
}
