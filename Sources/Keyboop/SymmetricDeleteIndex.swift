import Foundation

/// A one-edit symmetric-delete index used for offline comparison.
struct SymmetricDeleteIndex {
    private static let prefixLength = 7
    private let knownWords: Set<String>
    private let candidates: [String: [String]]
    private let frequencies: [String: Int]

    init(knownWords: Set<String>, frequencies: [String: Int]) {
        self.knownWords = knownWords
        self.frequencies = frequencies
        var candidates: [String: [String]] = [:]
        for (word, count) in frequencies where count > 0 && knownWords.contains(word) &&
            (4...32).contains(word.count) && WordCompletionIndex.isWord(word) {
            for signature in Self.signatures(word) {
                candidates[signature, default: []].append(word)
            }
        }
        self.candidates = candidates
    }

    func suggest(_ typed: String) -> String? {
        let word = WordCompletionIndex.key(typed)
        guard typed == word, (4...32).contains(word.count), WordCompletionIndex.isWord(word),
              !knownWords.contains(word) else { return nil }
        var seen: Set<String> = []
        var best: String?
        var highest = 0
        var runnerUp = 0
        for signature in Self.signatures(word) {
            for candidate in candidates[signature] ?? [] where seen.insert(candidate).inserted {
                guard Self.isOneEdit(word, candidate), let count = frequencies[candidate] else { continue }
                if count > highest {
                    runnerUp = highest
                    highest = count
                    best = candidate
                } else {
                    runnerUp = max(runnerUp, count)
                }
            }
        }
        // Equal or close frequencies are common with inflected forms.
        return highest >= 20 && Double(highest) >= Double(runnerUp) * 4 ? best : nil
    }

    private static func signatures(_ word: String) -> Set<String> {
        let prefix = Array(word.prefix(prefixLength))
        var keys: Set<String> = [String(prefix)]
        for index in prefix.indices {
            var deleted = prefix
            deleted.remove(at: index)
            keys.insert(String(deleted))
        }
        return keys
    }

    static func isOneEdit(_ first: String, _ second: String) -> Bool {
        let left = Array(first), right = Array(second)
        if left.count == right.count {
            let mismatches = left.indices.filter { left[$0] != right[$0] }
            if mismatches.count == 1 { return true }
            guard mismatches.count == 2 else { return false }
            let i = mismatches[0], j = mismatches[1]
            return j == i + 1 && left[i] == right[j] && left[j] == right[i]
        }
        let short = left.count < right.count ? left : right
        let long = left.count < right.count ? right : left
        guard long.count == short.count + 1 else { return false }
        let mismatch = short.indices.first { short[$0] != long[$0] } ?? short.endIndex
        return short[mismatch...].elementsEqual(long[(mismatch + 1)...])
    }
}
