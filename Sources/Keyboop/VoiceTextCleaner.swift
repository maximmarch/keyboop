import Foundation

/// Детерминированная очистка текста диктовки:
/// удаление слов-паразитов (с сохранением регистра начала предложения и пунктуации)
/// и схлопывание заиканий (3+ подряд идущих повтора одного слова).
enum VoiceTextCleaner {

    // Универсальные междометия-хезитации, которые безопасны к удалению независимо от языка.
    private static let universalFillers: Set<String> = [
        // Латиница
        "uh", "uhh", "uhhh", "uhm", "umm", "ummm", "uh-huh", "uhuh",
        "ehh", "ehm", "hmm", "hmmm", "hm", "mmm", "mmmm", "erm", "errm",
        // Кириллица
        "ээ", "эээ", "ээээ", "аа", "ааа", "аааа",
        "мм", "ммм", "мммм", "хм", "хмм", "гм", "эм", "эмм", "нуу", "нууу",
    ]

    // Слова-паразиты, которые можно безопасно удалять только при известном языке вывода
    // (чтобы короткие слова одного языка не ломали текст на другом).
    private static let languageGatedFillers: [String: Set<String>] = [
        "en": ["um", "uh", "ah", "er", "eh"],
        "ru": ["э", "эм"],
        "de": ["äh", "ähm", "ehm"],
        "fr": ["euh", "heu", "hum"],
    ]

    private static let punctuationChars = CharacterSet(charactersIn: ".,!?;:—–-()[]\"'«»`~…")

    /// Основная точка входа для очистки распознанного текста.
    static func clean(
        _ text: String,
        languageHint: String?,
        removeFillers: Bool,
        collapseStutters: Bool
    ) -> String {
        var result = text
        if removeFillers {
            result = removeFillerWords(result, languageHint: languageHint)
        }
        if collapseStutters {
            result = self.collapseStutters(result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Разрешает эффективный 2-буквенный код языка (`ru`, `en`, ...).
    static func effectiveLanguage(for hint: String?) -> String? {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "auto" else {
            return nil
        }
        if let dash = raw.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(raw[..<dash])
        }
        return raw
    }

    static func removeFillerWords(_ text: String, languageHint: String?) -> String {
        guard !text.isEmpty else { return text }

        let lang = effectiveLanguage(for: languageHint)
        var fillers = universalFillers
        if let lang, let extra = languageGatedFillers[lang] {
            fillers.formUnion(extra)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cleanedLines = lines.map { line -> String in
            cleanLineFillers(String(line), fillers: fillers)
        }
        return cleanedLines.joined(separator: "\n")
    }

    /// Схлопывает 3 и более подряд идущих повторений одного слова (`"я я я хочу"` -> `"я хочу"`).
    /// Намеренно не трогает 2 повторения (`"да да"`, `"bye bye"`).
    static func collapseStutters(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cleanedLines = lines.map { cleanLineStutters(String($0)) }
        return cleanedLines.joined(separator: "\n")
    }

    // MARK: - Line helpers

    private static func cleanLineFillers(_ line: String, fillers: Set<String>) -> String {
        let rawTokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !rawTokens.isEmpty else { return line }

        var kept: [String] = []
        kept.reserveCapacity(rawTokens.count)
        var capitalOwed = false

        for token in rawTokens {
            let parts = splitToken(token)
            let normalized = normalizeWord(parts.core)

            if !normalized.isEmpty && fillers.contains(normalized) {
                if startsWithUppercase(parts.core) {
                    capitalOwed = true
                }
                if let endPunct = sentenceTerminator(in: parts.trailing) {
                    capitalOwed = true
                    attachSentenceTerminator(endPunct, to: &kept)
                }
                continue
            }

            // Одиночная запятая после удалённого слова-паразита не должна оставаться висеть в начале строки.
            if kept.isEmpty && isOrphanCommaOrSeparator(token) {
                continue
            }

            var adjusted = token
            if capitalOwed {
                adjusted = restoreCapitalIfNeeded(adjusted)
                capitalOwed = false
            }
            kept.append(adjusted)
        }

        return kept.joined(separator: " ")
    }

    private static func cleanLineStutters(_ line: String) -> String {
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 3 else { return line }

        var out: [String] = []
        out.reserveCapacity(tokens.count)

        var i = 0
        while i < tokens.count {
            let firstParts = splitToken(tokens[i])
            let base = normalizeWord(firstParts.core)

            guard isAlphabeticWord(base) else {
                out.append(tokens[i])
                i += 1
                continue
            }

            var j = i + 1
            while j < tokens.count {
                // Не схлопываем слова через границу предложения (".", "!", "?").
                let prevParts = splitToken(tokens[j - 1])
                if sentenceTerminator(in: prevParts.trailing) != nil {
                    break
                }
                let nextParts = splitToken(tokens[j])
                if !nextParts.leading.isEmpty {
                    break
                }
                if normalizeWord(nextParts.core) == base {
                    j += 1
                } else {
                    break
                }
            }

            let runLength = j - i
            if runLength >= 3 {
                // Сохраняем ведущую пунктуацию и регистр первого слова + хвостовую пунктуацию последнего.
                let lastParts = splitToken(tokens[j - 1])
                out.append(firstParts.leading + firstParts.core + lastParts.trailing)
                i = j
            } else {
                out.append(tokens[i])
                i += 1
            }
        }

        return out.joined(separator: " ")
    }

    // MARK: - Token utilities

    private struct TokenParts {
        let leading: String
        let core: String
        let trailing: String
    }

    private static func splitToken(_ token: String) -> TokenParts {
        let scalars = Array(token.unicodeScalars)
        var start = 0
        while start < scalars.count && punctuationChars.contains(scalars[start]) {
            start += 1
        }
        var end = scalars.count
        while end > start && punctuationChars.contains(scalars[end - 1]) {
            end -= 1
        }
        let leading = String(String.UnicodeScalarView(scalars[..<start]))
        let core = String(String.UnicodeScalarView(scalars[start..<end]))
        let trailing = String(String.UnicodeScalarView(scalars[end...]))
        return TokenParts(leading: leading, core: core, trailing: trailing)
    }

    private static func normalizeWord(_ core: String) -> String {
        core.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func isAlphabeticWord(_ normalized: String) -> Bool {
        !normalized.isEmpty && normalized.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func startsWithUppercase(_ core: String) -> Bool {
        guard let first = core.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    private static func restoreCapitalIfNeeded(_ token: String) -> String {
        let parts = splitToken(token)
        guard let first = parts.core.first else { return token }
        let upper = String(first).uppercased()
        let rest = parts.core.dropFirst()
        return parts.leading + upper + rest + parts.trailing
    }

    private static func sentenceTerminator(in trailing: String) -> Character? {
        for ch in trailing.reversed() {
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                return ch
            }
        }
        return nil
    }

    private static func attachSentenceTerminator(_ terminator: Character, to kept: inout [String]) {
        guard var last = kept.popLast() else { return }
        if sentenceTerminator(in: last) != nil {
            kept.append(last)
            return
        }
        while let tail = last.last, tail == "," || tail == ";" || tail == ":" {
            last.removeLast()
        }
        kept.append(last + String(terminator))
    }

    private static func isOrphanCommaOrSeparator(_ token: String) -> Bool {
        token == "," || token == ";" || token == ":" || token == "—" || token == "-"
    }
}
