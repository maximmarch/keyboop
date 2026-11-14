import Foundation

/// Описание одной типографической операции внутри анализируемого фрагмента (§5).
struct TypographyOperation: Equatable {
    let ruleID: TypographyRuleID
    let range: Range<String.Index>
    let originalSubstring: String
    let replacementSubstring: String
}

/// Минимальная атомарная правка хвоста при наборе (от конца буфера назад).
struct TypographyTailPatch: Equatable {
    let deleteCount: Int
    let originalSuffix: String
    let replacementSuffix: String
    let appliedRuleIDs: [TypographyRuleID]
}

/// Результат работы `TypographyEngine` (§5).
struct TypographyResult: Equatable {
    let originalText: String
    let transformedText: String
    let operations: [TypographyOperation]
    let appliedRuleIDs: [TypographyRuleID]
    let detectedLanguage: TypographyDetectedLanguage

    var changed: Bool { transformedText != originalText }
}

/// Чистый механизм типографических преобразований KB-021.
/// Не зависит от AppKit, EventTap и TextReplacer; работает строго локально и детерминированно.
enum TypographyEngine {

    private static let unitsRussian: Set<String> = [
        "кг", "г", "мг", "т", "л", "мл", "м", "км", "см", "мм", "дм", "м²", "м³", "га",
        "с", "сек", "мин", "ч", "сут", "дн", "нед", "мес",
        "г.", "гг.", "в.", "вв.", "стр.", "с.", "рис.", "табл.",
        "руб.", "р.", "коп.", "тыс.", "млн", "млрд", "трлн",
        "шт.", "экз.", "чел.", "кВт", "МВт", "Вт", "Гц", "кГц", "МГц", "ГГц",
        "Б", "КБ", "МБ", "ГБ", "ТБ",
        "%", "‰", "₽", "$", "€", "£", "¥", "°", "°C", "°F"
    ]

    private static let unitsEnglish: Set<String> = [
        "kg", "mg", "km", "cm", "mm", "ml", "ms", "kb", "mb", "gb", "tb",
        "KB", "MB", "GB", "TB", "%", "‰", "$", "€", "£", "¥", "°", "°C", "°F"
    ]

    private static let nbsp: Character = "\u{00A0}"
    private static let narrowNbspChar: Character = "\u{202F}"

    static func analyze(_ text: String, context: TypographyContext) -> TypographyResult {
        guard !text.isEmpty else {
            return TypographyResult(
                originalText: text,
                transformedText: text,
                operations: [],
                appliedRuleIDs: [],
                detectedLanguage: .unknown
            )
        }

        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        var current = text
        var ops: [TypographyOperation] = []
        var appliedOrder: [TypographyRuleID] = []

        func recordRule(_ id: TypographyRuleID) {
            if !appliedOrder.contains(id) {
                appliedOrder.append(id)
            }
        }

        // 1. В режиме выделения — опциональная очистка лишних пробелов (до остальных правил, чтобы выровнять границы).
        if context.mode == .selection {
            if context.isRuleEnabled(.collapseSpacesSelection) {
                let next = applyCollapseSpaces(in: current, context: context)
                if next != current {
                    recordRule(.collapseSpacesSelection)
                    ops.append(TypographyOperation(
                        ruleID: .collapseSpacesSelection,
                        range: current.startIndex..<current.endIndex,
                        originalSubstring: current,
                        replacementSubstring: next
                    ))
                    current = next
                }
            }
            if context.isRuleEnabled(.trimSpaceBeforePunctSelection) {
                let next = applyTrimSpaceBeforePunct(in: current, context: context)
                if next != current {
                    recordRule(.trimSpaceBeforePunctSelection)
                    ops.append(TypographyOperation(
                        ruleID: .trimSpaceBeforePunctSelection,
                        range: current.startIndex..<current.endIndex,
                        originalSubstring: current,
                        replacementSubstring: next
                    ))
                    current = next
                }
            }
        }

        // 2. Специальные символы и многоточие
        if context.isRuleEnabled(.copyright) || context.isRuleEnabled(.registered) || context.isRuleEnabled(.trademark) {
            let next = applyTradeSymbols(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }
        if context.isRuleEnabled(.ellipsis) {
            let next = applyEllipsis(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }

        // 3. Тире и короткое тире (только в прозе)
        if context.isRuleEnabled(.emDash) {
            let next = applyEmDash(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }
        if context.isRuleEnabled(.enDashRanges) {
            let next = applyEnDashRanges(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }

        // 4. Кавычки и апострофы (поабзацно, парно и контекстно-зависимо)
        if context.isRuleEnabled(.ruQuotes) || context.isRuleEnabled(.enQuotes) || context.isRuleEnabled(.nestedQuotes) {
            let next = applyQuotes(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }
        if context.isRuleEnabled(.enApostrophe) {
            let next = applyEnglishApostrophe(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }

        // 5. Неразрывные пробелы
        if context.isRuleEnabled(.nbspUnits) || context.isRuleEnabled(.narrowNbsp) {
            let next = applyNonBreakingSpaces(in: current, context: context, applied: &appliedOrder, ops: &ops)
            current = next
        }

        return TypographyResult(
            originalText: text,
            transformedText: current,
            operations: ops,
            appliedRuleIDs: appliedOrder,
            detectedLanguage: analyzed.language
        )
    }

    /// Анализирует локальный хвост текста при наборе и возвращает минимальный суффикс-патч (от конца текста).
    static func analyzeTypingTail(_ tail: String, context: TypographyContext) -> TypographyTailPatch? {
        guard !tail.isEmpty else { return nil }
        let res = analyze(tail, context: context)
        guard res.changed else { return nil }

        var p1 = tail.startIndex
        var p2 = res.transformedText.startIndex
        while p1 < tail.endIndex && p2 < res.transformedText.endIndex && tail[p1] == res.transformedText[p2] {
            p1 = tail.index(after: p1)
            p2 = res.transformedText.index(after: p2)
        }
        guard p1 < tail.endIndex else { return nil }

        let origSuffix = String(tail[p1...])
        let replSuffix = String(res.transformedText[p2...])
        let delCount = origSuffix.count
        guard delCount > 0, origSuffix != replSuffix else { return nil }

        return TypographyTailPatch(
            deleteCount: delCount,
            originalSuffix: origSuffix,
            replacementSuffix: replSuffix,
            appliedRuleIDs: res.appliedRuleIDs
        )
    }

    // MARK: - Rule Implementations

    private static func applyTradeSymbols(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let protected = TypographyContextAnalyzer.findProtectedRanges(in: text)
        if TypographyContextAnalyzer.analyze(text: text, context: context).looksLikeCodeOrCommand {
            return text
        }

        var patterns: [(TypographyRuleID, String, String)] = []
        if context.isRuleEnabled(.copyright)  { patterns.append((.copyright,  #"\([cCсС]\)"#, "©")) }
        if context.isRuleEnabled(.registered) { patterns.append((.registered, #"\([rR]\)"#, "®")) }
        if context.isRuleEnabled(.trademark)  { patterns.append((.trademark,  #"\([tT][mM]\)"#, "™")) }

        var result = text
        for (ruleID, pattern, replacement) in patterns {
            let currentProtected = TypographyContextAnalyzer.findProtectedRanges(in: result)
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = re.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            guard !matches.isEmpty else { continue }

            for m in matches.reversed() {
                guard let range = Range(m.range, in: result) else { continue }
                if intersectsAny(range, currentProtected) || intersectsAny(range, protected) && result == text { continue }
                // Не превращаем `foo(c)` вызов функции в `foo©`: перед `(c)`/`(r)` должна быть граница (для `(tm)` допустимо после названия бренда).
                if ruleID != .trademark && range.lowerBound > result.startIndex {
                    let prev = result[result.index(before: range.lowerBound)]
                    if prev.isLetter || prev.isNumber || prev == "_" { continue }
                }
                let orig = String(result[range])
                result.replaceSubrange(range, with: replacement)
                if !applied.contains(ruleID) { applied.append(ruleID) }
                ops.append(TypographyOperation(ruleID: ruleID, range: range, originalSubstring: orig, replacementSubstring: replacement))
            }
        }
        return result
    }

    private static func applyEllipsis(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }

        guard let re = try? NSRegularExpression(pattern: #"\.\.\."#) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        let protected = analyzed.protectedRanges
        for m in matches.reversed() {
            guard let range = Range(m.range, in: result) else { continue }
            guard !intersectsAny(range, protected) else { continue }
            // Не трогаем 4+ точек подряд (`....`) или относительные пути `./` / `../`
            if range.lowerBound > result.startIndex, result[result.index(before: range.lowerBound)] == "." { continue }
            if range.upperBound < result.endIndex {
                let next = result[range.upperBound]
                if next == "." || next == "/" || next == "\\" { continue }
            }
            // Во время набора ждём границу после `...`, чтобы `....` не превратилось в `….` на третьей точке.
            if context.mode == .typing && range.upperBound == result.endIndex { continue }

            result.replaceSubrange(range, with: "…")
            if !applied.contains(.ellipsis) { applied.append(.ellipsis) }
            ops.append(TypographyOperation(ruleID: .ellipsis, range: range, originalSubstring: "...", replacementSubstring: "…"))
        }
        return result
    }

    private static func applyEmDash(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }

        // Ищем строго ` -- ` (одиночный пробел, два дефиса, одиночный пробел; не `---`).
        guard let re = try? NSRegularExpression(pattern: #"(?<=[^\s\-])\s--\s(?=[^\-\n]|$)"#) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        let protected = analyzed.protectedRanges
        for m in matches.reversed() {
            guard let range = Range(m.range, in: result) else { continue }
            guard !intersectsAny(range, protected) else { continue }
            // Проверим, что слева не оператор кода вроде `=` или `<`
            if range.lowerBound > result.startIndex {
                let prev = result[result.index(before: range.lowerBound)]
                if prev == "=" || prev == "<" || prev == ">" || prev == "+" || prev == "*" || prev == "/" { continue }
            }
            let orig = String(result[range])
            let repl = " — "
            result.replaceSubrange(range, with: repl)
            if !applied.contains(.emDash) { applied.append(.emDash) }
            ops.append(TypographyOperation(ruleID: .emDash, range: range, originalSubstring: orig, replacementSubstring: repl))
        }
        return result
    }

    private static func applyEnDashRanges(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }

        guard let re = try? NSRegularExpression(pattern: #"(?<![A-Za-zА-Яа-яЁё0-9\-/])(?<!\d\.)(\d{1,4})-(\d{1,4})(?![A-Za-zА-Яа-яЁё0-9\-/])(?!\.\d)"#) else {
            return text
        }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        let protected = analyzed.protectedRanges
        for m in matches.reversed() {
            guard let range = Range(m.range, in: result),
                  let r1 = Range(m.range(at: 1), in: result),
                  let r2 = Range(m.range(at: 2), in: result) else { continue }
            guard !intersectsAny(range, protected) else { continue }
            if context.mode == .typing && range.upperBound == result.endIndex { continue }

            // Консервативно: в диапазоне второе число должно быть >= первого (иначе 10-5 может быть вычитанием).
            if let a = Int(result[r1]), let b = Int(result[r2]), a <= b {
                let orig = String(result[range])
                let repl = "\(a)–\(b)"
                result.replaceSubrange(range, with: repl)
                if !applied.contains(.enDashRanges) { applied.append(.enDashRanges) }
                ops.append(TypographyOperation(ruleID: .enDashRanges, range: range, originalSubstring: orig, replacementSubstring: repl))
            }
        }
        return result
    }

    private static func applyQuotes(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }

        let ruEnabled = context.isRuleEnabled(.ruQuotes)
        let enEnabled = context.isRuleEnabled(.enQuotes)
        let nestedEnabled = context.isRuleEnabled(.nestedQuotes)

        // Разбиваем по строкам/абзацам: пара кавычек не перепрыгивает абзац.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for line in lines {
            if line.isEmpty {
                outLines.append(line)
                continue
            }
            let lineAnalysis = TypographyContextAnalyzer.analyze(text: line, context: context)
            if lineAnalysis.looksLikeCodeOrCommand {
                outLines.append(line)
                continue
            }
            // Не трогаем строки, явно похожие на JSON/код (`"key":` или `= "val"`).
            if line.contains("\":") || line.contains("= \"") || line.contains("=\"") {
                outLines.append(line)
                continue
            }

            let targetStyle: CharacterStyle?
            switch context.languageMode {
            case .ru:
                targetStyle = ruEnabled ? .russian : nil
            case .en:
                targetStyle = enEnabled ? .english : nil
            case .auto:
                switch lineAnalysis.language {
                case .ru:
                    targetStyle = ruEnabled ? .russian : nil
                case .en:
                    targetStyle = enEnabled ? .english : nil
                case .mixed:
                    if analyzed.language == .ru && ruEnabled {
                        targetStyle = .russian
                    } else {
                        targetStyle = nil
                    }
                case .unknown:
                    if context.activeLayoutHint == "ru" && ruEnabled {
                        targetStyle = .russian
                    } else if context.activeLayoutHint == "en" && enEnabled {
                        targetStyle = .english
                    } else {
                        targetStyle = nil
                    }
                }
            }

            guard let style = targetStyle else {
                outLines.append(line)
                continue
            }

            let updated = replacePairedQuotesInParagraph(
                line,
                style: style,
                nestedEnabled: nestedEnabled && style == .russian,
                protected: lineAnalysis.protectedRanges,
                applied: &applied,
                ops: &ops
            )
            outLines.append(updated)
        }

        return outLines.joined(separator: "\n")
    }

    private enum CharacterStyle {
        case russian // «...» и „...“
        case english // “...”
    }

    private static func replacePairedQuotesInParagraph(
        _ line: String,
        style: CharacterStyle,
        nestedEnabled: Bool,
        protected: [Range<String.Index>],
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        var chars = Array(line)
        var protectedMask = Array(repeating: false, count: chars.count)
        for range in protected {
            let startOffset = line.distance(from: line.startIndex, to: range.lowerBound)
            let endOffset = line.distance(from: line.startIndex, to: range.upperBound)
            for idx in max(0, startOffset)..<min(chars.count, endOffset) {
                protectedMask[idx] = true
            }
        }

        var openDoubleIndices: [Int] = []
        var openSingleIndices: [Int] = []
        var pairedDoubles: [(open: Int, close: Int)] = []
        var pairedSingles: [(open: Int, close: Int)] = []

        func canOpenQuote(at i: Int) -> Bool {
            guard i + 1 < chars.count else { return false }
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next = chars[i + 1]
            let prevOK = prev == nil || prev!.isWhitespace || prev == "(" || prev == "[" || prev == "{" || prev == "—" || prev == "«" || prev == "„" || prev == "\""
            let nextOK = !next.isWhitespace && next != ")" && next != "]" && next != "}" && next != "." && next != "," && next != ";" && next != ":" && next != "!" && next != "?" && next != "\"" && next != "'"
            return prevOK && nextOK
        }

        func canCloseQuote(at i: Int) -> Bool {
            guard i > 0 else { return false }
            let prev = chars[i - 1]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            let prevOK = !prev.isWhitespace && prev != "(" && prev != "[" && prev != "{" && prev != "«" && prev != "„" && prev != "\""
            let nextOK = next == nil || next!.isWhitespace || next == "." || next == "," || next == "!" || next == "?" || next == ";" || next == ":" || next == ")" || next == "]" || next == "}" || next == "—" || next == "»" || next == "”" || next == "\"" || next == "'"
            return prevOK && nextOK
        }

        for i in chars.indices {
            if protectedMask[i] { continue }
            let ch = chars[i]
            if ch == "\"" {
                if !openDoubleIndices.isEmpty && canCloseQuote(at: i) {
                    let openIdx = openDoubleIndices.removeLast()
                    pairedDoubles.append((openIdx, i))
                } else if canOpenQuote(at: i) {
                    openDoubleIndices.append(i)
                }
            } else if nestedEnabled && ch == "'" && !openDoubleIndices.isEmpty {
                // Внутренние одинарные кавычки `'...'` внутри потенциальных внешних двойных кавычек.
                if !openSingleIndices.isEmpty && canCloseQuote(at: i) {
                    let openIdx = openSingleIndices.removeLast()
                    pairedSingles.append((openIdx, i))
                } else if canOpenQuote(at: i) {
                    openSingleIndices.append(i)
                }
            }
        }

        // Фильтруем внутренние `'...'`: заменяем только если внешняя пара действительно закрылась.
        let confirmedSingles = pairedSingles.filter { single in
            pairedDoubles.contains { outer in outer.open < single.open && single.close < outer.close }
        }

        guard !pairedDoubles.isEmpty else { return line }

        let openOuter: Character = (style == .russian) ? "«" : "“"
        let closeOuter: Character = (style == .russian) ? "»" : "”"
        let ruleUsed: TypographyRuleID = (style == .russian) ? .ruQuotes : .enQuotes

        for pair in pairedDoubles {
            chars[pair.open] = openOuter
            chars[pair.close] = closeOuter
        }
        if !applied.contains(ruleUsed) { applied.append(ruleUsed) }
        ops.append(TypographyOperation(ruleID: ruleUsed, range: line.startIndex..<line.endIndex, originalSubstring: line, replacementSubstring: String(chars)))

        if nestedEnabled && !confirmedSingles.isEmpty {
            for pair in confirmedSingles {
                chars[pair.open] = "„"
                chars[pair.close] = "“"
            }
            if !applied.contains(.nestedQuotes) { applied.append(.nestedQuotes) }
            ops.append(TypographyOperation(ruleID: .nestedQuotes, range: line.startIndex..<line.endIndex, originalSubstring: line, replacementSubstring: String(chars)))
        }

        return String(chars)
    }

    private static func applyEnglishApostrophe(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }
        guard analyzed.language == .en || context.languageMode == .en else { return text }

        guard let re = try? NSRegularExpression(pattern: #"(?<=[A-Za-z])'(?=[A-Za-z])"#) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        let protected = analyzed.protectedRanges
        for m in matches.reversed() {
            guard let range = Range(m.range, in: result), !intersectsAny(range, protected) else { continue }
            result.replaceSubrange(range, with: "’")
            if !applied.contains(.enApostrophe) { applied.append(.enApostrophe) }
            ops.append(TypographyOperation(ruleID: .enApostrophe, range: range, originalSubstring: "'", replacementSubstring: "’"))
        }
        return result
    }

    private static func applyNonBreakingSpaces(
        in text: String,
        context: TypographyContext,
        applied: inout [TypographyRuleID],
        ops: inout [TypographyOperation]
    ) -> String {
        let analyzed = TypographyContextAnalyzer.analyze(text: text, context: context)
        guard !analyzed.looksLikeCodeOrCommand else { return text }

        let useNarrow = context.isRuleEnabled(.narrowNbsp)
        let nbspEnabled = context.isRuleEnabled(.nbspUnits)
        guard nbspEnabled || useNarrow else { return text }

        var result = text
        let protected = analyzed.protectedRanges

        // 1) Знак `№ 15` / `§ 3` → `№\u{00A0}15`
        if nbspEnabled, let reSign = try? NSRegularExpression(pattern: #"([№§]) (\d+)"#) {
            let matches = reSign.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for m in matches.reversed() {
                guard let fullRange = Range(m.range, in: result),
                      let signRange = Range(m.range(at: 1), in: result),
                      let numRange = Range(m.range(at: 2), in: result) else { continue }
                guard !intersectsAny(fullRange, protected) else { continue }
                if context.mode == .typing && fullRange.upperBound == result.endIndex { continue }
                let orig = String(result[fullRange])
                let repl = "\(result[signRange])\(nbsp)\(result[numRange])"
                result.replaceSubrange(fullRange, with: repl)
                if !applied.contains(.nbspUnits) { applied.append(.nbspUnits) }
                ops.append(TypographyOperation(ruleID: .nbspUnits, range: fullRange, originalSubstring: orig, replacementSubstring: repl))
            }
        }

        // 2) Число + обычный пробел + единица измерения/знак (`10 кг`, `25 %`, `100 ₽`, `2026 г.`)
        //    Захватываем как буквенные единицы (с опциональной точкой), так и знаки (% ‰ ₽ $ € £ ¥ °C °F).
        let unitPattern = #"(?<![A-Za-zА-Яа-яЁё_])(\d+(?:[.,]\d+)?)( )([A-Za-zА-Яа-яЁё²³°%‰₽$€£¥]+\.?)"#
        if let reUnit = try? NSRegularExpression(pattern: unitPattern) {
            let curProtected = TypographyContextAnalyzer.findProtectedRanges(in: result)
            let matches = reUnit.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for m in matches.reversed() {
                guard let fullRange = Range(m.range, in: result),
                      let spaceRange = Range(m.range(at: 2), in: result),
                      let unitRange = Range(m.range(at: 3), in: result) else { continue }
                guard !intersectsAny(fullRange, curProtected) else { continue }

                let rawUnit = String(result[unitRange])
                let exactRu = unitsRussian.contains(rawUnit) || unitsRussian.contains(rawUnit.lowercased())
                let exactEn = unitsEnglish.contains(rawUnit)
                let baseUnit = rawUnit.hasSuffix(".") ? String(rawUnit.dropLast()) : rawUnit
                let hasTrailingSentenceDot = !exactRu && !exactEn && rawUnit.hasSuffix(".")

                let isKnownRu = exactRu || unitsRussian.contains(baseUnit) || unitsRussian.contains(baseUnit.lowercased())
                let isKnownEn = exactEn || unitsEnglish.contains(baseUnit)
                guard isKnownRu || (analyzed.language == .en && isKnownEn) else { continue }

                // Во время набора ждём границу после единицы измерения (пробел, пунктуацию или точку),
                // чтобы не заменять префикс недопечатанного слова.
                let isSymbolUnit = rawUnit.contains("%") || rawUnit.contains("‰") || rawUnit.contains("₽")
                    || rawUnit.contains("$") || rawUnit.contains("€") || rawUnit.contains("£") || rawUnit.contains("¥")
                if context.mode == .typing && fullRange.upperBound == result.endIndex && !rawUnit.hasSuffix(".") && !isSymbolUnit {
                    continue
                }

                // Узкий неразрывный U+202F применяем только при включённом `narrowNbsp` для % / ‰ / валют.
                let trimmedForNarrow = hasTrailingSentenceDot ? baseUnit : rawUnit
                let isSymbolForNarrow = (trimmedForNarrow == "%" || trimmedForNarrow == "‰" || trimmedForNarrow == "₽" || trimmedForNarrow == "$" || trimmedForNarrow == "€" || trimmedForNarrow == "£" || trimmedForNarrow == "¥")
                let chosenSpace: Character
                let ruleUsed: TypographyRuleID
                if useNarrow && isSymbolForNarrow {
                    chosenSpace = narrowNbspChar
                    ruleUsed = .narrowNbsp
                } else if nbspEnabled {
                    chosenSpace = nbsp
                    ruleUsed = .nbspUnits
                } else {
                    continue
                }

                result.replaceSubrange(spaceRange, with: String(chosenSpace))
                if !applied.contains(ruleUsed) { applied.append(ruleUsed) }
                ops.append(TypographyOperation(ruleID: ruleUsed, range: spaceRange, originalSubstring: " ", replacementSubstring: String(chosenSpace)))
            }
        }

        return result
    }

    private static func applyCollapseSpaces(in text: String, context: TypographyContext) -> String {
        let protected = TypographyContextAnalyzer.findProtectedRanges(in: text)
        guard let re = try? NSRegularExpression(pattern: #"(?<=[^\s]) {2,}(?=[^\s])"#) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result), !intersectsAny(r, protected) else { continue }
            result.replaceSubrange(r, with: " ")
        }
        return result
    }

    private static func applyTrimSpaceBeforePunct(in text: String, context: TypographyContext) -> String {
        let protected = TypographyContextAnalyzer.findProtectedRanges(in: text)
        guard let re = try? NSRegularExpression(pattern: #"(?<=\S)[ \u00A0]+([,!\?;:]|\.(?!\.))"#) else { return text }
        let matches = re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for m in matches.reversed() {
            guard let fullR = Range(m.range, in: result),
                  let punctR = Range(m.range(at: 1), in: result),
                  !intersectsAny(fullR, protected) else { continue }
            let punct = String(result[punctR])
            result.replaceSubrange(fullR, with: punct)
        }
        return result
    }

    private static func intersectsAny(_ range: Range<String.Index>, _ list: [Range<String.Index>]) -> Bool {
        for r in list {
            if r.lowerBound < range.upperBound && range.lowerBound < r.upperBound {
                return true
            }
        }
        return false
    }
}
