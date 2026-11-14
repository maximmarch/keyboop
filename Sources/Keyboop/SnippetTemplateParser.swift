import Foundation

/// Тип встроенной автоматической переменной шаблона (MVP KB-004).
enum SnippetBuiltinKind: String, Codable, Equatable {
    case date
    case time
    case datetime
    case clipboard
}

/// Описание встроенной переменной в разобранном шаблоне.
struct SnippetBuiltinVariable: Equatable {
    let kind: SnippetBuiltinKind
    let format: String?
    let range: Range<String.Index>
}

/// Элемент разобранного шаблона сниппета.
enum SnippetTemplateToken: Equatable {
    case text(String)
    case builtin(SnippetBuiltinVariable)
    case field(key: String, range: Range<String.Index>)
}

/// Ошибка разбора или валидации шаблона (для подсветки в редакторе до сохранения).
enum SnippetDiagnosticKind: String, Equatable {
    case unclosedOpenBrace
    case unmatchedCloseBrace
    case emptyPlaceholder
    case nestedOpenBrace
    case invalidVariableName
    case emptyFormat
    case builtinTakesNoArgument
    case unknownBuiltinFunction
}

struct SnippetTemplateDiagnostic: Equatable {
    let kind: SnippetDiagnosticKind
    let detail: String
    let range: Range<String.Index>
}

struct ParsedSnippetTemplate: Equatable {
    let source: String
    let tokens: [SnippetTemplateToken]
    let diagnostics: [SnippetTemplateDiagnostic]
    /// Ключи пользовательских переменных в порядке первого появления (без дублей).
    let fieldKeysInOrder: [String]
    /// Есть ли в шаблоне {{clipboard}}.
    let usesClipboard: Bool

    var isValid: Bool { diagnostics.isEmpty }
    var hasUserFields: Bool { !fieldKeysInOrder.isEmpty }
}

/// Парсер и валидатор динамических шаблонов KB-004 без какого-либо исполнения кода (eval запрещён).
/// Поддерживает:
/// - `{{date}}`, `{{date:FORMAT}}`, `{{time}}`, `{{time:FORMAT}}`, `{{datetime}}`, `{{datetime:FORMAT}}`
/// - `{{clipboard}}` (выполняется только при явном разрешении на шаблоне)
/// - Пользовательские переменные `{{name}}` (валидный идентификатор)
/// - Экранирование литералов `\{{` → `{{`, `\}}` → `}}`, `\\{{` → `\{{...`
enum SnippetTemplateParser {

    static func parse(_ source: String) -> ParsedSnippetTemplate {
        var tokens: [SnippetTemplateToken] = []
        var diagnostics: [SnippetTemplateDiagnostic] = []
        var fieldKeysInOrder: [String] = []
        var seenFields = Set<String>()
        var usesClipboard = false

        var textBuffer = ""
        func flushText() {
            guard !textBuffer.isEmpty else { return }
            tokens.append(.text(textBuffer))
            textBuffer.removeAll(keepingCapacity: true)
        }

        var idx = source.startIndex
        while idx < source.endIndex {
            // Экранирование: \\{{, \\}}, \{{, \}}
            if source[idx] == "\\" {
                let next = source.index(after: idx)
                if next < source.endIndex {
                    if source[next] == "\\" {
                        let afterTwo = source.index(after: next)
                        if afterTwo < source.endIndex,
                           (source[afterTwo...].hasPrefix("{{") || source[afterTwo...].hasPrefix("}}")) {
                            textBuffer.append("\\")
                            idx = afterTwo
                            continue
                        }
                    } else if source[next...].hasPrefix("{{") {
                        textBuffer.append("{{")
                        idx = source.index(next, offsetBy: 2)
                        continue
                    } else if source[next...].hasPrefix("}}") {
                        textBuffer.append("}}")
                        idx = source.index(next, offsetBy: 2)
                        continue
                    }
                }
                textBuffer.append("\\")
                idx = next
                continue
            }

            // Одиночный `}}` вне плейсхолдера считаем ошибкой синтаксиса, чтобы пользователь
            // сразу видел незакрытую/лишнюю скобку до сохранения.
            if source[idx...].hasPrefix("}}") {
                flushText()
                let end = source.index(idx, offsetBy: 2)
                diagnostics.append(SnippetTemplateDiagnostic(
                    kind: .unmatchedCloseBrace,
                    detail: "}}",
                    range: idx..<end
                ))
                textBuffer.append("}}")
                idx = end
                continue
            }

            // Начало плейсхолдера `{{`
            if source[idx...].hasPrefix("{{") {
                flushText()
                let contentStart = source.index(idx, offsetBy: 2)
                var scan = contentStart
                var foundClose: String.Index?
                var nestedAt: String.Index?

                while scan < source.endIndex {
                    if source[scan...].hasPrefix("{{") {
                        nestedAt = scan
                        break
                    }
                    if source[scan...].hasPrefix("}}") {
                        foundClose = scan
                        break
                    }
                    scan = source.index(after: scan)
                }

                if let nested = nestedAt {
                    let nestedEnd = source.index(nested, offsetBy: 2)
                    diagnostics.append(SnippetTemplateDiagnostic(
                        kind: .nestedOpenBrace,
                        detail: String(source[idx..<nestedEnd]),
                        range: idx..<nestedEnd
                    ))
                    textBuffer.append(String(source[idx..<nested]))
                    idx = nested
                    continue
                }

                guard let closeStart = foundClose else {
                    diagnostics.append(SnippetTemplateDiagnostic(
                        kind: .unclosedOpenBrace,
                        detail: String(source[idx..<source.endIndex]),
                        range: idx..<source.endIndex
                    ))
                    textBuffer.append(String(source[idx..<source.endIndex]))
                    break
                }

                let tokenEnd = source.index(closeStart, offsetBy: 2)
                let fullRange = idx..<tokenEnd
                let rawInner = String(source[contentStart..<closeStart])

                if let parsed = classifyPlaceholder(rawInner, fullRange: fullRange) {
                    switch parsed {
                    case .success(let token):
                        tokens.append(token)
                        switch token {
                        case .builtin(let b) where b.kind == .clipboard:
                            usesClipboard = true
                        case .field(let key, _):
                            if seenFields.insert(key).inserted {
                                fieldKeysInOrder.append(key)
                            }
                        default:
                            break
                        }
                    case .failure(let diag):
                        diagnostics.append(diag)
                    }
                }

                idx = tokenEnd
                continue
            }

            textBuffer.append(source[idx])
            idx = source.index(after: idx)
        }

        flushText()

        return ParsedSnippetTemplate(
            source: source,
            tokens: tokens,
            diagnostics: diagnostics,
            fieldKeysInOrder: fieldKeysInOrder,
            usesClipboard: usesClipboard
        )
    }

    private enum PlaceholderParseOutcome {
        case success(SnippetTemplateToken)
        case failure(SnippetTemplateDiagnostic)
    }

    private static func classifyPlaceholder(
        _ rawInner: String,
        fullRange: Range<String.Index>
    ) -> PlaceholderParseOutcome? {
        if rawInner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(SnippetTemplateDiagnostic(
                kind: .emptyPlaceholder,
                detail: "{{}}",
                range: fullRange
            ))
        }

        if let colon = rawInner.firstIndex(of: ":") {
            let head = String(rawInner[..<colon])
            let arg = String(rawInner[rawInner.index(after: colon)...])

            if head.isEmpty || !isValidIdentifier(head) {
                return .failure(SnippetTemplateDiagnostic(
                    kind: .unknownBuiltinFunction,
                    detail: rawInner,
                    range: fullRange
                ))
            }

            switch head {
            case SnippetBuiltinKind.date.rawValue:
                guard !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !arg.contains("\n"), !arg.contains("\r") else {
                    return .failure(SnippetTemplateDiagnostic(
                        kind: .emptyFormat,
                        detail: rawInner,
                        range: fullRange
                    ))
                }
                return .success(.builtin(SnippetBuiltinVariable(kind: .date, format: arg, range: fullRange)))
            case SnippetBuiltinKind.time.rawValue:
                guard !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !arg.contains("\n"), !arg.contains("\r") else {
                    return .failure(SnippetTemplateDiagnostic(
                        kind: .emptyFormat,
                        detail: rawInner,
                        range: fullRange
                    ))
                }
                return .success(.builtin(SnippetBuiltinVariable(kind: .time, format: arg, range: fullRange)))
            case SnippetBuiltinKind.datetime.rawValue:
                guard !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !arg.contains("\n"), !arg.contains("\r") else {
                    return .failure(SnippetTemplateDiagnostic(
                        kind: .emptyFormat,
                        detail: rawInner,
                        range: fullRange
                    ))
                }
                return .success(.builtin(SnippetBuiltinVariable(kind: .datetime, format: arg, range: fullRange)))
            case SnippetBuiltinKind.clipboard.rawValue:
                return .failure(SnippetTemplateDiagnostic(
                    kind: .builtinTakesNoArgument,
                    detail: rawInner,
                    range: fullRange
                ))
            default:
                return .failure(SnippetTemplateDiagnostic(
                    kind: .unknownBuiltinFunction,
                    detail: head,
                    range: fullRange
                ))
            }
        }

        guard isValidIdentifier(rawInner) else {
            return .failure(SnippetTemplateDiagnostic(
                kind: .invalidVariableName,
                detail: rawInner,
                range: fullRange
            ))
        }

        switch rawInner {
        case SnippetBuiltinKind.date.rawValue:
            return .success(.builtin(SnippetBuiltinVariable(kind: .date, format: nil, range: fullRange)))
        case SnippetBuiltinKind.time.rawValue:
            return .success(.builtin(SnippetBuiltinVariable(kind: .time, format: nil, range: fullRange)))
        case SnippetBuiltinKind.datetime.rawValue:
            return .success(.builtin(SnippetBuiltinVariable(kind: .datetime, format: nil, range: fullRange)))
        case SnippetBuiltinKind.clipboard.rawValue:
            return .success(.builtin(SnippetBuiltinVariable(kind: .clipboard, format: nil, range: fullRange)))
        default:
            return .success(.field(key: rawInner, range: fullRange))
        }
    }

    /// Допустимый идентификатор переменной: начинается с буквы или `_`, далее буквы, цифры или `_`.
    /// Запрещает пробелы, дефисы, скобки, выражения, $ и пустые строки.
    static func isValidIdentifier(_ candidate: String) -> Bool {
        guard let first = candidate.unicodeScalars.first else { return false }
        guard isIdentifierStart(first) else { return false }
        return candidate.unicodeScalars.dropFirst().allSatisfy(isIdentifierContinue)
    }

    private static func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || CharacterSet.letters.contains(scalar)
    }

    private static func isIdentifierContinue(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}
