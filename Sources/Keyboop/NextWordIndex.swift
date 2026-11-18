import Foundation

struct NextWordIndex: Decodable {
    let one: [String: String]
    let two: [String: String]

    func predict(before: String, startsAtFieldStart: Bool, expectedLastWord: String? = nil) -> String? {
        guard before.last == " " else { return nil }
        let context = before.dropLast()
        guard let lastCharacter = context.last, !lastCharacter.isWhitespace else { return nil }

        let reversed = context.reversed()
        let last = String(reversed.prefix(while: { !$0.isWhitespace }).reversed())
        let lastKey = WordCompletionIndex.key(last)
        if let expectedLastWord, lastKey != WordCompletionIndex.key(expectedLastWord) { return nil }
        guard WordCompletionIndex.isWord(lastKey) else { return nil }
        let remaining = context.dropLast(last.count)
        guard !remaining.isEmpty || startsAtFieldStart else { return nil }

        // A newline or punctuation terminates the two-word context.
        let previousText = remaining.reversed().drop(while: { $0 == " " || $0 == "\t" })
        let previous = String(previousText.prefix(while: { !$0.isWhitespace }).reversed())
        let previousKey = WordCompletionIndex.key(previous)
        let twoWordsKnown = previousText.count > previous.count || startsAtFieldStart
        let pair = twoWordsKnown && WordCompletionIndex.isWord(previousKey) ? two[previousKey + " " + lastKey] : nil
        guard let candidate = pair ?? one[lastKey], candidate.count >= 2, WordCompletionIndex.isWord(candidate),
              let first = lastKey.unicodeScalars.first, let predicted = candidate.unicodeScalars.first,
              first.isASCII == predicted.isASCII, candidate != lastKey else { return nil }
        return candidate
    }
}
