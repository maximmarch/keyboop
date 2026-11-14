import ApplicationServices
import Carbon
import Cocoa
import CryptoKit
import Foundation

/// Языковое направление, предсказанное по контексту поля или чата.
enum FocusLayoutLanguage: String, Codable, Equatable {
    case cyrillic = "ru"
    case latin = "en"

    var isCyrillic: Bool { self == .cyrillic }
}

/// Откуда получено предсказание (только метаданные без пользовательского текста — для лога).
enum FocusPredictSource: String {
    case memory = "память чата"
    case fieldText = "текст в поле"
    case paneText = "сообщения чата"
}

/// Неизменяемый снимок фокуса, снятый в фоновой очереди Accessibility.
struct AXFocusSnapshot {
    let bundleID: String
    let isEditableTextInput: Bool
    let isSecureField: Bool
    let contextIdentity: String
    let hasSpecificIdentity: Bool
    let beforeCaret: String?
    let fieldText: String?
    let paneText: String?
    let paneTailHash: String
}

/// Чистый (без AX и без состояния) классификатор языка текста вокруг курсора и в активной панели.
enum FocusTextClassifier {

    struct Stats {
        var cyrTokens = 0
        var cyrChars = 0
        var enStrongTokens = 0
        var enWeakTokens = 0
        var enChars = 0
    }

    /// Служебные слова интерфейса чатов и почты (время, статусы, кнопки) — не считаем их сигналом языка чата.
    private static let uiChromeWords: Set<String> = [
        "am", "pm", "today", "yesterday", "edited", "reply", "replies", "thread",
        "forwarded", "pinned", "unread", "online", "typing", "delivered", "read",
        "sent", "message", "messages", "search", "cancel", "save", "send", "mute",
        "unmute", "join", "leave", "call", "video", "audio", "files", "file",
        "members", "channel", "channels", "direct", "general", "new", "open",
        "close", "more", "copy", "edit", "delete", "react", "reactions", "ok",
        "сегодня", "вчера", "изменено", "ответить", "переслано", "закреплено",
        "непрочитанные", "доставлено", "прочитано", "печатает", "поиск", "отмена",
        "сохранить", "отправить", "сообщение", "сообщения", "звонок", "файлы", "файл"
    ]

    /// Технические термины и сервисы, которые часто встречаются внутри русской переписки:
    /// поодиночке они НЕ должны уводить раскладку в английский.
    private static let techNeutralWords: Set<String> = [
        "pr", "mr", "ci", "cd", "api", "ui", "ux", "id", "vs", "url", "uri", "pdf",
        "png", "jpg", "jpeg", "svg", "gif", "json", "yaml", "yml", "xml", "html",
        "css", "sql", "git", "github", "gitlab", "docker", "jira", "figma", "slack",
        "zoom", "meet", "google", "mac", "macos", "ios", "iphone", "ipad", "xcode",
        "swift", "python", "node", "npm", "http", "https", "ssh", "vpn", "dns", "ai",
        "ml", "llm", "gpt", "bug", "fix", "prod", "dev", "stage", "staging", "test"
    ]

    static func classify(
        beforeCaret: String?,
        fieldText: String?,
        paneText: String?,
        enWords: Set<String>
    ) -> (language: FocusLayoutLanguage, source: FocusPredictSource)? {
        // 1. Сначала смотрим текст ПРЯМО ПЕРЕД курсором (пользователь дописывает или правит фразу).
        if let before = beforeCaret, !before.isEmpty {
            let tail = String(before.suffix(220))
            if let lang = classifyFieldSample(tail, enWords: enWords) {
                return (lang, .fieldText)
            }
        }
        // 2. Затем весь видимый срез поля (например, курсор стоит в самом начале черновика).
        if let field = fieldText, !field.isEmpty {
            if let lang = classifyFieldSample(field, enWords: enWords) {
                return (lang, .fieldText)
            }
        }
        // 3. Поле пустое или неинформативное → определяем язык по последним сообщениям / тексту рядом.
        if let pane = paneText, !pane.isEmpty {
            if let lang = classifyPaneSample(pane, enWords: enWords) {
                return (lang, .paneText)
            }
        }
        return nil
    }

    static func classifyFieldSample(_ raw: String, enWords: Set<String>) -> FocusLayoutLanguage? {
        let s = analyze(raw, enWords: enWords)
        // Кириллица в черновике: достаточно одного нормального слова (≥2 букв), если прямо перед
        // курсором пользователь уже не перешёл на связный английский текст.
        if s.cyrTokens >= 1, s.cyrChars >= 2 {
            let nearTail = analyze(String(raw.suffix(45)), enWords: enWords)
            if nearTail.cyrChars == 0,
               (nearTail.enStrongTokens >= 2 || (s.enStrongTokens >= 3 && s.enChars > s.cyrChars * 2)) {
                return .latin
            }
            if s.enStrongTokens >= 4, s.enChars > s.cyrChars * 3, nearTail.cyrTokens == 0 {
                return .latin
            }
            return .cyrillic
        }
        // Латиница в черновике: 0 кириллицы + хотя бы 1 настоящее английское слово ≥3 букв или 2 коротких.
        if s.cyrChars == 0 {
            if s.enStrongTokens >= 2 { return .latin }
            if s.enStrongTokens == 1, s.enChars >= 3 { return .latin }
            if s.enWeakTokens >= 2, s.enChars >= 6 { return .latin }
        }
        return nil
    }

    static func classifyPaneSample(_ raw: String, enWords: Set<String>) -> FocusLayoutLanguage? {
        // Свежие сообщения находятся в конце списка — сначала смотрим хвост (~220 символов), потом шире.
        let recent = String(raw.suffix(220))
        let r = analyze(recent, enWords: enWords)
        if r.cyrTokens >= 2, r.cyrChars >= 5, r.cyrTokens * 2 >= r.enStrongTokens {
            return .cyrillic
        }
        if r.cyrChars == 0, r.enStrongTokens >= 3, r.enChars >= 8 {
            return .latin
        }

        let wide = String(raw.suffix(800))
        let w = analyze(wide, enWords: enWords)
        if w.cyrTokens >= 2, w.cyrChars >= 5, w.cyrTokens * 2 >= w.enStrongTokens {
            return .cyrillic
        }
        if w.cyrChars == 0, w.enStrongTokens >= 3, w.enChars >= 8 {
            return .latin
        }
        if w.cyrTokens == 0, w.enStrongTokens >= 4, w.enChars >= 12 {
            return .latin
        }
        return nil
    }

    static func analyze(_ text: String, enWords: Set<String>) -> Stats {
        let cleaned = stripNoise(text)
        var stats = Stats()
        var current = ""
        var currentHasDigit = false

        func flushToken() {
            let hadDigit = currentHasDigit
            currentHasDigit = false
            guard !current.isEmpty else { return }
            let token = current.lowercased()
            current.removeAll(keepingCapacity: true)
            guard !hadDigit, token.count >= 2 else { return }
            if uiChromeWords.contains(token) { return }

            var hasCyr = false
            var hasLat = false
            for scalar in token.unicodeScalars {
                if (0x0400...0x04FF).contains(scalar.value) { hasCyr = true }
                else if (0x0061...0x007A).contains(scalar.value) { hasLat = true }
            }
            if hasCyr && !hasLat {
                stats.cyrTokens += 1
                stats.cyrChars += token.count
            } else if hasLat && !hasCyr {
                guard !techNeutralWords.contains(token) else { return }
                if enWords.contains(token) {
                    stats.enStrongTokens += 1
                    stats.enChars += token.count
                } else if token.count >= 3 {
                    stats.enWeakTokens += 1
                    stats.enChars += token.count
                }
            }
        }

        for scalar in cleaned.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if CharacterSet.decimalDigits.contains(scalar) {
                currentHasDigit = true
            } else {
                flushToken()
            }
        }
        flushToken()
        return stats
    }

    /// Вычищаем URL, e-mail, @упоминания, #хэштеги, пути и числа — чтобы ссылки/ники не ломали счётчики.
    static func stripNoise(_ s: String) -> String {
        let tokens = s.components(separatedBy: .whitespacesAndNewlines)
        var kept: [String] = []
        kept.reserveCapacity(tokens.count)
        for raw in tokens where !raw.isEmpty {
            let lower = raw.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("www.") || lower.hasPrefix("mailto:")
                || lower.hasPrefix("@") || lower.hasPrefix("#")
                || lower.hasPrefix("/") || lower.hasPrefix("~/")
            {
                continue
            }
            if lower.contains("@") && lower.contains(".") { continue }
            if lower.contains("://") { continue }
            kept.append(raw)
        }
        return kept.joined(separator: " ")
    }
}

/// Приватное хранилище выбора раскладки по контексту (чат / документ / вкладка).
/// Хранит ТОЛЬКО односторонний SHA-256 хэш контекста и выбранную сторону, без текстов и названий чатов.
final class ContextLayoutMemory {
    struct Entry: Codable, Equatable {
        let cyrillic: Bool
        let explicit: Bool
        var updatedAt: TimeInterval
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(defaults: UserDefaults = .standard,
         storageKey: String = "focusLayoutMemory",
         maxEntries: Int = 250) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxEntries = maxEntries
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = decoded
        }
    }

    static func contextHash(bundleID: String, identity: String) -> String {
        let payload = bundleID + "\u{0}" + identity
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func lookup(hash: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[hash]
    }

    func remember(hash: String, cyrillic: Bool, explicit: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        guard !hash.isEmpty else { return }
        lock.lock()
        entries[hash] = Entry(cyrillic: cyrillic, explicit: explicit, updatedAt: now)
        if entries.count > maxEntries {
            let sorted = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
            entries = Dictionary(uniqueKeysWithValues: sorted.prefix(maxEntries).map { ($0.key, $0.value) })
        }
        let snapshot = entries
        lock.unlock()

        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        defaults.removeObject(forKey: storageKey)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

/// Фоновый Accessibility-инспектор поля ввода и активной панели разговора.
/// Все методы предназначены ТОЛЬКО для фоновой очереди (`ru.keyboop.focuspredict`) с жёстким бюджетом времени.
enum AXFocusInspector {

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    private static let customEditableContainerRoles: Set<String> = [
        kAXGroupRole as String,
        "AXWebArea",
        "AXDocument",
        "AXGeneric"
    ]

    private static let skipPaneRoles: Set<String> = [
        "AXScrollBar",
        "AXSidebar",
        "AXOutline",
        "AXMenuBar",
        "AXMenu",
        "AXSplitGroup"
    ]

    private static let textLeafRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        "AXHeading",
        "AXParagraph"
    ]

    private static let genericPlaceholders: Set<String> = [
        "message", "write a message", "write a message...", "search", "type a message",
        "compose", "input", "text", "сообщение", "написать сообщение", "поиск", "введите текст"
    ]

    static func captureSnapshot() -> AXFocusSnapshot? {
        let deadline = CACurrentMediaTime() + 0.10
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let raw = focusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.05)

        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid > 0 else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        let bid = running?.bundleIdentifier ?? ""
        guard !bid.isEmpty else { return nil }

        let subrole = stringAttr(focused, kAXSubroleAttribute)
        let role = stringAttr(focused, kAXRoleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) || role == (kAXSecureTextFieldSubrole as String) {
            return AXFocusSnapshot(bundleID: bid, isEditableTextInput: false, isSecureField: true,
                                   contextIdentity: "", hasSpecificIdentity: false,
                                   beforeCaret: nil, fieldText: nil, paneText: nil, paneTailHash: "")
        }

        if boolAttr(focused, kAXEnabledAttribute) == false {
            return AXFocusSnapshot(bundleID: bid, isEditableTextInput: false, isSecureField: false,
                                   contextIdentity: "", hasSpecificIdentity: false,
                                   beforeCaret: nil, fieldText: nil, paneText: nil, paneTailHash: "")
        }

        let isEditable = checkEditable(focused, role: role)
        guard isEditable else {
            return AXFocusSnapshot(bundleID: bid, isEditableTextInput: false, isSecureField: false,
                                   contextIdentity: "", hasSpecificIdentity: false,
                                   beforeCaret: nil, fieldText: nil, paneText: nil, paneTailHash: "")
        }

        // Если включён глобальный Secure Input и поле не подтверждено как стандартный текстовый контрол,
        // оставляем безопасный отказ (как в SecureInputPolicy).
        if IsSecureEventInputEnabled(), !(role.map { editableRoles.contains($0) } ?? false) {
            return AXFocusSnapshot(bundleID: bid, isEditableTextInput: false, isSecureField: true,
                                   contextIdentity: "", hasSpecificIdentity: false,
                                   beforeCaret: nil, fieldText: nil, paneText: nil, paneTailHash: "")
        }

        let (beforeCaret, fieldText) = readFieldText(focused)
        let appName = (running?.localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let windowEl = elementAttr(focused, kAXWindowAttribute) ?? {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.05)
            return elementAttr(appEl, kAXFocusedWindowAttribute)
        }()
        let windowTitle = windowEl.flatMap { stringAttr($0, kAXTitleAttribute) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let docAttr = windowEl.flatMap { stringAttr($0, kAXDocumentAttribute) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let fieldDesc = nonGenericLabel(
            stringAttr(focused, kAXDescriptionAttribute) ?? stringAttr(focused, kAXTitleAttribute),
            appName: appName
        )

        var budget = 60
        let (chatHeader, paneLines) = collectPaneContext(from: focused, appName: appName, deadline: deadline, budget: &budget)
        let paneText = paneLines.isEmpty ? nil : paneLines.joined(separator: "\n")
        let paneTailHash: String = {
            let tail = paneLines.suffix(4).joined(separator: "\n")
            guard !tail.isEmpty else { return "" }
            return ContextLayoutMemory.contextHash(bundleID: bid, identity: tail)
        }()

        var parts: [String] = []
        if !docAttr.isEmpty { parts.append("doc:" + docAttr) }
        if let cleanTitle = nonGenericLabel(windowTitle, appName: appName) {
            parts.append("win:" + cleanTitle)
        }
        if let header = chatHeader, !header.isEmpty {
            parts.append("hdr:" + header)
        }
        if let desc = fieldDesc, !desc.isEmpty {
            parts.append("fld:" + desc)
        }

        let hasSpecificIdentity = !parts.isEmpty
        let contextIdentity = hasSpecificIdentity ? parts.joined(separator: "|") : (appName.isEmpty ? bid : appName)

        return AXFocusSnapshot(
            bundleID: bid,
            isEditableTextInput: true,
            isSecureField: false,
            contextIdentity: contextIdentity,
            hasSpecificIdentity: hasSpecificIdentity,
            beforeCaret: beforeCaret,
            fieldText: fieldText,
            paneText: paneText,
            paneTailHash: paneTailHash
        )
    }

    private static func checkEditable(_ el: AXUIElement, role: String?) -> Bool {
        if let role, editableRoles.contains(role) { return true }
        if let role, customEditableContainerRoles.contains(role) {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
            if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
            if let editable = boolAttr(el, "AXEditable"), editable { return true }
        }
        return false
    }

    private static func readFieldText(_ el: AXUIElement) -> (beforeCaret: String?, full: String?) {
        var rangeRef: CFTypeRef?
        var range = CFRange(location: 0, length: 0)
        var hasRange = false
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID(),
           AXValueGetValue(unsafeDowncast(rv as AnyObject, to: AXValue.self), .cfRange, &range),
           range.location >= 0 {
            hasRange = true
        }

        if hasRange {
            let loc = range.location
            var before: String?
            if loc > 0 {
                let start = max(0, loc - 350)
                if let s = stringForRange(el, location: start, length: loc - start), !s.isEmpty {
                    before = s
                }
            }
            let total = intAttr(el, kAXNumberOfCharactersAttribute) ?? (loc + 200)
            let afterLen = max(0, min(200, total - loc))
            let after = afterLen > 0 ? stringForRange(el, location: loc, length: afterLen) : nil
            if before != nil || after != nil {
                let combined = (before ?? "") + (after ?? "")
                return (before, combined.isEmpty ? nil : combined)
            }
        }

        // Фолбэк для контролов без kAXStringForRangeParameterizedAttribute (часть Electron/web-полей).
        if let val = stringAttr(el, kAXValueAttribute), !val.isEmpty {
            let clipped = String(val.prefix(600))
            if hasRange {
                let idx = val.index(val.startIndex, offsetBy: min(range.location, val.count))
                let before = String(val[..<idx].suffix(350))
                return (before.isEmpty ? nil : before, clipped)
            }
            return (nil, clipped)
        }
        return (nil, nil)
    }

    private static func collectPaneContext(
        from focused: AXUIElement,
        appName: String,
        deadline: CFTimeInterval,
        budget: inout Int
    ) -> (chatHeader: String?, lines: [String]) {
        var cur = focused
        var lines: [String] = []
        var totalChars = 0
        var chatHeader: String?

        for _ in 0..<6 {
            guard CACurrentMediaTime() < deadline, budget > 0 else { break }
            guard let parent = elementAttr(cur, kAXParentAttribute) else { break }
            budget -= 1
            let pRole = stringAttr(parent, kAXRoleAttribute) ?? ""
            if pRole == (kAXApplicationRole as String) { break }

            // Не перепрыгиваем через границу AXSplitGroup (соседний потомок там — боковой список чатов).
            if pRole == "AXSplitGroup" { break }

            if let kids = childrenAttr(parent), !kids.isEmpty {
                // Ищем индекс текущей ветки, чтобы читать элементы ВЫШЕ поля ввода (а не подвал страницы).
                let curIdx = kids.firstIndex { CFEqual($0, cur) } ?? kids.count
                // 1) Заголовок чата/панели наверху этого же контейнера (toolbar / heading / верхняя группа).
                if chatHeader == nil {
                    for sibling in kids.prefix(3) {
                        guard CACurrentMediaTime() < deadline, budget > 0 else { break }
                        if CFEqual(sibling, cur) { continue }
                        let sRole = stringAttr(sibling, kAXRoleAttribute) ?? ""
                        if sRole == "AXToolbar" || sRole == "AXHeading" || sRole == (kAXStaticTextRole as String) || sRole == (kAXGroupRole as String) {
                            if let lbl = firstHeaderText(in: sibling, appName: appName, deadline: deadline, budget: &budget) {
                                chatHeader = lbl
                                break
                            }
                        }
                    }
                }
                // 2) Сообщения / текст перед полем ввода (идём снизу вверх от поля — к самым свежим).
                if lines.count < 10 && totalChars < 900 {
                    var collectedRev: [String] = []
                    for i in stride(from: curIdx - 1, through: 0, by: -1) {
                        guard CACurrentMediaTime() < deadline, budget > 0, lines.count + collectedRev.count < 12, totalChars < 900 else { break }
                        let sibling = kids[i]
                        let sRole = stringAttr(sibling, kAXRoleAttribute) ?? ""
                        if skipPaneRoles.contains(sRole) { continue }
                        if stringAttr(sibling, kAXSubroleAttribute) == "AXSidebar" { continue }
                        collectTrailingTexts(from: sibling, depth: 0, into: &collectedRev, totalChars: &totalChars, deadline: deadline, budget: &budget)
                    }
                    if !collectedRev.isEmpty {
                        lines.insert(contentsOf: collectedRev.reversed(), at: 0)
                    }
                }
            }

            if pRole == (kAXWindowRole as String) { break }
            cur = parent
        }
        return (chatHeader, lines)
    }

    private static func firstHeaderText(
        in el: AXUIElement,
        appName: String,
        deadline: CFTimeInterval,
        budget: inout Int
    ) -> String? {
        guard CACurrentMediaTime() < deadline, budget > 0 else { return nil }
        budget -= 1
        if let candidate = stringAttr(el, kAXValueAttribute) ?? stringAttr(el, kAXTitleAttribute),
           let clean = nonGenericLabel(candidate, appName: appName), clean.count >= 2, clean.count <= 80 {
            return clean
        }
        guard let kids = childrenAttr(el) else { return nil }
        for child in kids.prefix(4) {
            guard CACurrentMediaTime() < deadline, budget > 0 else { break }
            budget -= 1
            let role = stringAttr(child, kAXRoleAttribute) ?? ""
            if role == (kAXStaticTextRole as String) || role == "AXHeading" || role == (kAXButtonRole as String) {
                if let val = stringAttr(child, kAXValueAttribute) ?? stringAttr(child, kAXTitleAttribute),
                   let clean = nonGenericLabel(val, appName: appName), clean.count >= 2, clean.count <= 80 {
                    return clean
                }
            }
        }
        return nil
    }

    private static func collectTrailingTexts(
        from el: AXUIElement,
        depth: Int,
        into outReversed: inout [String],
        totalChars: inout Int,
        deadline: CFTimeInterval,
        budget: inout Int
    ) {
        guard depth <= 8, CACurrentMediaTime() < deadline, budget > 0, outReversed.count < 12, totalChars < 900 else { return }
        budget -= 1

        let role = stringAttr(el, kAXRoleAttribute) ?? ""
        if skipPaneRoles.contains(role) { return }
        if stringAttr(el, kAXSubroleAttribute) == "AXSidebar" { return }

        if textLeafRoles.contains(role) {
            if let text = (stringAttr(el, kAXValueAttribute) ?? stringAttr(el, kAXTitleAttribute))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               text.count >= 2 {
                let clipped = String(text.prefix(300))
                outReversed.append(clipped)
                totalChars += clipped.count
            }
            return
        }

        if let desc = stringAttr(el, kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
           desc.count >= 12, role == (kAXGroupRole as String) || role == "AXRow" || role == "AXCell" {
            let clipped = String(desc.prefix(300))
            outReversed.append(clipped)
            totalChars += clipped.count
            return
        }

        guard let kids = childrenAttr(el), !kids.isEmpty else { return }
        // Идём с конца (новые сообщения внизу контейнера).
        let lowerBound = max(0, kids.count - 12)
        for i in stride(from: kids.count - 1, through: lowerBound, by: -1) {
            guard CACurrentMediaTime() < deadline, budget > 0, outReversed.count < 12, totalChars < 900 else { break }
            collectTrailingTexts(from: kids[i], depth: depth + 1, into: &outReversed, totalChars: &totalChars, deadline: deadline, budget: &budget)
        }
    }

    private static func nonGenericLabel(_ raw: String?, appName: String) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !appName.isEmpty && lower == appName.lowercased() { return nil }
        if genericPlaceholders.contains(lower) { return nil }
        return trimmed
    }

    private static func elementAttr(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let child = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(child, 0.05)
        return child
    }

    private static func childrenAttr(_ el: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private static func intAttr(_ el: AXUIElement, _ attr: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private static func stringForRange(_ el: AXUIElement, location: Int, length: Int) -> String? {
        var r = CFRange(location: location, length: length)
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXStringForRangeParameterizedAttribute as CFString, arg, &ref
        ) == .success else { return nil }
        return ref as? String
    }
}

/// Умная раскладка до первой буквы: при входе фокуса в поле ввода или чат заранее ставит
/// нужную раскладку по контексту и запоминает выбор пользователя отдельно для каждого чата/окна.
///
/// Инварианты:
///   1. Главный поток (где живёт EventTap) никогда не вызывает AX IPC — чтение уходит в `probeQueue`.
///   2. Никогда не перебивает пользователя: ручное переключение внутри контекста глушит автопрогноз
///      до ухода из этого контекста и сохраняется в `ContextLayoutMemory` по хэшу.
///   3. Никогда не срабатывает, если пользователь уже начал печатать до завершения пробы.
final class FocusLayoutPredictor {
    static let shared = FocusLayoutPredictor()

    enum TriggerReason: String {
        case appActivated = "активация"
        case click = "клик"
        case focusKey = "переход фокуса"
    }

    private static let skippedBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.campo",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter"
    ]

    var selectLayout: ((_ cyrillic: Bool) -> Bool)?
    var currentIsCyrillic: (() -> Bool)?
    var onDidSwitchLayout: (() -> Void)?

    let memory = ContextLayoutMemory()

    private let probeQueue = DispatchQueue(label: "ru.keyboop.focuspredict", qos: .userInitiated)
    private var scheduledWork: DispatchWorkItem?
    private var probeSeq: UInt64 = 0
    private var lastRealKeyAt: TimeInterval = 0

    // Состояние текущего активного контекста на main-потоке.
    private var activeContextHash = ""
    private var activeContextSpecific = false
    private var activeEffectiveSignature = ""
    private var lastAppliedSignature = ""
    private var manualOverrideSignature: String? = nil

    private init() {}

    /// Сообщить, что пользователь нажал реальную печатную клавишу или Backspace:
    /// отменяет незапущенный прогноз и бракует уже летящий.
    func noteRealKey(at eventTime: TimeInterval) {
        if eventTime > lastRealKeyAt { lastRealKeyAt = eventTime }
        scheduledWork?.cancel()
        scheduledWork = nil
    }

    /// Пользователь сам переключил раскладку или вручную сконвертировал слово в текущем контексте.
    func noteManualLayoutChoice(cyrillic: Bool) {
        guard !activeEffectiveSignature.isEmpty else { return }
        manualOverrideSignature = activeEffectiveSignature
        if activeContextSpecific, !activeContextHash.isEmpty {
            memory.remember(hash: activeContextHash, cyrillic: cyrillic, explicit: true)
            kbLog("умная раскладка: запомнен выбор для чата/окна → \(cyrillic ? "RU" : "EN")")
        }
    }

    /// Пользователь подтвердил язык набором и конверсией в текущем контексте (не переписывает свежий ручной выбор без необходимости).
    func noteConfirmedTypingLayout(cyrillic: Bool) {
        guard activeContextSpecific, !activeContextHash.isEmpty else { return }
        memory.remember(hash: activeContextHash, cyrillic: cyrillic, explicit: false)
    }

    func clearMemory() {
        memory.clear()
        manualOverrideSignature = nil
        lastAppliedSignature = ""
    }

    func schedulePredict(reason: TriggerReason, delay: TimeInterval = 0.07) {
        guard AppSettings.shared.predictLayoutEnabled, !Pause.active else { return }
        // На окнах собственного приложения не переключаемся.
        if let own = Bundle.main.bundleIdentifier,
           Engine.frontmostBundleID() == own {
            resetActiveContext()
            return
        }

        scheduledWork?.cancel()
        probeSeq &+= 1
        let seq = probeSeq
        let triggeredAt = ProcessInfo.processInfo.systemUptime

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard seq == self.probeSeq else { return }
            guard AppSettings.shared.predictLayoutEnabled, !Pause.active else { return }
            guard self.lastRealKeyAt <= triggeredAt else { return }

            self.probeQueue.async {
                guard let snap = AXFocusInspector.captureSnapshot() else { return }
                let enWords = LayoutData.shared.wordsEn
                let classified = snap.isEditableTextInput
                    ? FocusTextClassifier.classify(beforeCaret: snap.beforeCaret,
                                                   fieldText: snap.fieldText,
                                                   paneText: snap.paneText,
                                                   enWords: enWords)
                    : nil

                DispatchQueue.main.async {
                    self.applyPrediction(
                        snap: snap,
                        classified: classified,
                        seq: seq,
                        triggeredAt: triggeredAt,
                        reason: reason
                    )
                }
            }
        }
        scheduledWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetActiveContext() {
        activeContextHash = ""
        activeContextSpecific = false
        activeEffectiveSignature = ""
        lastAppliedSignature = ""
        manualOverrideSignature = nil
    }

    private func applyPrediction(
        snap: AXFocusSnapshot,
        classified: (language: FocusLayoutLanguage, source: FocusPredictSource)?,
        seq: UInt64,
        triggeredAt: TimeInterval,
        reason: TriggerReason
    ) {
        guard seq == probeSeq else { return }
        guard AppSettings.shared.predictLayoutEnabled, !Pause.active else { return }
        // Пользователь уже начал печатать — не меняем раскладку посреди ввода.
        guard lastRealKeyAt <= triggeredAt else { return }

        if snap.isSecureField || !snap.isEditableTextInput {
            resetActiveContext()
            return
        }

        let bid = snap.bundleID
        if bid == Bundle.main.bundleIdentifier || Self.skippedBundleIDs.contains(bid) {
            resetActiveContext()
            return
        }
        if Engine.appMode(for: bid) == "off" || !ExceptionStore.shared.appLayout(bid).isEmpty {
            resetActiveContext()
            return
        }
        let siteResolved = RuleResolver.resolveCurrent(bundleID: bid)
        if siteResolved.sitePreferredLayoutExplicit || siteResolved.effectiveExceptionMode == "off" {
            resetActiveContext()
            return
        }
        if AppSettings.shared.developerMode && Engine.isDevBundleID(bid) {
            resetActiveContext()
            return
        }

        let ctxHash = ContextLayoutMemory.contextHash(bundleID: bid, identity: snap.contextIdentity)
        let effectiveSig: String = snap.hasSpecificIdentity
            ? ctxHash
            : (snap.paneTailHash.isEmpty ? ctxHash : "\(ctxHash):\(snap.paneTailHash)")

        let contextChanged = (effectiveSig != activeEffectiveSignature)
        if contextChanged {
            manualOverrideSignature = nil
            lastAppliedSignature = ""
        }
        activeContextHash = ctxHash
        activeContextSpecific = snap.hasSpecificIdentity
        activeEffectiveSignature = effectiveSig

        // Если в ЭТОМ же контексте пользователь уже переключился вручную — никогда с ним не спорим.
        if manualOverrideSignature == effectiveSig { return }
        // Если для этого же входа уже применили (или проверили) прогноз — повторно не дёргаемся.
        if !contextChanged && lastAppliedSignature == effectiveSig { return }

        // Определяем целевую раскладку:
        // 1) Непустой текст прямо в поле (пользователь редактирует готовый черновик) — приоритетнее старой памяти.
        // 2) Память конкретного чата/окна (если пользователь уже выбирал там язык).
        // 3) Определение языка по сообщениям чата/панели.
        var decision: (cyrillic: Bool, source: FocusPredictSource)?
        if let c = classified, c.source == .fieldText {
            decision = (c.language.isCyrillic, .fieldText)
        } else if snap.hasSpecificIdentity, let remembered = memory.lookup(hash: ctxHash) {
            decision = (remembered.cyrillic, .memory)
        } else if let c = classified {
            decision = (c.language.isCyrillic, c.source)
        }

        lastAppliedSignature = effectiveSig
        guard let target = decision else { return }
        guard let curCyr = currentIsCyrillic?(), curCyr != target.cyrillic else { return }

        if selectLayout?(target.cyrillic) == true {
            onDidSwitchLayout?()
            kbLog("умная раскладка: \(bid) → \(target.cyrillic ? "RU" : "EN") (\(target.source.rawValue), \(reason.rawValue))")
        }
    }
}
