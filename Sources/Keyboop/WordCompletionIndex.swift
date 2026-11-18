import Foundation

struct WordCompletionIndex {
    static let openingPunctuation = "(«“„[\"‘'"
    static let closingPunctuation = ",.!?;:)]»”\"’"

    private let words: [String]
    private let frequencies: [String: Int]

    init(words: Set<String>, frequencies: [String: Int] = [:]) {
        self.words = Set(words.map(Self.key).filter(Self.isWord)).sorted()
        self.frequencies = frequencies
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
            if suffix.count >= 2, let count = frequencies[word] {
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
        if let best, Double(bestCount) >= Double(runnerUp) * 1.25,
           !exact || bestCount > 4 * (frequencies[key] ?? 1) {
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
