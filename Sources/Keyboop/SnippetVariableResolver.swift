import Foundation

struct SnippetRenderResult: Equatable {
    let text: String
    let missingRequiredFieldKeys: [String]
    let clipboardBlocked: Bool
    let isValidTemplate: Bool

    var canInsert: Bool {
        isValidTemplate && missingRequiredFieldKeys.isEmpty && !text.isEmpty
    }
}

/// Безопасный резолвер переменных шаблона KB-004 без какого-либо eval.
/// Буфер обмена читается ТОЛЬКО если `snippet.allowClipboard == true` и передан `clipboardReader`.
enum SnippetVariableResolver {

    static func initialFieldValues(for snippet: SnippetV2, parsed: ParsedSnippetTemplate? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for field in snippet.resolvedFormFields(using: parsed) {
            if !field.defaultValue.isEmpty {
                result[field.key] = field.defaultValue
            } else if field.type == .choice, field.required, let first = field.options.first {
                result[field.key] = first
            } else {
                result[field.key] = ""
            }
        }
        return result
    }

    static func resolve(
        snippet: SnippetV2,
        fieldValues: [String: String] = [:],
        fallbackToDefaults: Bool = true,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .current,
        clipboardReader: (() -> String?)? = nil
    ) -> SnippetRenderResult {
        if snippet.kind == .plain {
            let clean = sanitize(snippet.body)
            return SnippetRenderResult(
                text: clean,
                missingRequiredFieldKeys: [],
                clipboardBlocked: false,
                isValidTemplate: true
            )
        }

        let parsed = SnippetTemplateParser.parse(snippet.body)
        guard parsed.isValid else {
            return SnippetRenderResult(
                text: "",
                missingRequiredFieldKeys: [],
                clipboardBlocked: false,
                isValidTemplate: false
            )
        }

        let fields = snippet.resolvedFormFields(using: parsed)
        let defaultsByKey = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })

        var effectiveValues: [String: String] = [:]
        var missingRequired: [String] = []

        for field in fields {
            let raw: String
            if let provided = fieldValues[field.key] {
                raw = provided
            } else if fallbackToDefaults {
                raw = field.defaultValue
            } else {
                raw = ""
            }
            effectiveValues[field.key] = raw
            if field.required && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missingRequired.append(field.key)
            }
        }

        var clipboardCache: String?
        var clipboardFetched = false
        var clipboardBlocked = false

        func readClipboardIfAllowed() -> String {
            guard snippet.allowClipboard else {
                clipboardBlocked = true
                return ""
            }
            if !clipboardFetched {
                clipboardFetched = true
                clipboardCache = clipboardReader?() ?? ""
            }
            return clipboardCache ?? ""
        }

        var out = ""
        for token in parsed.tokens {
            switch token {
            case .text(let literal):
                out += literal
            case .field(let key, _):
                if let val = effectiveValues[key] {
                    out += val
                } else if fallbackToDefaults, let def = defaultsByKey[key] {
                    out += def
                }
            case .builtin(let builtin):
                switch builtin.kind {
                case .date:
                    out += formatDate(now, format: builtin.format, defaultDateStyle: .short, defaultTimeStyle: .none, locale: locale, timeZone: timeZone)
                case .time:
                    out += formatDate(now, format: builtin.format, defaultDateStyle: .none, defaultTimeStyle: .short, locale: locale, timeZone: timeZone)
                case .datetime:
                    out += formatDate(now, format: builtin.format, defaultDateStyle: .short, defaultTimeStyle: .short, locale: locale, timeZone: timeZone)
                case .clipboard:
                    out += readClipboardIfAllowed()
                }
            }
        }

        return SnippetRenderResult(
            text: sanitize(out),
            missingRequiredFieldKeys: missingRequired,
            clipboardBlocked: clipboardBlocked,
            isValidTemplate: true
        )
    }

    static func formatDate(
        _ date: Date,
        format: String?,
        defaultDateStyle: DateFormatter.Style,
        defaultTimeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if let format, !format.isEmpty {
            formatter.dateFormat = format
        } else {
            formatter.dateStyle = defaultDateStyle
            formatter.timeStyle = defaultTimeStyle
        }
        return formatter.string(from: date)
    }

    /// Нормализует переводы строк (\r\n / \r → \n) и убирает опасные управляющие символы,
    /// сохраняя \n и \t, аналогично статическим сниппетам.
    static func sanitize(_ s: String) -> String {
        let normalizedNewlines = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalizedNewlines.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.value >= 0x20
        }))
    }
}
