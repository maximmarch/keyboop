import Foundation

/// Exact-prefix completions from explicit terms and the current accessibility snapshot.
struct PredictionReferenceIndex {
    struct Preferences: Equatable {
        let useField: Bool
        let glossary: String
    }

    enum Source: String {
        case glossary = "prediction.glossary"
        case field = "prediction.fieldWord"
    }

    enum Lookup {
        case finishedWord
        case suggestion(suffix: String, source: Source)
        case noMatch
    }

    private let glossary: Words
    var isEmpty: Bool { glossary.keys.isEmpty }

    init(glossary: String) {
        self.glossary = Words(glossary.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }

    func lookup(prefix: String, before: String, after: String, startsAtFieldStart: Bool,
                endsAtFieldEnd: Bool, useField: Bool) -> Lookup {
        let key = WordCompletionIndex.key(prefix)
        let field = useField ? Words(Self.fieldWords(before: before, after: after,
                                                    startsAtFieldStart: startsAtFieldStart,
                                                    endsAtFieldEnd: endsAtFieldEnd)) : nil
        if glossary.spellings[key] != nil || field?.spellings[key] != nil { return .finishedWord }
        if let suffix = glossary.suffix(for: prefix, key: key) { return .suggestion(suffix: suffix, source: .glossary) }
        if let suffix = field?.suffix(for: prefix, key: key) { return .suggestion(suffix: suffix, source: .field) }
        return .noMatch
    }

    static func isInsideCode(_ text: String) -> Bool {
        text.reduce(into: false) { inside, character in
            if character == "`" { inside.toggle() }
        }
    }

    private static func fieldWords(before: String, after: String, startsAtFieldStart: Bool,
                                   endsAtFieldEnd: Bool) -> [String] {
        let left = before.split(whereSeparator: \.isWhitespace).dropLast() // The last token is being typed.
        let right = after.split(whereSeparator: \.isWhitespace)[...]
        return proseWords(left, dropLeadingEdge: !startsAtFieldStart && before.first?.isWhitespace == false) +
            proseWords(right, dropTrailingEdge: !endsAtFieldEnd && after.last?.isWhitespace == false)
    }

    private static func proseWords(_ tokens: ArraySlice<Substring>, dropLeadingEdge: Bool = false,
                                   dropTrailingEdge: Bool = false) -> [String] {
        var insideCode = false
        return tokens.indices.compactMap { position in
            let token = tokens[position]
            let isCode = insideCode || token.contains("`")
            if isInsideCode(String(token)) { insideCode.toggle() }
            guard !isCode,
                  !dropLeadingEdge || position != tokens.startIndex,
                  !dropTrailingEdge || position + 1 != tokens.endIndex else { return nil }
            let leading = token.drop(while: { WordCompletionIndex.openingPunctuation.contains($0) })
            let trailing = leading.reversed().drop(while: { WordCompletionIndex.closingPunctuation.contains($0) })
            return String(trailing.reversed())
        }
    }

    private struct Words {
        let spellings: [String: [String]]
        let keys: [String]

        init(_ words: [String]) {
            spellings = Dictionary(grouping: words.map(\.precomposedStringWithCanonicalMapping).filter {
                WordCompletionIndex.isWord(WordCompletionIndex.key($0))
            }, by: WordCompletionIndex.key)
            keys = spellings.keys.sorted()
        }

        func suffix(for prefix: String, key: String) -> String? {
            let start = WordCompletionIndex.lowerBound(of: key, in: keys)
            guard start < keys.count, keys[start].hasPrefix(key), keys[start] != key,
                  start + 1 == keys.count || !keys[start + 1].hasPrefix(key),
                  let variants = spellings[keys[start]] else { return nil }
            let normalized = prefix.precomposedStringWithCanonicalMapping
            let length = normalized.count
            let word: String
            if let exact = variants.first(where: { $0.hasPrefix(normalized) }) { word = exact }
            else if normalized == normalized.uppercased() { word = variants[0].uppercased() }
            else if normalized.dropFirst() == key.dropFirst() { word = variants[0] }
            else { return nil }
            let suffix = word.dropFirst(length)
            return suffix.count >= 2 ? String(suffix) : nil
        }
    }
}
