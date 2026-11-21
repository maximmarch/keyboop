import ApplicationServices
import AppKit
import Carbon

// MARK: - Что стоит слева от каретки (задача 187)

/// Что находится непосредственно СЛЕВА от точки ввода.
enum CaretLeft {
    /// Буква: каретка внутри слова или сразу за ним. Одиночную букву тут трогать нельзя.
    case letter
    /// Пробел, знак препинания или самое начало поля: слева слова нет, конверсия безопасна.
    case boundary
    /// Accessibility не ответил (Electron, web, запрет доступа, таймаут). Ведём себя осторожно.
    case unknown
}

enum SelectionText {
    /// Спросить у системы, что слева от каретки. ⚠️ ТОЛЬКО В ФОНЕ И ТОЛЬКО ЗАРАНЕЕ.
    ///
    /// Зачем это вообще (задача 187, наблюдение автора 22.08.2026). После прыжка каретки мы не трогаем
    /// первую одиночную букву: слева на экране может стоять целое слово, которого мы не видим, и
    /// «починив» букву внутри него, мы отменяем правку, которую человек только что сделал руками
    /// (его же баг 02.08). Но правило слепое: в пустом поле оно тоже молчит, хотя там чинить безопасно.
    /// Этот запрос превращает догадку в наблюдение.
    ///
    /// ⚠️ ПОЧЕМУ ЗАРАНЕЕ, А НЕ В МОМЕНТ РЕШЕНИЯ. Решение принимается на границе слова, в главном
    /// потоке, где живёт runloop нашего перехватчика. Обращение к Accessibility оттуда может занять
    /// десятки миллисекунд, а система убивает перехватчик, если колбэк не уложился в срок. У проекта
    /// уже есть шрам ровно этого рода: вызов за разрешением из горячего пути заморозил ВЕСЬ ввод в
    /// системе. Поэтому спрашиваем в момент КЛИКА, в фоне, и к границе слова ответ уже лежит готовым.
    ///
    /// ⚠️ Таймаут обязателен: неотвечающее приложение (зависший Electron) иначе держит наш фоновый
    /// поток минутами, и ответ приходит к чужому уже клику.
    static func caretLeftAsync(_ done: @escaping (CaretLeft) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            done(caretLeftBlocking())
        }
    }

    /// Синхронная часть. Отдельно — чтобы её можно было позвать из стенда.
    static func caretLeftBlocking() -> CaretLeft {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return .unknown }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return .unknown }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return .unknown }
        // Каретка в самом начале поля: слева заведомо ничего нет.
        if range.location <= 0 { return .boundary }

        var before = CFRange(location: range.location - 1, length: 1)
        guard let arg = AXValueCreate(.cfRange, &before) else { return .unknown }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, arg, &strRef) == .success,
              let ch = (strRef as? String)?.first else { return .unknown }
        return ch.isLetter ? .letter : .boundary
    }
}

extension SelectionText {
    /// Identity of a selection that will survive a background operation and a preview.
    /// Revalidate the field, range and text before writing, even if the same app is still open.
    struct CorrectionTarget {
        let text: String
        fileprivate let pid: pid_t
        fileprivate let element: AXUIElement
        fileprivate let range: CFTypeRef

        func isCurrent() -> Bool {
            guard !IsSecureEventInputEnabled(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let current = SelectionText.readAX(), CFEqual(element, current.element),
                  text.utf16.elementsEqual(current.text.utf16),
                  let selectedRange = SelectionText.selectionRange(in: current.element) else { return false }
            return CFEqual(range, selectedRange)
        }

        func replace(with replacement: String) -> Bool {
            guard isCurrent() else { return false }
            return SelectionText.write(element, replacement)
        }
    }

    static func correctionTarget(in pid: pid_t) -> CorrectionTarget? {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let (element, text) = readAX() else { return nil }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole as String else { return nil }
        let owner = ownerApp(of: element)
        guard !isGecko(bundleID: owner.bid, bundleURL: owner.url) else { return nil }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue, let range = selectionRange(in: element) else { return nil }
        return CorrectionTarget(text: text, pid: pid, element: element, range: range)
    }

    private static func selectionRange(in element: AXUIElement) -> CFTypeRef? {
        for attribute in [kAXSelectedTextRangeAttribute, "AXSelectedTextMarkerRange"] {
            var range: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &range) == .success, let range {
                return range
            }
        }
        return nil
    }

    private static func readAX() -> (element: AXUIElement, text: String)? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let fErr = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard fErr == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var sel: CFTypeRef?
        let sErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &sel)
        guard sErr == .success, let text = sel as? String, !text.isEmpty else { return nil }
        return (element, text)
    }

    /// Известные программы на Gecko. Форки с незнакомым id ловит проверка XUL в `isGecko`.
    static let geckoBundleIDs: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "org.mozilla.thunderbird", "org.mozilla.seamonkey", "org.torproject.torbrowser",
        "net.mullvad.mullvadbrowser", "io.gitlab.librewolf-community", "app.zen-browser.zen",
        "net.waterfox.waterfox", "one.ablaze.floorp", "eu.betterbird.Betterbird",
    ]

    /// ⚠️ ТОЛЬКО ТОЧНОЕ СОВПАДЕНИЕ, БЕЗ ПРЕФИКСА `org.mozilla.` (ревью, 26.09.2026). Префикс ловил и
    /// программы Mozilla НЕ на Gecko: Firefox для iOS на Mac с Apple Silicon (`org.mozilla.ios.*`,
    /// это WebKit) и Mozilla VPN (Qt). У них AX-запись работает, а префикс перевёл бы их на печать и
    /// отказ для многострочного, то есть поменял бы то, что работает. Настоящий Gecko с незнакомым
    /// id ловит проверка XUL: libxul это и есть движок, без неё Gecko не запустится. Ошибись путь,
    /// мы просто останемся на прежней AX-записи, то есть на сегодняшнем поведении.
    static func isGeckoBundleID(_ bid: String) -> Bool {
        geckoBundleIDs.contains(bid)
    }

    /// Gecko по bundle id, а для незнакомого id по факту: лежит ли в пакете библиотека движка
    /// `Contents/MacOS/XUL`. ⚠️ Путь к XUL на живом Firefox.app не сверен (на машине разработки его
    /// нет), поэтому это только ДОБАВКА к списку: ошибись он, список всё равно ловит основные
    /// программы, а ложное срабатывание стоит двух вещей: однострочное пишем печатью, как в
    /// Electron, а от многострочного отказываемся.
    /// Кэш по bundle id, как у `Engine.isElectronApp`: файловая система один раз на приложение.
    private static var geckoCache: [String: Bool] = [:]
    static func isGecko(bundleID bid: String, bundleURL: URL?) -> Bool {
        if isGeckoBundleID(bid) { return true }
        if !bid.isEmpty, let cached = geckoCache[bid] { return cached }
        guard let url = bundleURL else { return false }   // без пакета не кэшируем: спросим ещё раз
        let found = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/XUL").path)
        if !bid.isEmpty { geckoCache[bid] = found }
        return found
    }

    /// Чьё это поле. Спрашиваем у самого элемента, а не у переднего приложения: запись через AX
    /// уйдёт именно владельцу элемента. Не вышло — переднее приложение, как раньше в логе.
    private static func ownerApp(of element: AXUIElement) -> (bid: String, url: URL?) {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid), let bid = app.bundleIdentifier {
            return (bid, app.bundleURL)
        }
        // ⚠️ Пакет берём, только если он того же приложения: при открытом Spotlight
        // `frontmostBundleID` отвечает за Spotlight, а `frontmostApplication` за программу под ним,
        // и кэш Gecko записал бы Spotlight движком чужого пакета.
        let bid = Engine.frontmostBundleID()
        let front = NSWorkspace.shared.frontmostApplication
        return (bid, front?.bundleIdentifier == bid ? front?.bundleURL : nil)
    }

    private static func write(_ element: AXUIElement, _ replacement: String) -> Bool {
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                          replacement as CFTypeRef) == .success else { return false }
        guard let current = typingAttribute(element, kAXSelectedTextAttribute) as? String else { return true }
        return current.isEmpty || current == replacement
    }

    /// A bounded snapshot at a collapsed caret. Auto-proofreading uses only editors with
    /// native AX range and selected-text setters.
    struct TypingTarget {
        let text: String
        fileprivate let field: TypingField
        fileprivate let range: NSRange

        func isCurrent() -> Bool {
            guard let current = SelectionText.typingField(in: field.pid) else { return false }
            return CFEqual(field.element, current.element) && field.position == current.position
                && field.length == current.length
                && field.before.utf16.elementsEqual(current.before.utf16)
                && field.after.utf16.elementsEqual(current.after.utf16)
        }

        func replace(_ edit: SageCorrectionText.TypingEdit) -> Bool {
            guard isCurrent() else { return false }
            return edit.apply(to: text, startingAt: range.location, in: field)
        }
    }

    fileprivate struct TypingField: SageTypingEditor {
        let pid: pid_t
        let element: AXUIElement
        let position: Int
        let length: Int
        let before: String
        let after: String

        var isFocused: Bool {
            SelectionText.focusedTypingElement(in: pid).map { CFEqual($0, element) } == true
        }

        var selection: NSRange? { SelectionText.typingSelection(in: element) }

        func select(_ range: NSRange) -> Bool {
            SelectionText.setTypingSelection(range, in: element)
        }

        func text(in range: NSRange) -> String? {
            SelectionText.typingText(in: element, range: range)
        }

        func replaceSelection(with text: String) -> Bool {
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                         text as CFTypeRef) == .success
        }

        func collapseSelection() {
            _ = TextReplacer.postSuggestionRightArrow(to: pid)
        }
    }

    static func typingTarget(in pid: pid_t, afterTyping key: Character) -> TypingTarget? {
        guard let field = typingField(in: pid), let last = field.before.last,
              last == key || (key == " " && last.isWhitespace && !last.isNewline),
              field.after.isEmpty || field.after.first?.isNewline == true,
              let local = SageCorrectionText.typingRange(before: field.before,
                                                         startsAtFieldStart: field.position == field.before.utf16.count) else { return nil }
        let start = field.position - field.before.utf16.count + local.location
        return TypingTarget(text: (field.before as NSString).substring(with: local), field: field,
                            range: NSRange(location: start, length: local.length))
    }

    private static func typingField(in pid: pid_t) -> TypingField? {
        guard let element = focusedTypingElement(in: pid),
              typingAttribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String,
              typingAttribute(element, kAXEnabledAttribute) as? Bool != false,
              let selected = typingSelection(in: element), selected.length == 0, selected.location > 0 else { return nil }
        let owner = ownerApp(of: element)
        guard !isGecko(bundleID: owner.bid, bundleURL: owner.url) else { return nil }
        for name in [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute] {
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success,
                  writable.boolValue else { return nil }
        }

        let start = max(0, selected.location - SageCorrectionText.typingWindowLength)
        let left = NSRange(location: start, length: selected.location - start)
        if let length = typingAttribute(element, kAXNumberOfCharactersAttribute) as? Int, length >= selected.location,
           let before = typingText(in: element, range: left),
           let after = typingText(in: element, range: NSRange(location: selected.location,
                                                              length: min(16, length - selected.location))) {
            return TypingField(pid: pid, element: element, position: selected.location, length: length,
                               before: before, after: after)
        }
        guard let value = typingAttribute(element, kAXValueAttribute) as? NSString,
              value.length <= 16_384, value.length >= selected.location else { return nil }
        return TypingField(pid: pid, element: element, position: selected.location, length: value.length,
                           before: value.substring(with: left),
                           after: value.substring(with: NSRange(location: selected.location,
                                                                length: min(16, value.length - selected.location))))
    }

    private static func focusedTypingElement(in pid: pid_t) -> AXUIElement? {
        guard !IsSecureEventInputEnabled(), pid != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focus = typingAttribute(system, kAXFocusedUIElementAttribute)
                ?? typingAttribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focus) == AXUIElementGetTypeID() else { return nil }
        let element = focus as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.08)
        guard typingAttribute(element, kAXRoleAttribute) as? String != kAXSecureTextFieldSubrole as String else { return nil }
        return element
    }

    private static func typingAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func typingSelection(in element: AXUIElement) -> NSRange? {
        var range = CFRange()
        guard let value = typingAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func setTypingSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        var selection = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &selection) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func typingText(in element: AXUIElement, range: NSRange) -> String? {
        guard range.length > 0 else { return "" }
        var parameter = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &parameter) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      value, &result) == .success, let text = result as? String,
           text.utf16.count == range.length {
            return text
        }
        guard let full = typingAttribute(element, kAXValueAttribute) as? NSString,
              full.length <= 16_384, NSMaxRange(range) <= full.length else { return nil }
        return full.substring(with: range)
    }
}
