import Foundation

struct WordCompletionIndex {
    static let openingPunctuation = "(«“„[\"‘'"
    static let closingPunctuation = ",.!?;:)]»”\"’"

    enum Language: String, CaseIterable, Decodable {
        case en, ru

        init(word: String) { self = word.utf8.first.map { $0 < 128 } == true ? .en : .ru }
    }

    private let words: [String]
    private let weights: [String: Int]
    private let rankedLanguages: Set<Language>

    init(words: Set<String>, frequencies: [String: Int] = [:], rankedLanguages: Set<Language> = []) {
        self.words = Set(words.map(Self.key).filter(Self.isWord)).sorted()
        self.weights = frequencies
        self.rankedLanguages = rankedLanguages
    }

    func suffix(for prefix: String, preferredWord: String? = nil) -> String? {
        let normalized = prefix.precomposedStringWithCanonicalMapping
        let key = Self.key(normalized)
        guard key.count >= 3, Self.isWord(key) else { return nil }
        let uppercase = normalized == normalized.uppercased()
        guard uppercase || normalized == key || normalized.dropFirst() == key.dropFirst() else { return nil }

        let lower = Self.lowerBound(of: key, in: words)
        let exact = lower < words.count && words[lower] == key
        if !exact, let preferredWord, Self.isWord(preferredWord), preferredWord.hasPrefix(key) {
            let suffix = preferredWord.dropFirst(key.count)
            if suffix.count >= 3 { return uppercase ? suffix.uppercased() : String(suffix) }
        }

        var unique: Substring?
        var eligibleCount = 0
        var best: Substring?
        var bestCount = 0
        var runnerUp = 0
        for word in words[lower...] {
            guard word.hasPrefix(key) else { break }
            let suffix = word.dropFirst(key.count)
            if suffix.count >= 3 {
                eligibleCount += 1
                unique = suffix
            }
            if suffix.count >= 2, let count = weights[word] {
                if count > bestCount {
                    runnerUp = bestCount
                    bestCount = count
                    best = suffix
                } else {
                    runnerUp = max(runnerUp, count)
                }
            }
        }
        let candidate: Substring?
        let exactWeight = exact ? (weights[key] ?? (rankedLanguages.contains(Language(word: key)) ? bestCount : 1)) : 1
        if let best, Double(bestCount) >= Double(runnerUp) * 1.25,
           !exact || bestCount > 4 * exactWeight {
            candidate = best
        } else {
            candidate = !exact && eligibleCount == 1 ? unique : nil
        }
        return candidate.map { uppercase ? $0.uppercased() : String($0) }
    }

    static func prefix(before: String, after: String, startsAtFieldStart: Bool) -> String? {
        // Keep dots, slashes, digits and sigils in the token so paths, addresses and code fail isWord.
        let separator = before.lastIndex(where: \.isWhitespace)
        guard separator != nil || startsAtFieldStart else { return nil }
        let start = separator.map { before.index(after: $0) } ?? before.startIndex
        let prefix = before[start...].drop(while: { openingPunctuation.contains($0) })
        let end = after.prefix(while: { !$0.isWhitespace })
        guard end.allSatisfy({ closingPunctuation.contains($0) }), isWord(key(String(prefix))) else { return nil }
        return String(prefix)
    }

    static func key(_ word: String) -> String {
        word.lowercased().precomposedStringWithCanonicalMapping
    }

    func contains(_ word: String) -> Bool {
        let key = Self.key(word)
        let position = Self.lowerBound(of: key, in: words)
        return position < words.count && words[position] == key
    }

    static func lowerBound(of key: String, in words: [String]) -> Int {
        var lower = 0
        var upper = words.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if words[middle] < key { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    static func isWord(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        if (97...122).contains(first.value) {
            return word.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        }
        return word.unicodeScalars.allSatisfy { (1072...1103).contains($0.value) || $0.value == 1105 }
    }
}


/// Source files only extend the completion index. Layout and spelling continue reading LayoutData.
enum CompletionVocabulary {
    private struct Candidate: Decodable {
        let language: WordCompletionIndex.Language?
        let words: Set<String>
        let frequencies: [String: Int]?
        let ranks: [String: Int]?

        init(at url: URL, expectedLanguage: WordCompletionIndex.Language? = nil) throws {
            self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            func valid(_ word: String) -> Bool {
                WordCompletionIndex.isWord(word) && (language == nil || language == .init(word: word))
            }
            guard (expectedLanguage == nil || language == expectedLanguage),
                  words.allSatisfy(valid),
                  frequencies?.allSatisfy({ valid($0.key) && (1...1_000_000_000).contains($0.value) }) != false,
                  ranks == nil || (language != nil && frequencies == nil &&
                      ranks?.allSatisfy({ valid($0.key) && (1...1_000_000).contains($0.value) }) == true) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            }
        }
    }

    static func index(words: Set<String>, resources: URL, candidate: URL? = nil,
                      useBundledCandidates: Bool = true) throws -> WordCompletionIndex {
        let base = resources.appendingPathComponent("word_frequencies.json")
        var frequencies = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: base))
        var allWords = words
        var rankedLanguages: Set<WordCompletionIndex.Language> = []
        func apply(_ data: Candidate) {
            allWords.formUnion(data.words)
            if data.frequencies != nil || data.ranks != nil {
                frequencies = data.language.map { language in
                    frequencies.filter { WordCompletionIndex.Language(word: $0.key) != language }
                } ?? [:]
            }
            if let counts = data.frequencies {
                frequencies.merge(counts) { _, replacement in replacement }
            }
            if let language = data.language, let ranks = data.ranks {
                // Compare inverse ranks within one language to the same lead margin as frequencies.
                // The raw ranks are retained in the candidate and never mixed with corpus counts.
                rankedLanguages.insert(language)
                frequencies.merge(ranks.mapValues { 1_000_000_000 / $0 }) { _, replacement in replacement }
            }
        }
        if let candidate {
            try apply(Candidate(at: candidate))
        } else if useBundledCandidates {
            for language in WordCompletionIndex.Language.allCases {
                let name = "completion_dictionary_\(language.rawValue).json"
                let url = resources.appendingPathComponent(name)
                if let data = try? Candidate(at: url, expectedLanguage: language) { apply(data) }
            }
        }
        return WordCompletionIndex(words: allWords, frequencies: frequencies, rankedLanguages: rankedLanguages)
    }
}
