import Foundation

extension Notification.Name {
    static let keyboopTypographySettingsChanged = Notification.Name("KeyboopTypographySettingsChanged")
}

/// Хранилище настроек умной типографики KB-021 (FR-01, FR-08).
final class TypographySettingsStore {
    static let shared = TypographySettingsStore()

    private let d: UserDefaults
    private let lock = NSLock()

    private enum Keys {
        static let enabled = "typography.enabled"
        static let mode = "typography.mode"
        static let language = "typography.language"
        static let customRules = "typography.customRules"
        static let excludedApps = "typography.excludedApps"
        static let showSelectionPreview = "typography.showSelectionPreview"
        static let formatKeyCode = "typography.formatKeyCode"
        static let formatModifiers = "typography.formatModifiers"
        static let formatKeyLabel = "typography.formatKeyLabel"
        static let undoKeyCode = "typography.undoKeyCode"
        static let undoModifiers = "typography.undoModifiers"
        static let undoKeyLabel = "typography.undoKeyLabel"
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
    }

    /// Глобальное включение (FR-01). По умолчанию выключено.
    var enabled: Bool {
        get { d.bool(forKey: Keys.enabled) }
        set {
            let wasEnabled = enabled
            d.set(newValue, forKey: Keys.enabled)
            if newValue && !wasEnabled && d.string(forKey: Keys.mode) == nil {
                // При первом включении стартуем с минимального (самого безопасного) режима.
                d.set(TypographyMode.minimal.rawValue, forKey: Keys.mode)
            }
            NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
        }
    }

    var mode: TypographyMode {
        get {
            guard let raw = d.string(forKey: Keys.mode),
                  let m = TypographyMode(rawValue: raw) else { return .minimal }
            return m
        }
        set {
            let prev = mode
            if newValue == .custom && prev != .custom && d.dictionary(forKey: Keys.customRules) == nil {
                var seed: [String: Bool] = [:]
                for id in TypographyRuleID.allCases {
                    seed[id.rawValue] = Self.presetEnabled(id, mode: prev)
                }
                d.set(seed, forKey: Keys.customRules)
            }
            d.set(newValue.rawValue, forKey: Keys.mode)
            NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
        }
    }

    var language: TypographyLanguageMode {
        get {
            guard let raw = d.string(forKey: Keys.language),
                  let l = TypographyLanguageMode(rawValue: raw) else { return .auto }
            return l
        }
        set {
            d.set(newValue.rawValue, forKey: Keys.language)
            NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
        }
    }

    var showSelectionPreview: Bool {
        get { d.object(forKey: Keys.showSelectionPreview) == nil ? true : d.bool(forKey: Keys.showSelectionPreview) }
        set {
            d.set(newValue, forKey: Keys.showSelectionPreview)
            NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
        }
    }

    // MARK: - Горячие клавиши (FR-07, FR-09)

    var formatHotkeyEnabled: Bool { formatKeyCode >= 0 }

    var formatKeyCode: Int {
        get { d.object(forKey: Keys.formatKeyCode) == nil ? -1 : d.integer(forKey: Keys.formatKeyCode) }
        set { d.set(newValue, forKey: Keys.formatKeyCode) }
    }

    var formatModifiers: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: Keys.formatModifiers))) }
        set { d.set(Int64(bitPattern: newValue), forKey: Keys.formatModifiers) }
    }

    var formatKeyLabel: String {
        get { d.string(forKey: Keys.formatKeyLabel) ?? "" }
        set { d.set(newValue, forKey: Keys.formatKeyLabel) }
    }

    var undoHotkeyEnabled: Bool { undoKeyCode >= 0 }

    var undoKeyCode: Int {
        get { d.object(forKey: Keys.undoKeyCode) == nil ? -1 : d.integer(forKey: Keys.undoKeyCode) }
        set { d.set(newValue, forKey: Keys.undoKeyCode) }
    }

    var undoModifiers: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: Keys.undoModifiers))) }
        set { d.set(Int64(bitPattern: newValue), forKey: Keys.undoModifiers) }
    }

    var undoKeyLabel: String {
        get { d.string(forKey: Keys.undoKeyLabel) ?? "" }
        set { d.set(newValue, forKey: Keys.undoKeyLabel) }
    }

    // MARK: - Правила

    static func presetEnabled(_ id: TypographyRuleID, mode: TypographyMode) -> Bool {
        switch mode {
        case .minimal:
            switch id {
            case .ruQuotes, .emDash, .nbspUnits:
                return true
            default:
                return false
            }
        case .standard:
            switch id {
            case .ruQuotes, .emDash, .nbspUnits, .ellipsis, .copyright, .registered, .trademark, .collapseSpacesSelection:
                return true
            case .nestedQuotes, .enQuotes, .enApostrophe, .enDashRanges, .narrowNbsp, .trimSpaceBeforePunctSelection:
                return false
            }
        case .custom:
            return presetEnabled(id, mode: .minimal)
        }
    }

    func isRuleEnabled(_ id: TypographyRuleID) -> Bool {
        let currentMode = mode
        guard currentMode == .custom else {
            return Self.presetEnabled(id, mode: currentMode)
        }
        let map = (d.dictionary(forKey: Keys.customRules) as? [String: Bool]) ?? [:]
        if let val = map[id.rawValue] {
            return val
        }
        return Self.presetEnabled(id, mode: .minimal)
    }

    func setRuleEnabled(_ id: TypographyRuleID, _ isOn: Bool) {
        var map = (d.dictionary(forKey: Keys.customRules) as? [String: Bool]) ?? [:]
        if mode != .custom {
            let baseMode = mode
            for r in TypographyRuleID.allCases where map[r.rawValue] == nil {
                map[r.rawValue] = Self.presetEnabled(r, mode: baseMode)
            }
            d.set(TypographyMode.custom.rawValue, forKey: Keys.mode)
        }
        map[id.rawValue] = isOn
        d.set(map, forKey: Keys.customRules)
        NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
    }

    func effectiveRules() -> [TypographyRule] {
        let lang = language
        return TypographyRuleID.allCases
            .map { id in
                TypographyRule(id: id, enabled: isRuleEnabled(id), language: lang)
            }
            .sorted { $0.priority < $1.priority }
    }

    // MARK: - Исключения по приложениям (FR-08)

    var excludedBundleIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set((d.array(forKey: Keys.excludedApps) as? [String]) ?? [])
    }

    func isAppExcluded(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func setAppExcluded(_ bundleID: String, excluded: Bool) {
        guard !bundleID.isEmpty else { return }
        lock.lock()
        var current = Set((d.array(forKey: Keys.excludedApps) as? [String]) ?? [])
        if excluded {
            current.insert(bundleID)
        } else {
            current.remove(bundleID)
        }
        d.set(Array(current).sorted(), forKey: Keys.excludedApps)
        lock.unlock()
        NotificationCenter.default.post(name: .keyboopTypographySettingsChanged, object: self)
    }
}
