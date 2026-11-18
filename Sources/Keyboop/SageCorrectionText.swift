import Foundation

enum SageCorrectionText {
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
