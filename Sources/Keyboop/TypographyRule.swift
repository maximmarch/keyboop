import Foundation

/// Режим работы умной типографики (FR-01).
enum TypographyMode: String, Codable, CaseIterable, Equatable {
    case minimal
    case standard
    case custom
}

/// Языковой профиль типографики (FR-06).
enum TypographyLanguageMode: String, Codable, CaseIterable, Equatable {
    case auto
    case ru
    case en
}

/// Определённый язык локального фрагмента текста.
enum TypographyDetectedLanguage: String, Equatable {
    case ru
    case en
    case mixed
    case unknown
}

/// Категория типографического правила (§5).
enum TypographyRuleCategory: String, Codable, Equatable {
    case quotes
    case dashes
    case spaces
    case symbols
}

/// Требования к контексту, при которых правило разрешено применять (§5).
enum TypographyContextRequirement: String, Codable, Equatable {
    case proseOnly
    case pairBoundary
    case notCodeOrTerminal
    case notURLOrEmail
    case notMarkdown
    case selectionOnly
    case numericBoundary
}

/// Идентификаторы типографических правил KB-021.
enum TypographyRuleID: String, Codable, CaseIterable, Equatable {
    case ruQuotes
    case nestedQuotes
    case enQuotes
    case enApostrophe
    case emDash
    case enDashRanges
    case nbspUnits
    case narrowNbsp
    case ellipsis
    case copyright
    case registered
    case trademark
    case collapseSpacesSelection
    case trimSpaceBeforePunctSelection

    var category: TypographyRuleCategory {
        switch self {
        case .ruQuotes, .nestedQuotes, .enQuotes, .enApostrophe:
            return .quotes
        case .emDash, .enDashRanges:
            return .dashes
        case .nbspUnits, .narrowNbsp, .collapseSpacesSelection, .trimSpaceBeforePunctSelection:
            return .spaces
        case .ellipsis, .copyright, .registered, .trademark:
            return .symbols
        }
    }

    var defaultPriority: Int {
        switch self {
        case .ellipsis:                      return 10
        case .copyright, .registered, .trademark: return 20
        case .emDash:                        return 30
        case .enDashRanges:                  return 35
        case .ruQuotes, .nestedQuotes, .enQuotes, .enApostrophe: return 40
        case .nbspUnits, .narrowNbsp:        return 50
        case .collapseSpacesSelection:       return 60
        case .trimSpaceBeforePunctSelection: return 70
        }
    }

    var defaultContextRequirements: [TypographyContextRequirement] {
        switch self {
        case .ruQuotes, .nestedQuotes, .enQuotes, .enApostrophe:
            return [.proseOnly, .pairBoundary, .notCodeOrTerminal, .notURLOrEmail, .notMarkdown]
        case .emDash:
            return [.proseOnly, .notCodeOrTerminal, .notURLOrEmail, .notMarkdown]
        case .enDashRanges:
            return [.numericBoundary, .notCodeOrTerminal, .notURLOrEmail, .notMarkdown]
        case .nbspUnits, .narrowNbsp:
            return [.notCodeOrTerminal, .notURLOrEmail, .notMarkdown]
        case .ellipsis, .copyright, .registered, .trademark:
            return [.proseOnly, .notCodeOrTerminal, .notURLOrEmail, .notMarkdown]
        case .collapseSpacesSelection, .trimSpaceBeforePunctSelection:
            return [.selectionOnly, .notCodeOrTerminal, .notURLOrEmail]
        }
    }
}

/// Модель отдельного типографического правила (§5).
struct TypographyRule: Codable, Identifiable, Equatable {
    var id: TypographyRuleID
    var enabled: Bool
    var language: TypographyLanguageMode
    var category: TypographyRuleCategory
    var priority: Int
    var contextRequirements: [TypographyContextRequirement]
    var minimumConfidence: Double

    init(
        id: TypographyRuleID,
        enabled: Bool,
        language: TypographyLanguageMode = .auto,
        category: TypographyRuleCategory? = nil,
        priority: Int? = nil,
        contextRequirements: [TypographyContextRequirement]? = nil,
        minimumConfidence: Double = 0.8
    ) {
        self.id = id
        self.enabled = enabled
        self.language = language
        self.category = category ?? id.category
        self.priority = priority ?? id.defaultPriority
        self.contextRequirements = contextRequirements ?? id.defaultContextRequirements
        self.minimumConfidence = minimumConfidence
    }
}
