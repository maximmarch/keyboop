import Foundation

/// Неизменяемый снимок эффективных правил ввода для горячего пути Engine (FR-4).
struct ResolvedInputContext: Equatable {
    let bundleID: String
    let browser: SiteBrowser?
    let siteStatus: WebsiteContextStatus
    let matchedRule: SiteRule?
    let appHardExcluded: Bool
    let effectiveAutoSwitch: Bool
    let effectiveTypoFix: Bool
    let effectiveSnippets: Bool
    let effectiveExceptionMode: String   // "" | "soft" | "off"
    let effectivePreferredLayout: String // "" | "ru" | "en"
    let sitePreferredLayoutExplicit: Bool
    let siteContextKey: String

    static let empty = ResolvedInputContext(
        bundleID: "",
        browser: nil,
        siteStatus: .notBrowser,
        matchedRule: nil,
        appHardExcluded: false,
        effectiveAutoSwitch: false,
        effectiveTypoFix: false,
        effectiveSnippets: false,
        effectiveExceptionMode: "",
        effectivePreferredLayout: "",
        sitePreferredLayoutExplicit: false,
        siteContextKey: ""
    )

    var activeDomain: String? {
        if case .active(let domain, _, _, _) = siteStatus { return domain }
        return nil
    }
}

/// Чистый резолвер приоритетов KB-001 (FR-4):
/// 1. Secure Input / защищённые поля
/// 2. Глобальное отключение / пауза
/// 3. Явное полное исключение macOS-приложения
/// 4. Правило активного сайта (если параметр не `.inherit`)
/// 5. Правило macOS-приложения (`ExceptionStore`)
/// 6. Глобальные настройки
enum RuleResolver {
    struct Input: Equatable {
        let bundleID: String
        let secureInput: Bool
        let pauseActive: Bool
        let globalAutoEnabled: Bool
        let globalTypoFixEnabled: Bool
        let globalSnippetsEnabled: Bool
        let developerMode: Bool
        let appIsDev: Bool
        let appMode: String          // "" | "soft" | "off"
        let appLayout: String        // "" | "ru" | "en"
        let siteSnapshot: WebsiteContextSnapshot
        let matchedRule: SiteRule?
    }

    static func resolve(_ input: Input) -> ResolvedInputContext {
        let browser = SiteBrowser.from(bundleID: input.bundleID)
        let siteKey = "\(input.bundleID)|\(input.siteSnapshot.contextIdentityKey)"

        // 1. Системная защита Secure Input — абсолютный запрет.
        if input.secureInput {
            return ResolvedInputContext(
                bundleID: input.bundleID,
                browser: browser,
                siteStatus: input.siteSnapshot.status,
                matchedRule: input.matchedRule,
                appHardExcluded: true,
                effectiveAutoSwitch: false,
                effectiveTypoFix: false,
                effectiveSnippets: false,
                effectiveExceptionMode: "off",
                effectivePreferredLayout: "",
                sitePreferredLayoutExplicit: false,
                siteContextKey: siteKey
            )
        }

        // 2. Пауза автоматических действий глушит всё.
        if input.pauseActive {
            return ResolvedInputContext(
                bundleID: input.bundleID,
                browser: browser,
                siteStatus: input.siteSnapshot.status,
                matchedRule: input.matchedRule,
                appHardExcluded: false,
                effectiveAutoSwitch: false,
                effectiveTypoFix: false,
                effectiveSnippets: false,
                effectiveExceptionMode: input.appMode,
                effectivePreferredLayout: "",
                sitePreferredLayoutExplicit: false,
                siteContextKey: siteKey
            )
        }

        // 3. Полное исключение macOS-приложения (правило сайта НЕ может его обойти).
        let hardExcluded = (input.appMode == "off") || (input.developerMode && input.appIsDev)
        if hardExcluded {
            return ResolvedInputContext(
                bundleID: input.bundleID,
                browser: browser,
                siteStatus: input.siteSnapshot.status,
                matchedRule: input.matchedRule,
                appHardExcluded: true,
                effectiveAutoSwitch: false,
                effectiveTypoFix: false,
                effectiveSnippets: false,
                effectiveExceptionMode: "off",
                effectivePreferredLayout: input.appLayout,
                sitePreferredLayoutExplicit: false,
                siteContextKey: siteKey
            )
        }

        // Определяем базовые значения уровня приложения + глобальных настроек (уровни 5–6).
        let baseMode = input.appMode
        let baseAuto = input.globalAutoEnabled
        let baseTypo = input.globalTypoFixEnabled
        let baseSnippets = input.globalSnippetsEnabled
        let baseLayout = input.appLayout

        // Без активного правила сайта (или не в браузере / домен неизвестен) — уровни 5–6.
        guard browser != nil,
              case .active = input.siteSnapshot.status,
              let rule = input.matchedRule else {
            return ResolvedInputContext(
                bundleID: input.bundleID,
                browser: browser,
                siteStatus: input.siteSnapshot.status,
                matchedRule: nil,
                appHardExcluded: false,
                effectiveAutoSwitch: baseAuto,
                effectiveTypoFix: baseTypo,
                effectiveSnippets: baseSnippets,
                effectiveExceptionMode: baseMode,
                effectivePreferredLayout: baseLayout,
                sitePreferredLayoutExplicit: false,
                siteContextKey: siteKey
            )
        }

        // 4. Применяем правило сайта с наследованием `.inherit`.
        let effectiveMode: String
        switch rule.exceptionMode {
        case .inherit: effectiveMode = baseMode
        case .soft: effectiveMode = "soft"
        case .off: effectiveMode = "off"
        }

        // Режим «выкл.» на уровне сайта выключает автоконверсию и по умолчанию гасит вмешательство.
        let siteTurnsOff = (effectiveMode == "off")

        // Глобальное отключение Keyboop (`!globalAutoEnabled`) имеет приоритет (уровень 2 над уровнем 4).
        let effectiveAuto: Bool
        if !input.globalAutoEnabled || siteTurnsOff {
            effectiveAuto = false
        } else {
            switch rule.autoSwitch {
            case .inherit: effectiveAuto = true
            case .enable: effectiveAuto = true
            case .disable: effectiveAuto = false
            }
        }

        let effectiveTypo: Bool
        if siteTurnsOff {
            effectiveTypo = false
        } else {
            switch rule.typoFix {
            case .inherit: effectiveTypo = baseTypo
            case .enable: effectiveTypo = true
            case .disable: effectiveTypo = false
            }
        }

        let effectiveSnip: Bool
        if siteTurnsOff {
            effectiveSnip = false
        } else {
            switch rule.snippets {
            case .inherit: effectiveSnip = baseSnippets
            case .enable: effectiveSnip = true
            case .disable: effectiveSnip = false
            }
        }

        let effectiveLayout: String
        let siteLayoutExplicit: Bool
        switch rule.preferredLayout {
        case .inherit:
            effectiveLayout = baseLayout
            siteLayoutExplicit = false
        case .ru:
            effectiveLayout = "ru"
            siteLayoutExplicit = true
        case .en:
            effectiveLayout = "en"
            siteLayoutExplicit = true
        }

        return ResolvedInputContext(
            bundleID: input.bundleID,
            browser: browser,
            siteStatus: input.siteSnapshot.status,
            matchedRule: rule,
            appHardExcluded: false,
            effectiveAutoSwitch: effectiveAuto,
            effectiveTypoFix: effectiveTypo,
            effectiveSnippets: effectiveSnip,
            effectiveExceptionMode: effectiveMode,
            effectivePreferredLayout: effectiveLayout,
            sitePreferredLayoutExplicit: siteLayoutExplicit,
            siteContextKey: siteKey
        )
    }

    /// Удобный хелпер для живого состояния приложения.
    static func resolveCurrent(bundleID: String) -> ResolvedInputContext {
        let settings = AppSettings.shared
        let snap = WebsiteContextProvider.shared.snapshot(forBundleID: bundleID)
        let matched: SiteRule?
        if let domain = snap.activeDomain, let browser = snap.activeBrowser {
            matched = SiteRuleStore.shared.matchingRule(forNormalizedDomain: domain, browser: browser)
        } else {
            matched = nil
        }
        return resolve(Input(
            bundleID: bundleID,
            secureInput: AppHealth.secureInputOn,
            pauseActive: Pause.active,
            globalAutoEnabled: settings.autoEnabled,
            globalTypoFixEnabled: settings.typoFix,
            globalSnippetsEnabled: !settings.snippetsDisabled,
            developerMode: settings.developerMode,
            appIsDev: Engine.isDevBundleID(bundleID),
            appMode: Engine.appMode(for: bundleID),
            appLayout: ExceptionStore.shared.appLayout(bundleID),
            siteSnapshot: snap,
            matchedRule: matched
        ))
    }
}
