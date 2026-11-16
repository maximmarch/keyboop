import ApplicationServices

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
