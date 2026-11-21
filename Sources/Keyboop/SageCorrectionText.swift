import Foundation

enum SageTypingMode: String, CaseIterable {
    case automatic, confirmation, off

    var localizationKey: String { "sage.typing." + rawValue }
}

protocol SageTypingEditor {
    var isFocused: Bool { get }
    var selection: NSRange? { get }
    func select(_ range: NSRange) -> Bool
    func text(in range: NSRange) -> String?
    func replaceSelection(with text: String) -> Bool
    func collapseSelection()
}

enum SageCorrectionText {
    static let typingWindowLength = 384

    private static let sentenceBoundary = try! NSRegularExpression(pattern: #"[.!?…]+[»”"’\)\]]*\h+|\R\h*"#)

    static func typingRange(before: String, startsAtFieldStart: Bool) -> NSRange? {
        let text = before as NSString
        let endOfBody = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endOfBody.count >= 2, before.last?.isNewline == false else { return nil }
        let trailing = before.reversed().prefix(while: \.isWhitespace)
        guard !trailing.contains(where: \.isNewline) else { return nil }
        let bodyEnd = text.length - String(trailing).utf16.count
        let start = sentenceBoundary.matches(in: before, range: NSRange(location: 0, length: text.length))
            .map { NSMaxRange($0.range) }.last { $0 < bodyEnd }
        guard let start = start ?? (startsAtFieldStart ? 0 : nil) else { return nil }
        let range = NSRange(location: start, length: text.length - start)
        guard supports(text.substring(with: range)) else { return nil }
        return range
    }

    struct TypingEdit {
        let range: NSRange
        let replacement: String

        func apply(to original: String, startingAt start: Int, in editor: SageTypingEditor) -> Bool {
            guard editor.isFocused else { return false }
            let source = original as NSString
            let change = NSRange(location: start + range.location, length: range.length)
            var caret = NSRange(location: start + source.length, length: 0)
            defer {
                // A setter can expand the selection or change it even when it reports failure.
                if editor.isFocused || (change.length > 0 && editor.selection == change) {
                    restoreCaret(caret, in: editor)
                }
            }

            guard editor.select(change), editor.selection == change, editor.isFocused else { return false }
            let expected = source.substring(with: range)
            guard range.length == 0 || editor.text(in: change)?.utf16.elementsEqual(expected.utf16) == true else {
                return false
            }

            let wrote = editor.replaceSelection(with: replacement)
            let corrected = source.replacingCharacters(in: range, with: replacement)
            let updated = NSRange(location: start, length: corrected.utf16.count)
            let verified = editor.text(in: updated)?.utf16.elementsEqual(corrected.utf16) == true
            if verified { caret.location = NSMaxRange(updated) }
            return verified || wrote
        }

        private func restoreCaret(_ caret: NSRange, in editor: SageTypingEditor) {
            _ = editor.select(caret)
            guard editor.selection != caret else { return }
            _ = editor.select(caret)
            if let selection = editor.selection, selection.length > 0, editor.isFocused {
                editor.collapseSelection()
            }
        }
    }

    static func typingEdit(from original: String, to answer: String) -> TypingEdit? {
        guard answer.utf16.count <= typingWindowLength,
              let corrected = validated(answer, for: original) else { return nil }
        // A typing correction should make local spelling or punctuation edits.
        let before = Array(original)
        let after = Array(corrected)
        let limit = max(2, before.count / 4)
        guard abs(before.count - after.count) <= limit,
              editDistance(before, after) <= limit else { return nil }
        let prefix = zip(before, after).prefix { $0 == $1 }.count
        let suffix = zip(before.dropFirst(prefix).reversed(), after.dropFirst(prefix).reversed())
            .prefix { $0 == $1 }.count
        let old = String(before[prefix..<(before.count - suffix)])
        let new = String(after[prefix..<(after.count - suffix)])
        guard !old.utf16.elementsEqual(new.utf16) else { return nil }
        let range = NSRange(location: String(before.prefix(prefix)).utf16.count, length: old.utf16.count)
        let overlapsProtectedText = TypographyContextAnalyzer.findProtectedRanges(in: original).contains {
            let protected = NSRange($0, in: original)
            return range.location < NSMaxRange(protected) && NSMaxRange(range) > protected.location
        }
        guard !overlapsProtectedText else { return nil }
        return TypingEdit(range: range, replacement: new)
    }

    // Dictation can be much longer than a model request. Cut on whitespace and leave
    // the original separators in place, including the exact newline sequence.
    static let dictationChunkBytes = 720
    private static let dictationToken = try! NSRegularExpression(pattern: #"\R|[^\s]+\h*|\h+"#)

    static func dictationChunks(_ text: String) -> [String] {
        let source = text as NSString
        let matches = dictationToken.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result: [String] = []
        var chunk = ""
        var cursor = 0
        for match in matches {
            // A separator outside the model's alphabet is copied without being interpreted.
            if match.range.location > cursor {
                if !chunk.isEmpty { result.append(chunk); chunk = "" }
                result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let token = source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
            if token.contains(where: \.isNewline) || chunk.utf8.count + token.utf8.count > dictationChunkBytes {
                if !chunk.isEmpty { result.append(chunk); chunk = "" }
            }
            if token.contains(where: \.isNewline) || token.utf8.count > dictationChunkBytes {
                result.append(token)
            } else {
                chunk += token
            }
        }
        if !chunk.isEmpty { result.append(chunk) }
        if cursor < source.length { result.append(source.substring(from: cursor)) }
        return result
    }

    static func validatedDictation(_ answer: String, for original: String) -> String? {
        guard supports(original), original.utf8.count <= dictationChunkBytes,
              answer.utf8.count <= 2 * dictationChunkBytes,
              let corrected = validated(answer, for: original) else { return nil }
        let source = Array(original)
        let output = Array(corrected)
        let allowedEdits = max(2, source.count / 5)
        guard abs(source.count - output.count) <= allowedEdits,
              editDistance(source, output) <= allowedEdits else { return nil }
        return corrected
    }

    private static func editDistance(_ before: [Character], _ after: [Character]) -> Int {
        var previous = Array(0...after.count)
        var current = previous
        for (row, lhs) in before.enumerated() {
            current[0] = row + 1
            for (column, rhs) in after.enumerated() {
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1,
                                          previous[column] + (lhs == rhs ? 0 : 1))
            }
            swap(&current, &previous)
        }
        return previous[after.count]
    }

    static func supports(_ text: String) -> Bool {
        guard !containsUnsupportedCharacters(text) else { return false }
        let protected = TypographyContextAnalyzer.findProtectedRanges(in: text)
        return text.indices.contains { index in
            !protected.contains(where: { $0.contains(index) }) &&
                text[index].unicodeScalars.contains { (0x0410...0x044F).contains($0.value) || $0 == "ё" || $0 == "Ё" }
        }
    }

    static func validated(_ answer: String, for original: String) -> String? {
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !containsUnsupportedCharacters(body) else { return nil }

        let leading = original.prefix(while: \.isWhitespace)
        let trailing = original.dropFirst(leading.count).reversed().prefix(while: \.isWhitespace).reversed()
        let result = String(leading) + body + String(trailing)
        guard original.filter(\.isNewline) == result.filter(\.isNewline),
              protectedFragments(in: original) == protectedFragments(in: result),
              identifiers(in: original) == identifiers(in: result) else { return nil }
        return result
    }

    private static func protectedFragments(in text: String) -> [String] {
        TypographyContextAnalyzer.findProtectedRanges(in: text).map { String(text[$0]) }
    }

    // Preserve names such as Keyboop and PR, and avoid changing numeric values.
    private static let identifierPattern = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_]*|[0-9]+(?:[.,][0-9]+)*"#)

    private static func identifiers(in text: String) -> [String] {
        identifierPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func containsUnsupportedCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0 == "\u{FFFC}" || $0 == "\u{FFFD}" || ($0.value < 32 && ![9, 10, 13].contains($0.value))
        }
    }
}
