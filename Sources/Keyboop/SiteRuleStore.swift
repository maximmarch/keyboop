import Foundation

/// Поддерживаемые браузеры для правил уровня сайтов (KB-001).
enum SiteBrowser: String, Codable, CaseIterable, Equatable {
    case any = ""
    case chrome = "chrome"

    static let chromeBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev"
    ]

    static func from(bundleID: String) -> SiteBrowser? {
        if chromeBundleIDs.contains(bundleID) { return .chrome }
        return nil
    }

    static func from(id: String) -> SiteBrowser? {
        switch id.lowercased() {
        case "", "any": return .any
        case "chrome", "google-chrome": return .chrome
        default: return nil
        }
    }

    var l10nKey: String {
        switch self {
        case .any: return "sites.browser.any"
        case .chrome: return "sites.browser.chrome"
        }
    }
}

/// Трёхпозиционный переключатель для правила сайта (FR-1).
enum SiteRuleToggle: String, Codable, CaseIterable, Equatable {
    case inherit
    case enable
    case disable
}

/// Предпочтительная раскладка при переходе на сайт (FR-1).
enum SitePreferredLayout: String, Codable, CaseIterable, Equatable {
    case inherit
    case ru
    case en
}

/// Переопределение режима исключения на уровне сайта (FR-1).
enum SiteExceptionMode: String, Codable, CaseIterable, Equatable {
    case inherit
    case soft
    case off
}

/// Одно правило ввода для домена / поддоменов.
struct SiteRule: Codable, Equatable, Identifiable {
    var id: UUID
    var domainPattern: String
    var displayName: String?
    var enabled: Bool
    var browser: SiteBrowser
    var autoSwitch: SiteRuleToggle
    var typoFix: SiteRuleToggle
    var snippets: SiteRuleToggle
    var typography: SiteRuleToggle
    var preferredLayout: SitePreferredLayout
    var exceptionMode: SiteExceptionMode
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, domainPattern, displayName, enabled, browser
        case autoSwitch, typoFix, snippets, typography
        case preferredLayout, exceptionMode, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domainPattern = try c.decode(String.self, forKey: .domainPattern)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        browser = try c.decode(SiteBrowser.self, forKey: .browser)
        autoSwitch = try c.decode(SiteRuleToggle.self, forKey: .autoSwitch)
        typoFix = try c.decode(SiteRuleToggle.self, forKey: .typoFix)
        snippets = try c.decode(SiteRuleToggle.self, forKey: .snippets)
        typography = try c.decodeIfPresent(SiteRuleToggle.self, forKey: .typography) ?? .inherit
        preferredLayout = try c.decode(SitePreferredLayout.self, forKey: .preferredLayout)
        exceptionMode = try c.decode(SiteExceptionMode.self, forKey: .exceptionMode)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    init(
        id: UUID = UUID(),
        domainPattern: String,
        displayName: String? = nil,
        enabled: Bool = true,
        browser: SiteBrowser = .any,
        autoSwitch: SiteRuleToggle = .inherit,
        typoFix: SiteRuleToggle = .inherit,
        snippets: SiteRuleToggle = .inherit,
        typography: SiteRuleToggle = .inherit,
        preferredLayout: SitePreferredLayout = .inherit,
        exceptionMode: SiteExceptionMode = .inherit,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.domainPattern = domainPattern
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false) ? trimmedName : nil
        self.enabled = enabled
        self.browser = browser
        self.autoSwitch = autoSwitch
        self.typoFix = typoFix
        self.snippets = snippets
        self.typography = typography
        self.preferredLayout = preferredLayout
        self.exceptionMode = exceptionMode
        self.updatedAt = updatedAt
    }

    var isWildcard: Bool { domainPattern.hasPrefix("*.") }

    var wildcardBase: String? {
        guard isWildcard else { return nil }
        return String(domainPattern.dropFirst(2))
    }

    var effectiveTitle: String {
        if let n = displayName, !n.isEmpty { return n }
        return domainPattern
    }

    /// Количество меток в базовом домене (для ранжирования специфичности).
    var baseLabelCount: Int {
        let base = wildcardBase ?? domainPattern
        return base.split(separator: ".").count
    }

    /// Проверяет, подходит ли правило к уже нормализованному домену и браузеру (FR-2).
    /// - `github.com` → только точный домен.
    /// - `*.github.com` → только поддомены (`gist.github.com`), но НЕ сам `github.com`.
    func matches(normalizedDomain domain: String, browser activeBrowser: SiteBrowser) -> Bool {
        guard enabled else { return false }
        if browser != .any && browser != activeBrowser { return false }
        if let suffix = wildcardBase {
            return domain.count > suffix.count + 1 && domain.hasSuffix("." + suffix)
        }
        return domain == domainPattern
    }
}

enum DomainValidationError: Error, Equatable {
    case empty
    case regexNotAllowed
    case invalidCharacters
    case invalidLabel
    case singleLabelNotAllowed
    case overlyBroadWildcard
}

/// Сериализуемый контейнер со схемой данных.
struct SiteRuleSchema: Codable, Equatable {
    static let currentVersion = 1

    var schemaVersion: Int
    var trackIncognito: Bool
    var rules: [SiteRule]

    init(
        schemaVersion: Int = SiteRuleSchema.currentVersion,
        trackIncognito: Bool = false,
        rules: [SiteRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.trackIncognito = trackIncognito
        self.rules = rules
    }
}

extension Notification.Name {
    static let keyboopSiteRulesChanged = Notification.Name("keyboopSiteRulesChanged")
}

/// Хранилище правил ввода по доменам с нормализацией, валидацией (включая IDNA) и поиском победителя.
final class SiteRuleStore {
    static let shared = SiteRuleStore()

    private let defaults: UserDefaults
    private let storageKey = "siteRulesSchemaV1"
    private let lock = NSLock()
    private var schema: SiteRuleSchema

    var onChange: (() -> Void)?

    /// Двухуровневые публичные суффиксы, для которых запрещён шаблон `*.suffix` (слишком широкий).
    private static let disallowedWildcardTwoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp",
        "com.ru", "net.ru", "org.ru", "edu.ru", "gov.ru", "msk.ru", "spb.ru",
        "com.ua", "org.ua", "net.ua", "kiev.ua",
        "com.br", "com.cn", "com.hk", "com.tw", "com.tr", "com.mx",
        "co.in", "co.kr", "co.nz", "co.za", "co.il",
        "com.pl", "net.pl", "org.pl", "com.de"
    ]

    private static let regexMetaMarkers: Set<Character> = [
        "^", "$", "[", "]", "(", ")", "{", "}", "+", "?", "\\", "|"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(SiteRuleSchema.self, from: data) {
            self.schema = decoded
        } else {
            self.schema = SiteRuleSchema()
        }
    }

    var allRules: [SiteRule] {
        lock.withLock {
            schema.rules.sorted { lhs, rhs in
                let a = lhs.domainPattern.replacingOccurrences(of: "*.", with: "")
                let b = rhs.domainPattern.replacingOccurrences(of: "*.", with: "")
                if a != b { return a < b }
                return lhs.domainPattern < rhs.domainPattern
            }
        }
    }

    var trackIncognito: Bool {
        get { lock.withLock { schema.trackIncognito } }
        set {
            lock.withLock {
                guard schema.trackIncognito != newValue else { return }
                schema.trackIncognito = newValue
                saveLocked()
            }
            notifyChanged()
        }
    }

    func rule(id: UUID) -> SiteRule? {
        lock.withLock { schema.rules.first { $0.id == id } }
    }

    func upsert(_ rule: SiteRule) throws {
        let normalized = try Self.normalizeDomainPattern(rule.domainPattern)
        var clean = rule
        clean.domainPattern = normalized
        clean.updatedAt = Date()
        if let name = clean.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            clean.displayName = name
        } else {
            clean.displayName = nil
        }

        lock.withLock {
            if let idx = schema.rules.firstIndex(where: { $0.id == clean.id }) {
                schema.rules[idx] = clean
            } else {
                schema.rules.append(clean)
            }
            saveLocked()
        }
        notifyChanged()
    }

    func remove(id: UUID) {
        let removed = lock.withLock { () -> Bool in
            let before = schema.rules.count
            schema.rules.removeAll { $0.id == id }
            guard schema.rules.count != before else { return false }
            saveLocked()
            return true
        }
        if removed { notifyChanged() }
    }

    func setEnabled(id: UUID, enabled: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard let idx = schema.rules.firstIndex(where: { $0.id == id }),
                  schema.rules[idx].enabled != enabled else { return false }
            schema.rules[idx].enabled = enabled
            schema.rules[idx].updatedAt = Date()
            saveLocked()
            return true
        }
        if changed { notifyChanged() }
    }

    /// Поиск победившего правила для домена и браузера (§FR-2 & §6):
    /// 1. Точный домен побеждает wildcard `*.domain`.
    /// 2. Среди нескольких wildcard побеждает более длинный/специфичный (`*.gist.github.com` > `*.github.com`).
    /// 3. При равной специфичности явный браузер побеждает «Любой».
    /// 4. Далее — более свежее обновление.
    func matchingRule(forNormalizedDomain domain: String, browser: SiteBrowser) -> SiteRule? {
        let cleanDomain = domain.lowercased()
        return lock.withLock {
            let candidates = schema.rules.filter { $0.matches(normalizedDomain: cleanDomain, browser: browser) }
            return candidates.max { a, b in
                compareSpecificity(a, b)
            }
        }
    }

    /// Проверяет, есть ли хотя бы одно правило с тем же шаблоном и браузером (кроме `excludingID`).
    func hasDuplicate(domainPattern: String, browser: SiteBrowser, excludingID: UUID?) -> Bool {
        guard let norm = try? Self.normalizeDomainPattern(domainPattern) else { return false }
        return lock.withLock {
            schema.rules.contains {
                $0.id != excludingID && $0.domainPattern == norm && $0.browser == browser
            }
        }
    }

    private func compareSpecificity(_ lhs: SiteRule, _ rhs: SiteRule) -> Bool {
        // Возвращает true, если rhs специфичнее lhs (для max).
        if lhs.isWildcard != rhs.isWildcard {
            return lhs.isWildcard && !rhs.isWildcard
        }
        if lhs.baseLabelCount != rhs.baseLabelCount {
            return lhs.baseLabelCount < rhs.baseLabelCount
        }
        let lhsBaseLen = (lhs.wildcardBase ?? lhs.domainPattern).count
        let rhsBaseLen = (rhs.wildcardBase ?? rhs.domainPattern).count
        if lhsBaseLen != rhsBaseLen {
            return lhsBaseLen < rhsBaseLen
        }
        let lhsExplicitBrowser = lhs.browser != .any
        let rhsExplicitBrowser = rhs.browser != .any
        if lhsExplicitBrowser != rhsExplicitBrowser {
            return !lhsExplicitBrowser && rhsExplicitBrowser
        }
        return lhs.updatedAt < rhs.updatedAt
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(schema) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
            NotificationCenter.default.post(name: .keyboopSiteRulesChanged, object: nil)
        }
    }

    // MARK: - Нормализация и валидация доменов (FR-2)

    /// Нормализует пользовательский ввод шаблона домена (`github.com`, `*.github.com`, IDNA `тест.рф`),
    /// отрезает случайно вставленный `https://.../path` и отклоняет слишком широкие/regex шаблоны.
    static func normalizeDomainPattern(_ rawInput: String) throws -> String {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { throw DomainValidationError.empty }

        // Отсекаем явные regex-конструкции (если это не обычный URL с query `?a=1`), затем вырезаем host.
        if text.contains("://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
                throw DomainValidationError.invalidCharacters
            }
            text = host.lowercased()
        } else {
            // Срезаем путь/порт если ввели `github.com/org` или `github.com:443`.
            if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
            if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        }

        if text.contains(where: { regexMetaMarkers.contains($0) }) {
            throw DomainValidationError.regexNotAllowed
        }

        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { throw DomainValidationError.empty }

        let isWildcard = text.hasPrefix("*.")
        let hostPart = isWildcard ? String(text.dropFirst(2)) : text

        // Одиночные `*` или `*` не в начале `*.` запрещены.
        if hostPart.contains("*") {
            throw DomainValidationError.regexNotAllowed
        }

        guard let asciiHost = convertIDNAToASCII(hostPart) else {
            throw DomainValidationError.invalidCharacters
        }
        guard isValidASCIIDomain(asciiHost) else {
            let labels = asciiHost.split(separator: ".", omittingEmptySubsequences: false)
            if labels.count < 2 {
                if isWildcard { throw DomainValidationError.overlyBroadWildcard }
                throw DomainValidationError.singleLabelNotAllowed
            }
            throw DomainValidationError.invalidLabel
        }

        let labels = asciiHost.split(separator: ".").map(String.init)
        guard labels.count >= 2 else {
            throw isWildcard ? DomainValidationError.overlyBroadWildcard : DomainValidationError.singleLabelNotAllowed
        }

        if isWildcard {
            // Запрещаем `*.com`, `*.ru` и известные 2-уровневые публичные суффиксы вроде `*.co.uk`.
            if labels.count < 2 {
                throw DomainValidationError.overlyBroadWildcard
            }
            if labels.count == 2 && disallowedWildcardTwoLevelSuffixes.contains(asciiHost) {
                throw DomainValidationError.overlyBroadWildcard
            }
            return "*." + asciiHost
        }

        return asciiHost
    }

    /// Нормализует входящий от браузера домен активной вкладки.
    /// Возвращает `nil` для пустых, локальных или некорректных имён.
    static func normalizeObservedDomain(_ rawHost: String?) -> String? {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        if host.contains("://") {
            guard let parsed = URL(string: host)?.host?.lowercased(), !parsed.isEmpty else { return nil }
            host = parsed
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains("*") else { return nil }
        guard let ascii = convertIDNAToASCII(host), isValidASCIIDomain(ascii) else { return nil }
        return ascii
    }

    private static func convertIDNAToASCII(_ host: String) -> String? {
        guard !host.isEmpty else { return nil }
        if host.allSatisfy(\.isASCII) {
            return host.lowercased()
        }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        guard let encoded = comps.url?.host?.lowercased(), !encoded.isEmpty else { return nil }
        return encoded
    }

    private static func isValidASCIIDomain(_ host: String) -> Bool {
        guard host.count >= 3, host.count <= 253 else { return false }
        guard host.allSatisfy(\.isASCII) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for (idx, labelSub) in labels.enumerated() {
            let label = String(labelSub)
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            let okChars = label.allSatisfy { ch in
                ("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "-"
            }
            guard okChars else { return false }
            // TLD (последняя метка) должна содержать хотя бы одну букву (отсекаем IPv4 и числа).
            if idx == labels.count - 1 {
                let hasAlpha = label.contains { ("a"..."z").contains($0) } || label.hasPrefix("xn--")
                guard hasAlpha else { return false }
            }
        }
        return true
    }
}
