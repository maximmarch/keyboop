import Foundation

enum PredictionPhrase {
    static func remaining(_ suggestion: String, afterTyping typed: String) -> String? {
        guard suggestion.hasPrefix(typed), suggestion.count > typed.count else { return nil }
        return String(suggestion.dropFirst(typed.count))
    }

    /// The first displayed word can include a separator if the user typed the preceding word.
    static func firstChunk(_ text: String) -> String {
        let start = text.prefix(while: { $0 == " " })
        return String(start + text.dropFirst(start.count).prefix(while: { !$0.isWhitespace }))
    }

    static func acceptFirstWord(_ suggestion: String) -> (insertion: String, remainder: String)? {
        let first = firstChunk(suggestion)
        guard first.last?.isWhitespace == false else { return nil }
        // The inserted space also serves as the separator before an unaccepted word.
        let remainder = suggestion.dropFirst(first.count).drop(while: \.isWhitespace)
        return (first + " ", String(remainder))
    }

    // Editors may represent a typed trailing space as NBSP. Character offsets in AX are UTF-16.
    static func matchesEdit(before: String, after: String, inserted: String, position: Int,
                            newBefore: String, newAfter: String, newPosition: Int) -> Bool {
        guard newPosition == position + inserted.utf16.count, newAfter.utf16.elementsEqual(after.utf16) else { return false }
        let original = (before + inserted).replacingOccurrences(of: "\u{00a0}", with: " ").utf16
        let updated = newBefore.replacingOccurrences(of: "\u{00a0}", with: " ").utf16
        return original.suffix(updated.count).elementsEqual(updated)
    }
}

extension PredictionPhrase {
    struct InfillContext {
        static let rightLimit = 96
        let before: String
        let after: String
        let leftWord: String
        let rightWord: String
        let grammar: String

        init?(before: String, after: String, endsAtFieldEnd: Bool = true) {
            let left = String(before.reversed().prefix(while: { !$0.isNewline }).reversed())
            let rightLine = after.prefix { !$0.isNewline }
            var right = String(rightLine)
            if !endsAtFieldEnd, rightLine.count == after.count {
                guard let separator = right.lastIndex(where: \.isWhitespace) else { return nil }
                right = String(right[..<separator])
            }
            let previous = left.dropLast(left.reversed().prefix(while: Self.isSpace).count)
            let leftWord = String(previous.split(whereSeparator: \.isWhitespace).last ?? "")
            let leftKey = WordCompletionIndex.key(leftWord)
            let following = right.drop(while: Self.isSpace)
            guard WordCompletionIndex.isWord(leftKey), leftKey.count <= 32,
                  let rightFirst = right.first, let next = following.first,
                  !left.contains(where: Self.isUnsupported), !right.contains(where: Self.isUnsupported) else { return nil }
            let closing = WordCompletionIndex.closingPunctuation.contains(next)
            guard next.isLetter || closing else { return nil }
            guard Self.isSpace(rightFirst) || Self.isSpace(left.last) || closing else { return nil }
            // Dots and quotes attached to letters can be part of a URL, code or another token.
            guard !closing || following.dropFirst().first?.isLetter != true else { return nil }
            let nextWord = following.drop(while: { WordCompletionIndex.closingPunctuation.contains($0) || Self.isSpace($0) })
                                    .prefix(while: \.isLetter)
            let rightKey = WordCompletionIndex.key(String(nextWord))
            guard leftKey != rightKey else { return nil }

            self.before = left
            self.after = right
            self.leftWord = leftKey
            self.rightWord = rightKey
            let alphabet = leftKey.utf8.first.map { $0 < 128 } == true ? "[A-Za-z]" : "[А-Яа-яЁё]"
            grammar = "root ::= \" \"? \(alphabet){1,32}"
        }

        func edit(for word: String) -> InfillEdit? {
            let key = WordCompletionIndex.key(word)
            guard WordCompletionIndex.isWord(key), key.count <= 32, key != leftWord, key != rightWord,
                  key.utf8.first.map({ $0 < 128 }) == leftWord.utf8.first.map({ $0 < 128 }) else { return nil }
            let leading = Self.isSpace(before.last) ? "" : " "
            let borrowed = Self.isSpace(after.first) ? String(after.prefix(1)) : ""
            let trailing = after.first?.isLetter == true ? " " : ""
            return InfillEdit(word: word, insertion: leading + word + trailing, borrowedSpace: borrowed)
        }

        private static func isSpace(_ character: Character?) -> Bool {
            character == " " || character == "\u{00a0}"
        }

        private static func isUnsupported(_ character: Character) -> Bool {
            character == "`" || character == "\u{fffd}" || character == "\u{fffc}"
                || (character.isWhitespace && !isSpace(character))
        }
    }

    struct InfillEdit: Equatable {
        let word: String
        let insertion: String
        let borrowedSpace: String

        func verifies(before: String, after: String, position: Int, newBefore: String, newAfter: String,
                      newPosition: Int, advanced: Bool) -> Bool {
            let passed = advanced ? borrowedSpace : ""
            let expectedRight = after.dropFirst(passed.count).utf16
            guard !newBefore.isEmpty,
                  newAfter.utf16.prefix(expectedRight.count).elementsEqual(expectedRight) else { return false }
            // One extra character can enter the bounded snapshot after advancing past an existing space.
            return PredictionPhrase.matchesEdit(before: before, after: "", inserted: insertion + passed, position: position,
                                               newBefore: newBefore, newAfter: "", newPosition: newPosition)
        }
    }
}
