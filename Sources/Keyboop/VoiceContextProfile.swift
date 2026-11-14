import Foundation

/// Категория приложения для контекстной адаптации диктовки и AI-постобработки.
enum VoiceContextCategory: String, Codable, CaseIterable {
    case general
    case chat
    case emailDocs
    case codeTerminal
    case custom

    var titleKey: String {
        switch self {
        case .general: return "voice.ctx.cat.general"
        case .chat: return "voice.ctx.cat.chat"
        case .emailDocs: return "voice.ctx.cat.emailDocs"
        case .codeTerminal: return "voice.ctx.cat.codeTerminal"
        case .custom: return "voice.ctx.cat.custom"
        }
    }

    /// Нужно ли принудительно снимать одиночную точку в конце (nil = глобальная настройка).
    var defaultNoFinalPeriod: Bool? {
        switch self {
        case .chat: return true
        case .codeTerminal: return true
        case .emailDocs: return false
        case .general, .custom: return nil
        }
    }

    /// Нужно ли заменять длинное тире на дефис (nil = глобальная настройка).
    var defaultNoEmDash: Bool? {
        switch self {
        case .chat: return true
        case .codeTerminal: return true
        case .emailDocs: return false
        case .general, .custom: return nil
        }
    }

    /// Подсказка для LLM-постобработки, добавляемая к базовому промпту (если не задан свой).
    func promptAddendum(appName: String) -> String {
        let appNote = appName.isEmpty ? "" : " Целевое приложение: \(appName)."
        switch self {
        case .general:
            return ""
        case .chat:
            return "Контекст: мессенджер / чат.\(appNote) Сохраняй живой разговорный стиль, делай фразы компактными, избегай лишнего канцелярита и не ставь финальную точку в конце короткого сообщения (вопрос «?» и восклицание «!» сохраняй)."
        case .emailDocs:
            return "Контекст: письмо или документ.\(appNote) Оформи текст аккуратно, с чёткой пунктуацией, корректной капитализацией, связными абзацами и списками там, где они явно диктуются."
        case .codeTerminal:
            return "Контекст: редактор кода или терминал.\(appNote) Сохраняй латинские идентификаторы, имена файлов, CLI-флаги, camelCase/snake_case и технические термины без перевода на русский. Не используй длинное тире."
        case .custom:
            return ""
        }
    }
}

/// Правило контекстной диктовки для конкретного приложения (по bundleIdentifier).
struct VoiceContextRule: Codable, Equatable, Identifiable {
    var id: String
    var appName: String
    var category: VoiceContextCategory
    var noFinalPeriodOverride: Bool?
    var noCapitalOverride: Bool?
    var customPrompt: String
    var enabled: Bool

    init(
        id: String,
        appName: String,
        category: VoiceContextCategory,
        noFinalPeriodOverride: Bool? = nil,
        noCapitalOverride: Bool? = nil,
        customPrompt: String = "",
        enabled: Bool = true
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.appName = appName
        self.category = category
        self.noFinalPeriodOverride = noFinalPeriodOverride
        self.noCapitalOverride = noCapitalOverride
        self.customPrompt = customPrompt
        self.enabled = enabled
    }
}

/// Итоговое решение для одной сессии диктовки после учёта активного приложения.
struct VoiceContextDecision: Equatable {
    let bundleID: String
    let appName: String
    let category: VoiceContextCategory
    let isProfileApplied: Bool
    let noFinalPeriod: Bool
    let noCapital: Bool
    let noEmDash: Bool
    let postProcessPromptOverride: String?
}

/// Хранилище и резолвер контекстных профилей диктовки по активному приложению.
final class VoiceContextProfileStore {
    static let shared = VoiceContextProfileStore()

    private static let storageKey = "voiceContextRulesData"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var customRulesCache: [String: VoiceContextRule]

    static let builtInDefaults: [VoiceContextRule] = [
        // Мессенджеры и чаты
        VoiceContextRule(id: "ru.keepcoder.telegram", appName: "Telegram", category: .chat),
        VoiceContextRule(id: "org.telegram.desktop", appName: "Telegram Desktop", category: .chat),
        VoiceContextRule(id: "com.tinyspeck.slackmacgap", appName: "Slack", category: .chat),
        VoiceContextRule(id: "com.hnc.discord", appName: "Discord", category: .chat),
        VoiceContextRule(id: "net.whatsapp.whatsapp", appName: "WhatsApp", category: .chat),
        VoiceContextRule(id: "com.apple.mobilesms", appName: "Messages", category: .chat),
        VoiceContextRule(id: "org.whispersystems.signal-desktop", appName: "Signal", category: .chat),
        VoiceContextRule(id: "com.viber.osx", appName: "Viber", category: .chat),
        VoiceContextRule(id: "com.vk.vkmessenger", appName: "VK Messenger", category: .chat),
        VoiceContextRule(id: "us.zoom.xos", appName: "Zoom", category: .chat),
        VoiceContextRule(id: "com.microsoft.teams2", appName: "Microsoft Teams", category: .chat),

        // Почта и документы
        VoiceContextRule(id: "com.apple.mail", appName: "Mail", category: .emailDocs),
        VoiceContextRule(id: "com.readdle.smartemail-mac", appName: "Spark", category: .emailDocs),
        VoiceContextRule(id: "com.microsoft.outlook", appName: "Outlook", category: .emailDocs),
        VoiceContextRule(id: "notion.id", appName: "Notion", category: .emailDocs),
        VoiceContextRule(id: "md.obsidian", appName: "Obsidian", category: .emailDocs),
        VoiceContextRule(id: "com.apple.notes", appName: "Notes", category: .emailDocs),
        VoiceContextRule(id: "com.apple.iwork.pages", appName: "Pages", category: .emailDocs),
        VoiceContextRule(id: "com.apple.textedit", appName: "TextEdit", category: .emailDocs),
        VoiceContextRule(id: "com.microsoft.word", appName: "Microsoft Word", category: .emailDocs),
        VoiceContextRule(id: "com.craftdocs.craft", appName: "Craft", category: .emailDocs),
        VoiceContextRule(id: "com.bear-writer.bear", appName: "Bear", category: .emailDocs),

        // Редакторы кода и терминалы
        VoiceContextRule(id: "com.apple.dt.xcode", appName: "Xcode", category: .codeTerminal),
        VoiceContextRule(id: "com.microsoft.vscode", appName: "VS Code", category: .codeTerminal),
        VoiceContextRule(id: "com.microsoft.vscodeinsiders", appName: "VS Code Insiders", category: .codeTerminal),
        VoiceContextRule(id: "sh.cursor.cursor", appName: "Cursor", category: .codeTerminal),
        VoiceContextRule(id: "com.todesktop.230313mzl4w4u92", appName: "Cursor", category: .codeTerminal),
        VoiceContextRule(id: "com.exafunction.windsurf", appName: "Windsurf", category: .codeTerminal),
        VoiceContextRule(id: "dev.zed.zed", appName: "Zed", category: .codeTerminal),
        VoiceContextRule(id: "com.sublimetext.4", appName: "Sublime Text", category: .codeTerminal),
        VoiceContextRule(id: "com.apple.terminal", appName: "Terminal", category: .codeTerminal),
        VoiceContextRule(id: "com.googlecode.iterm2", appName: "iTerm2", category: .codeTerminal),
        VoiceContextRule(id: "com.mitchellh.ghostty", appName: "Ghostty", category: .codeTerminal),
        VoiceContextRule(id: "dev.warp.warp-stable", appName: "Warp", category: .codeTerminal),
        VoiceContextRule(id: "net.kovidgoyal.kitty", appName: "kitty", category: .codeTerminal),
        VoiceContextRule(id: "com.github.wez.wezterm", appName: "WezTerm", category: .codeTerminal),
    ]

    private static let builtInMap: [String: VoiceContextRule] = {
        Dictionary(uniqueKeysWithValues: builtInDefaults.map { ($0.id, $0) })
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.customRulesCache = Self.loadRules(from: defaults)
    }

    private static func loadRules(from defaults: UserDefaults) -> [String: VoiceContextRule] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([VoiceContextRule].self, from: data) else {
            return [:]
        }
        var out: [String: VoiceContextRule] = [:]
        for item in decoded where !item.id.isEmpty {
            out[item.id] = item
        }
        return out
    }

    private func persistLocked() {
        let sorted = customRulesCache.values.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        if sorted.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func allEffectiveRules() -> [VoiceContextRule] {
        lock.withLock {
            var merged = Self.builtInMap
            for (k, v) in customRulesCache {
                merged[k] = v
            }
            return merged.values.sorted {
                if $0.category.rawValue != $1.category.rawValue {
                    return $0.category.rawValue < $1.category.rawValue
                }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
        }
    }

    func customRulesCount() -> Int {
        lock.withLock { customRulesCache.count }
    }

    func isBuiltIn(bundleID: String) -> Bool {
        Self.builtInMap[bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil
    }

    func isCustomized(bundleID: String) -> Bool {
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lock.withLock { customRulesCache[key] != nil }
    }

    func upsertRule(_ rule: VoiceContextRule) {
        guard !rule.id.isEmpty else { return }
        lock.withLock {
            customRulesCache[rule.id] = rule
            persistLocked()
        }
    }

    func removeCustomRule(bundleID: String) {
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        lock.withLock {
            customRulesCache.removeValue(forKey: key)
            persistLocked()
        }
    }

    func resetCustomRules() {
        lock.withLock {
            customRulesCache.removeAll()
            persistLocked()
        }
    }

    /// Определяет правило для конкретного bundleIdentifier с учётом пользовательских переопределений и семейств.
    private func matchRule(for rawBundleID: String) -> VoiceContextRule? {
        let bid = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bid.isEmpty else { return nil }

        let custom: VoiceContextRule? = lock.withLock { customRulesCache[bid] }
        if let custom {
            return custom
        }
        if let exactBuiltIn = Self.builtInMap[bid] {
            return exactBuiltIn
        }
        if bid.hasPrefix("com.jetbrains.") {
            return VoiceContextRule(id: bid, appName: "JetBrains IDE", category: .codeTerminal)
        }
        if bid.hasPrefix("dev.warp.") {
            return VoiceContextRule(id: bid, appName: "Warp", category: .codeTerminal)
        }
        return nil
    }

    func resolve(
        bundleID: String?,
        enabled: Bool,
        globalNoFinalPeriod: Bool,
        globalNoCapital: Bool,
        globalNoEmDash: Bool,
        globalPrompt: String
    ) -> VoiceContextDecision {
        let cleanBID = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, let rule = matchRule(for: cleanBID), rule.enabled, rule.category != .general else {
            return VoiceContextDecision(
                bundleID: cleanBID,
                appName: "",
                category: .general,
                isProfileApplied: false,
                noFinalPeriod: globalNoFinalPeriod,
                noCapital: globalNoCapital,
                noEmDash: globalNoEmDash,
                postProcessPromptOverride: nil
            )
        }

        let effPeriod = rule.noFinalPeriodOverride ?? rule.category.defaultNoFinalPeriod ?? globalNoFinalPeriod
        let effCapital = rule.noCapitalOverride ?? globalNoCapital
        let effEmDash = rule.category.defaultNoEmDash ?? globalNoEmDash

        let trimmedCustom = rule.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptOverride: String?
        if !trimmedCustom.isEmpty {
            promptOverride = trimmedCustom
        } else {
            let addendum = rule.category.promptAddendum(appName: rule.appName).trimmingCharacters(in: .whitespacesAndNewlines)
            if addendum.isEmpty {
                promptOverride = nil
            } else {
                let base = globalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                promptOverride = base.isEmpty ? addendum : "\(base)\n\n\(addendum)"
            }
        }

        return VoiceContextDecision(
            bundleID: cleanBID,
            appName: rule.appName,
            category: rule.category,
            isProfileApplied: true,
            noFinalPeriod: effPeriod,
            noCapital: effCapital,
            noEmDash: effEmDash,
            postProcessPromptOverride: promptOverride
        )
    }
}
