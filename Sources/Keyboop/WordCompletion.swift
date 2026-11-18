import AppKit
import ApplicationServices
import Carbon

final class WordCompletion {
    enum Trigger {
        case completion(useContext: Bool)
        case nextWord
    }

    private struct Field {
        let element: AXUIElement
        let pid: pid_t
        let position: Int
        let before: String
        let after: String
        let startsAtFieldStart: Bool
        let geometry: CaretLocator.Geometry
        var bounds: CGRect { geometry.rect }
        let viewport: CGRect?

        func matches(_ other: Field) -> Bool {
            pid == other.pid && position == other.position
                && before.utf16.elementsEqual(other.before.utf16) && after.utf16.elementsEqual(other.after.utf16)
                && CFEqual(element, other.element)
        }

        func hasSameLayout(as other: Field) -> Bool {
            bounds == other.bounds && viewport == other.viewport && geometry.font == other.geometry.font
        }
    }

    private struct Suggestion {
        var field: Field
        let trigger: Trigger
        let prefix: String
        let suffix: String
        let inputSource: String
    }

    enum Insertion {
        case confirmed(prefix: String, suffix: String)
        case unconfirmed
    }

    private let worker = DispatchQueue(label: "ru.keyboop.word-completion", qos: .userInitiated)
    private lazy var localModel = PredictiveLocalModel()
    // Worker-only identity for the field receiving consecutive model requests.
    private var inferenceContext: (pid: pid_t, element: AXUIElement, source: String, id: UUID)?
    private lazy var index: WordCompletionIndex = {
        let counts = Bundle.main.url(forResource: "word_frequencies", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        return WordCompletionIndex(words: LayoutData.shared.wordsRu.union(LayoutData.shared.wordsEn),
                                   frequencies: counts)
    }()
    private lazy var nextWordIndex: NextWordIndex? = {
        guard let url = Bundle.main.url(forResource: "next_words", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NextWordIndex.self, from: data)
    }()
    // State owned by main. The worker only sees each request's cancellation flag.
    private var request: WordCompletionRequest?
    private var debounce: DispatchWorkItem?
    private var suggestion: Suggestion?
    private struct TypedTail {
        let original: Suggestion
        var typed: String
    }
    private var deferredAccept: (() -> Void)?
    private var pendingTail: TypedTail?
    private var keySeed: TypedTail?
    private var overlay: NSPanel?
    var hasSuggestion: Bool { suggestion != nil || pendingTail != nil }

    func invalidate() {
        clearRequest()
        keySeed = nil
        if overlay?.isVisible == true { overlay?.orderOut(nil) }
    }

    func resetInferenceContext() {
        invalidate()
        worker.async { [weak self] in self?.inferenceContext = nil }
    }

    private func cacheScope(for field: Field, source: String) -> UUID {
        if let context = inferenceContext, context.pid == field.pid, context.source == source,
           CFEqual(context.element, field.element) { return context.id }
        let id = UUID()
        inferenceContext = (field.pid, field.element, source, id)
        return id
    }

    private func clearRequest() {
        request?.cancel()
        request = nil
        debounce?.cancel()
        debounce = nil
        suggestion = nil
        pendingTail = nil
        deferredAccept = nil
    }

    // The event tap calls these around a physical key. Only input that survives all hotkeys,
    // layout fixes and snippet handling reaches continueTyping.
    func beginKeyDown() {
        keySeed = pendingTail ?? suggestion.map { TypedTail(original: $0, typed: "") }
        clearRequest()
    }

    func endKeyDown() {
        keySeed = nil
        if suggestion == nil && pendingTail == nil && overlay?.isVisible == true { overlay?.orderOut(nil) }
    }

    func continueTyping(_ characters: String, isEligible: @escaping (Trigger) -> Bool) -> Bool {
        guard var tail = keySeed, !characters.isEmpty,
              isEligible(tail.original.trigger) else { return false }
        tail.typed += characters
        guard tail.original.suffix.hasPrefix(tail.typed) else { return false }
        keySeed = nil
        if tail.original.suffix == tail.typed {
            invalidate()
            return false
        }
        pendingTail = tail
        let current = WordCompletionRequest()
        request = current
        let expected = tail
        worker.asyncAfter(deadline: .now() + .milliseconds(15)) { [weak self] in
            let remainder = String(expected.original.suffix.dropFirst(expected.typed.count))
            let next = Self.readAdvanced(expected.original, inserted: expected.typed, remainder: remainder, request: current)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request === current else { return }
                self.pendingTail = nil
                let accept = self.deferredAccept
                self.deferredAccept = nil
                guard let next, self.present(next, request: current, isEligible: { isEligible(next.trigger) }) else {
                    self.invalidate()
                    return
                }
                accept?()
            }
        }
        return true
    }

    private func present(_ candidate: Suggestion, request: WordCompletionRequest, isEligible: @escaping () -> Bool) -> Bool {
        guard isEligible(), Self.keyboardLayoutID() == candidate.inputSource,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == candidate.field.pid else {
            PredictionDiagnostic.shared.record("prediction.changed")
            return false
        }
        let first = suggestion == nil
        guard show(candidate) else {
            PredictionDiagnostic.shared.record("prediction.noRoom")
            return false
        }
        suggestion = candidate
        if first { watch(candidate, request: request, until: .now() + .seconds(6), isEligible: isEligible) }
        return true
    }

    func schedule(_ trigger: Trigger, useLocalModel: Bool, isEligible: @escaping () -> Bool) {
        invalidate()
        let request = WordCompletionRequest()
        self.request = request
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.request === request else { return }
            self.debounce = nil
            guard isEligible(), let source = Self.keyboardLayoutID(),
                  let app = NSWorkspace.shared.frontmostApplication else {
                PredictionDiagnostic.shared.record("prediction.ineligible")
                self.invalidate()
                return
            }
            let pid = app.processIdentifier
            self.worker.async { [weak self] in
                guard let self, !request.isCancelled else { return }
                self.makeSuggestion(pid: pid, trigger: trigger, source: source, request: request,
                                    useLocalModel: useLocalModel) { [weak self] candidate, reason in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request === request else { return }
                        guard let candidate else {
                            // A deadline may follow an already displayed, complete word.
                            if self.suggestion != nil && reason == "prediction.timeout" { return }
                            PredictionDiagnostic.shared.record(reason)
                            self.invalidate()
                            return
                        }
                        if let visible = self.suggestion, visible.suffix == candidate.suffix,
                           visible.field.hasSameLayout(as: candidate.field) { return }
                        guard self.present(candidate, request: request, isEligible: isEligible) else {
                            self.invalidate()
                            return
                        }
                        PredictionDiagnostic.shared.record(reason, geometry: candidate.field.geometry.source.rawValue)
                    }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }

    // Freeze the displayed phrase before touching the field. Late streaming updates and watchers
    // from its original request cannot replace the tail while an accepted word is being inserted.
    func accept(isEligible: @escaping (Trigger) -> Bool, finished: @escaping (Insertion) -> Void) -> Bool {
        if let pendingTail, isEligible(pendingTail.original.trigger),
           Self.keyboardLayoutID() == pendingTail.original.inputSource {
            // The old overlay is still visible while the host applies the typed letter.
            // Retain this explicit accept until its new AX position has been verified.
            deferredAccept = { [weak self] in _ = self?.accept(isEligible: isEligible, finished: finished) }
            return true
        }
        guard let candidate = suggestion, isEligible(candidate.trigger),
              Self.keyboardLayoutID() == candidate.inputSource,
              let accepted = PredictionPhrase.acceptFirstWord(candidate.suffix) else { return false }
        invalidate()
        let current = WordCompletionRequest()
        request = current
        worker.async { [weak self] in
            let result = Self.insert(candidate, chunk: accepted.insertion, request: current)
            var next: Suggestion?
            if case .confirmed = result, !accepted.remainder.isEmpty {
                next = Self.readAdvanced(candidate, inserted: accepted.insertion, remainder: accepted.remainder, request: current)
            }
            let tail = next
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let valid = self.request === current && isEligible(candidate.trigger)
                if self.request === current {
                    if let tail, valid {
                        if !self.present(tail, request: current, isEligible: { isEligible(candidate.trigger) }) { self.invalidate() }
                    } else {
                        self.invalidate()
                    }
                }
                if let result { finished(valid ? result : .unconfirmed) }
            }
        }
        return true
    }

    private func makeSuggestion(pid: pid_t, trigger: Trigger, source: String, request: WordCompletionRequest,
                                useLocalModel: Bool, finished: @escaping (Suggestion?, String) -> Void) {
        var fieldReason = "prediction.field"
        guard let field = Self.readField(pid: pid, report: { fieldReason = $0 }) else {
            finished(nil, fieldReason)
            return
        }
        guard !request.isCancelled else { return }
        guard field.after.isEmpty || field.after.first?.isNewline == true else {
            finished(nil, "prediction.rightText")
            return
        }
        let before = field.before.replacingOccurrences(of: "\u{00A0}", with: " ")
        let prefix: String
        let dictionarySuffix: String?
        switch trigger {
        case let .completion(useContext):
            guard let actual = WordCompletionIndex.prefix(before: before, after: field.after,
                                                          startsAtFieldStart: field.startsAtFieldStart) else {
                finished(nil, "prediction.noMatch")
                return
            }
            prefix = actual
            let preferred = useContext ? nextWordIndex?.predict(before: String(before.dropLast(prefix.count)),
                                                                 startsAtFieldStart: field.startsAtFieldStart) : nil
            dictionarySuffix = index.suffix(for: prefix, preferredWord: preferred)
        case .nextWord:
            prefix = ""
            dictionarySuffix = nextWordIndex?.predict(before: before, startsAtFieldStart: field.startsAtFieldStart)
        }

        func publish(_ suffix: String, reason: String) {
            guard !request.isCancelled else { return }
            guard let current = Self.readField(pid: pid), field.matches(current) else {
                finished(nil, "prediction.changed")
                return
            }
            finished(Suggestion(field: current, trigger: trigger, prefix: prefix, suffix: suffix, inputSource: source), reason)
        }
        if let suffix = dictionarySuffix { publish(suffix, reason: "prediction.dictionary"); return }
        guard useLocalModel else { finished(nil, "prediction.noMatch"); return }
        let contextWord: String
        if prefix.isEmpty {
            guard before.last == " ",
                  let word = WordCompletionIndex.prefix(before: String(before.dropLast()), after: "",
                                                        startsAtFieldStart: field.startsAtFieldStart) else {
                finished(nil, "prediction.noMatch")
                return
            }
            contextWord = word
        } else {
            guard prefix.count >= 3 else { finished(nil, "prediction.noMatch"); return }
            contextWord = prefix
        }
        guard !request.isCancelled, !IsSecureEventInputEnabled(),
              let current = Self.readField(pid: pid), field.matches(current) else {
            finished(nil, "prediction.changed")
            return
        }
        guard let connection = PredictionRuntime.shared.connection() else { finished(nil, "prediction.modelNotReady"); return }
        // Only the managed server has our private single slot and no shared prompt cache.
        let scope = connection.apiKey.map { _ in cacheScope(for: current, source: source) }
        let context = scope == nil ? before : PredictiveLocalModel.stableContext(before, caretPosition: current.position)
        // Give a warm model its own budget after the dictionary pass; new input still cancels immediately.
        let deadline = DispatchTime.now() + .milliseconds(650)
        localModel.predict(before: context, contextWord: contextWord, completing: !prefix.isEmpty,
                           endpoint: connection.baseURL, apiKey: connection.apiKey, cacheScope: scope,
                           request: request, deadline: deadline) { [weak self] event in
            self?.worker.async {
                guard !request.isCancelled else { return }
                switch event {
                case .partial(let text), .finished(.some(let text)):
                    guard DispatchTime.now() <= deadline else { finished(nil, "prediction.timeout"); return }
                    publish(text, reason: "prediction.model")
                case .failed(let reason): finished(nil, reason)
                case .finished(nil): finished(nil, "prediction.noMatch")
                }
            }
        }
    }

    private static func readAdvanced(_ candidate: Suggestion, inserted: String, remainder: String,
                                     request: WordCompletionRequest) -> Suggestion? {
        let target = candidate.field
        for attempt in 0..<4 {
            guard !request.isCancelled else { return nil }
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.015) }
            guard let field = readField(pid: target.pid), CFEqual(target.element, field.element) else { return nil }
            if PredictionPhrase.matchesEdit(before: target.before, after: target.after, inserted: inserted, position: target.position,
                                            newBefore: field.before, newAfter: field.after, newPosition: field.position) {
                let prefix = field.before.reversed().prefix(while: { $0.isLetter }).reversed()
                return Suggestion(field: field, trigger: candidate.trigger, prefix: String(prefix),
                                  suffix: remainder, inputSource: candidate.inputSource)
            }
        }
        return nil
    }

    private func watch(_ candidate: Suggestion, request: WordCompletionRequest, until expiry: DispatchTime,
                       isEligible: @escaping () -> Bool) {
        // Reflow, scrolling and a growing composer can move the same insertion point between
        // AX reads. Keep the latest streamed suffix and place it at the current coordinates.
        worker.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard !request.isCancelled else { return }
            let current = DispatchTime.now() < expiry ? Self.readField(pid: candidate.field.pid) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request === request, var visible = self.suggestion else { return }
                guard let current, visible.field.matches(current), isEligible() else { self.invalidate(); return }
                if !visible.field.hasSameLayout(as: current) {
                    visible.field = current
                    guard self.present(visible, request: request, isEligible: isEligible) else {
                        self.invalidate()
                        return
                    }
                }
                self.watch(visible, request: request, until: expiry, isEligible: isEligible)
            }
        }
    }

    private static func insert(_ suggestion: Suggestion, chunk: String, request: WordCompletionRequest) -> Insertion? {
        let target = suggestion.field
        let result = request.insert(readTarget: { () -> Field? in
            guard let current = readField(pid: target.pid),
                  target.matches(current), !IsSecureEventInputEnabled() else { return nil }
            return current
        }, write: { field in
            TextReplacer.postSuggestion(chunk, to: field.pid)
        }, verify: {
            // The target processes a posted keystroke asynchronously. Only reread the field.
            for attempt in 0..<5 {
                guard !request.isCancelled else { return false }
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.02) }
                guard let updated = readField(pid: target.pid),
                      CFEqual(updated.element, target.element) else { return false }
                guard updated.position == target.position + chunk.utf16.count else { continue }
                return PredictionPhrase.matchesEdit(before: target.before, after: target.after, inserted: chunk, position: target.position,
                                                    newBefore: updated.before, newAfter: updated.after, newPosition: updated.position)
            }
            return false
        })
        switch result {
        case .skipped: return nil
        case .unconfirmed: return .unconfirmed
        case .confirmed: return .confirmed(prefix: suggestion.prefix, suffix: chunk)
        }
    }

    private static func readField(pid: pid_t, report: (String) -> Void = { _ in }) -> Field? {
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let focused: CFTypeRef?
        if let systemFocus = attribute(system, kAXFocusedUIElementAttribute) {
            focused = systemFocus
        } else {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            focused = attribute(app, kAXFocusedUIElementAttribute)
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard isEditableText(element) else { return nil }
        return snapshot(element: element, pid: pid, report: report)
    }

    private static func isEditableText(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let secureRole = kAXSecureTextFieldSubrole as String
        guard role != secureRole, subrole != secureRole,
              attribute(element, kAXEnabledAttribute) as? Bool != false else { return false }

        // Web editors and some custom controls declare editability directly.
        let editable = (attribute(element, "AXIsEditable") as? Bool) ?? (attribute(element, "AXEditable") as? Bool)
        if let editable { return editable }

        // Native text controls normally advertise writable text through their AX setters.
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
                || role == kAXComboBoxRole as String || role == kAXGroupRole as String else { return false }
        return [kAXSelectedTextAttribute, kAXValueAttribute].contains { name in
            var writable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
        }
    }

    private static func snapshot(element: AXUIElement, pid: pid_t, report: (String) -> Void) -> Field? {
        var range = CFRange()
        guard let selected = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID(),
              AXValueGetValue(selected as! AXValue, .cfRange, &range) else {
            if let field = markerSnapshot(element: element, pid: pid) { return field }
            report("prediction.caret")
            return nil
        }
        guard range.length == 0, range.location > 0 else { return nil }
        let left = max(0, range.location - 128)
        let nearby: (String, String)?
        if let length = attribute(element, kAXNumberOfCharactersAttribute) as? Int, length >= range.location,
           let before = text(element, from: left, length: range.location - left),
           let after = text(element, from: range.location, length: min(12, length - range.location)) {
            nearby = (before, after)
        } else if let value = attribute(element, kAXValueAttribute) as? NSString,
                  value.length >= range.location {
            nearby = (value.substring(with: NSRange(location: left, length: range.location - left)),
                      value.substring(with: NSRange(location: range.location, length: min(12, value.length - range.location))))
        } else {
            if let field = markerSnapshot(element: element, pid: pid) { return field }
            report("prediction.field")
            return nil
        }
        guard let (before, after) = nearby,
              let geometry = CaretLocator.inlineGeometry(in: element, at: range.location, before: before, after: after, viewport: frame(of: element)) else {
            if let field = markerSnapshot(element: element, pid: pid) { return field }
            report("prediction.caret")
            return nil
        }
        return Field(element: element, pid: pid, position: range.location, before: before, after: after,
                     startsAtFieldStart: left == 0, geometry: geometry, viewport: frame(of: element))
    }

    // Web editors can expose selection and bounds as text markers instead of UTF-16 ranges.
    private static func markerSnapshot(element: AXUIElement, pid: pid_t) -> Field? {
        func parameter(_ name: String, _ value: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
            return result
        }

        let length = "AXLengthForTextMarkerRange"
        let start = "AXStartTextMarkerForTextMarkerRange"
        let end = "AXEndTextMarkerForTextMarkerRange"
        let span = "AXTextMarkerRangeForUnorderedTextMarkers"
        let string = "AXStringForTextMarkerRange"
        guard let selected = attribute(element, "AXSelectedTextMarkerRange"),
              parameter(length, selected) as? Int == 0,
              let cursor = parameter(start, selected),
              let full = parameter("AXTextMarkerRangeForUIElement", element),
              let count = parameter(length, full) as? Int, (1...16_384).contains(count),
              let first = parameter(start, full), let last = parameter(end, full),
              let left = parameter(span, [first, cursor] as CFArray),
              let right = parameter(span, [cursor, last] as CFArray),
              let before = parameter(string, left) as? NSString,
              let after = parameter(string, right) as? NSString,
              before.length > 0, before.length + after.length == count else { return nil }
        let leftText = before.substring(from: max(0, before.length - 128))
        let rightText = after.substring(to: min(12, after.length))
        guard let geometry = CaretLocator.inlineGeometry(in: element, at: before.length,
            before: leftText, after: rightText, viewport: frame(of: element), selectedMarker: selected) else { return nil }
        return Field(element: element, pid: pid, position: before.length,
                     before: leftText,
                     after: rightText, startsAtFieldStart: before.length <= 128,
                     geometry: geometry, viewport: frame(of: element))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func text(_ element: AXUIElement, from start: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: start, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success,
              let string = result as? String, string.utf16.count == length else { return nil }
        return string
    }

    private static func keyboardLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
              CFEqual(Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue(), kTISTypeKeyboardLayout),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    private func show(_ candidate: Suggestion) -> Bool {
        let caret = CaretLocator.flipToCocoa(candidate.field.bounds)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret.insetBy(dx: -1, dy: 0)) }) else { return false }
        let label = NSTextField(labelWithString: candidate.suffix)
        label.font = candidate.field.geometry.font ?? .systemFont(ofSize: min(32, max(9, caret.height * 0.78)))
        label.textColor = .systemGray
        let fieldRight = candidate.field.viewport.map { CaretLocator.flipToCocoa($0).maxX } ?? screen.visibleFrame.maxX
        func fit() -> NSRect? {
            label.sizeToFit()
            label.setFrameOrigin(.zero)
            let frame = CaretLocator.inlineFrame(caret: caret, label: label)
            return screen.visibleFrame.contains(frame) && frame.maxX <= fieldRight ? frame : nil
        }
        var fitted = fit()
        // Close to the right edge, show exactly the word the shortcut would accept.
        if fitted == nil {
            label.stringValue = PredictionPhrase.firstChunk(candidate.suffix)
            fitted = fit()
        }
        guard let frame = fitted else { return false }

        if overlay == nil {
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.level = .floating
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
            overlay = window
        }
        overlay?.contentView = label
        overlay?.setFrame(frame, display: true)
        overlay?.orderFrontRegardless()
        return true
    }
}
