import Foundation

/// Контекст, передаваемый в `TypographyEngine` для анализа фрагмента текста или выделения (§5).
struct TypographyContext: Equatable {
    enum Mode: Equatable {
        case typing
        case selection
    }

    let mode: Mode
    let languageMode: TypographyLanguageMode
    let activeLayoutHint: String?   // "ru" | "en" | nil
    let bundleID: String
    let rules: [TypographyRule]
    let allowUnsafeProseInMixed: Bool

    init(
        mode: Mode,
        languageMode: TypographyLanguageMode = .auto,
        activeLayoutHint: String? = nil,
        bundleID: String = "",
        rules: [TypographyRule],
        allowUnsafeProseInMixed: Bool = false
    ) {
        self.mode = mode
        self.languageMode = languageMode
        self.activeLayoutHint = activeLayoutHint
        self.bundleID = bundleID
        self.rules = rules
        self.allowUnsafeProseInMixed = allowUnsafeProseInMixed
    }

    func isRuleEnabled(_ id: TypographyRuleID) -> Bool {
        rules.first(where: { $0.id == id })?.enabled ?? false
    }
}

/// Результат анализа текстового контекста: язык, уверенность и защищённые диапазоны (URL, email, код, CLI).
struct TypographyAnalyzedContext {
    let language: TypographyDetectedLanguage
    let confidence: Double
    let protectedRanges: [Range<String.Index>]
    let looksLikeCodeOrCommand: Bool

    func isIndexProtected(_ idx: String.Index) -> Bool {
        for r in protectedRanges where r.contains(idx) {
            return true
        }
        return false
    }

    func intersectsProtected(_ range: Range<String.Index>) -> Bool {
        for r in protectedRanges {
            if r.lowerBound < range.upperBound && range.lowerBound < r.upperBound {
                return true
            }
        }
        return false
    }
}

/// Анализатор языка, границ фрагментов, URL/email/путей/кода/CLI (§5, §6).
/// Работает строго локально, без сети и без блокирующих AX-вызовов.
enum TypographyContextAnalyzer {

    static let terminalAndCodeBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.Console",
        "io.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "co.zeit.hyper", "org.tabby", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode",
        "sh.cursor.Cursor", "com.exafunction.windsurf", "com.panic.Nova", "dev.zed.Zed",
        "com.sublimetext.4", "com.sublimetext.3", "org.vim.MacVim", "com.github.atom",
    ]

    static func isDefaultTerminalOrCodeApp(_ bundleID: String) -> Bool {
        if terminalAndCodeBundleIDs.contains(bundleID) { return true }
        if bundleID.hasPrefix("com.jetbrains") || bundleID.hasPrefix("dev.warp.Warp") { return true }
        return false
    }

    static func analyze(text: String, context: TypographyContext) -> TypographyAnalyzedContext {
        let protected = findProtectedRanges(in: text)
        let (lang, confidence) = detectLanguage(
            in: text,
            excluding: protected,
            preferred: context.languageMode,
            layoutHint: context.activeLayoutHint
        )
        let isCode = detectCodeOrCommand(text: text, protectedRanges: protected)
        return TypographyAnalyzedContext(
            language: lang,
            confidence: confidence,
            protectedRanges: protected,
            looksLikeCodeOrCommand: isCode
        )
    }

    static func detectLanguage(
        in text: String,
        excluding protected: [Range<String.Index>],
        preferred: TypographyLanguageMode,
        layoutHint: String?
    ) -> (TypographyDetectedLanguage, Double) {
        switch preferred {
        case .ru:
            return (.ru, 1.0)
        case .en:
            return (.en, 1.0)
        case .auto:
            break
        }

        var ruCount = 0
        var enCount = 0
        var idx = text.startIndex
        while idx < text.endIndex {
            let inProtected = protected.contains { $0.contains(idx) }
            if !inProtected {
                for s in text[idx].unicodeScalars {
                    if (0x0410...0x044F).contains(s.value) || s.value == 0x0401 || s.value == 0x0451 {
                        ruCount += 1
                    } else if (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value) {
                        enCount += 1
                    }
                }
            }
            idx = text.index(after: idx)
        }

        let total = ruCount + enCount
        if total == 0 {
            if layoutHint == "ru" { return (.ru, 0.75) }
            if layoutHint == "en" { return (.en, 0.75) }
            return (.unknown, 0.5)
        }
        if ruCount > 0 && enCount == 0 { return (.ru, 1.0) }
        if enCount > 0 && ruCount == 0 { return (.en, 1.0) }

        let ruRatio = Double(ruCount) / Double(total)
        if ruRatio >= 0.65 { return (.ru, ruRatio) }
        if ruRatio <= 0.35 { return (.en, 1.0 - ruRatio) }
        return (.mixed, max(ruRatio, 1.0 - ruRatio))
    }

    /// Находит защищённые фрагменты, в которых типографические замены запрещены:
    /// fenced/inline code, URL, email, пути к файлам, CLI-флаги, выражения вида user-name/a=b.
    static func findProtectedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        guard !text.isEmpty else { return ranges }

        // 1. Markdown fenced code blocks ```...``` и inline code `...`
        ranges.append(contentsOf: matchRegex(#"```[\s\S]*?```"#, in: text))
        ranges.append(contentsOf: matchRegex(#"`[^`\n]+`"#, in: text))

        // 2. URL (http/https/ftp/www) и email
        ranges.append(contentsOf: matchRegex(#"(?i)\b(?:https?|ftp)://[^\s<>()\[\]\"']+"#, in: text))
        ranges.append(contentsOf: matchRegex(#"(?i)\bwww\.[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?:/[^\s<>()\[\]\"']*)?"#, in: text))
        ranges.append(contentsOf: matchRegex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text))

        // 3. Пути к файлам (/Users/..., ~/..., ./..., C:\...)
        ranges.append(contentsOf: matchRegex(#"(?:^|(?<=[\s(\[\"']))(?:~|\.{1,2})?/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*"#, in: text))
        ranges.append(contentsOf: matchRegex(#"[A-Za-z]:\\[^\s\"'<>]+"#, in: text))

        // 4. CLI-флаги (--amend, --help, -la), но НЕ «слово -- слово» (после -- стоит непробельный символ)
        ranges.append(contentsOf: matchRegex(#"(?:^|(?<=[\s(\[]))--[A-Za-z0-9][A-Za-z0-9_-]*"#, in: text))

        // 5. Технические идентификаторы с дефисом или подчёркиванием в коде (user-name, foo_bar) и ISO-даты (2026-11-14)
        ranges.append(contentsOf: matchRegex(#"\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b"#, in: text))
        ranges.append(contentsOf: matchRegex(#"\b\d{4}-\d{2}-\d{2}\b"#, in: text))

        return mergeRanges(ranges)
    }

    private static func detectCodeOrCommand(text: String, protectedRanges: [Range<String.Index>]) -> Bool {
        let lower = text.lowercased()
        let cliVerbs = ["git ", "npm ", "pnpm ", "yarn ", "cargo ", "pip ", "pip3 ", "brew ", "docker ",
                        "kubectl ", "swift ", "swiftc ", "xcodebuild ", "curl ", "ssh ", "chmod ", "sudo "]
        for prefix in cliVerbs {
            if lower.hasPrefix(prefix) || lower.contains("\n" + prefix) {
                return true
            }
        }
        // Наличие явных CLI-флагов (--foo) или присваивания / операторов кода
        if text.contains(" --") {
            let cliFlagRegex = #"(?:^|\s)--[A-Za-z0-9]"#
            if !matchRegex(cliFlagRegex, in: text).isEmpty {
                return true
            }
        }
        if text.contains("===") || text.contains("!==") || text.contains(" => ") || text.contains("-> ") {
            return true
        }
        if text.contains("function ") || text.contains("import ") && text.contains(";") {
            return true
        }
        _ = protectedRanges
        return false
    }

    private static func matchRegex(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, options: [], range: nsRange).compactMap { Range($0.range, in: text) }
    }

    private static func mergeRanges(_ input: [Range<String.Index>]) -> [Range<String.Index>] {
        guard input.count > 1 else { return input }
        let sorted = input.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = [sorted[0]]
        for r in sorted.dropFirst() {
            if r.lowerBound <= merged[merged.count - 1].upperBound {
                let last = merged.removeLast()
                merged.append(last.lowerBound..<max(last.upperBound, r.upperBound))
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
