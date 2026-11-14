import AppKit
import ApplicationServices

struct SnippetInsertionOutcome {
    let insertedText: String
    let glue: String
}

/// Захваченный снимок контекста ввода на момент активации динамического сниппета (KB-004).
private struct SnippetContextSnapshot {
    let pid: pid_t
    let bundleID: String
    let sourceApp: NSRunningApplication?
    weak var ownWindow: NSWindow?
    let focusedElement: AXUIElement?
    let windowElement: AXUIElement?
    let windowTitle: String?
    let focusedRole: String?
    let focusedSubrole: String?
    let caretRect: NSRect?
    let capturedAt: Date

    static func captureCurrent() -> SnippetContextSnapshot? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        let bundleID = front.bundleIdentifier ?? ""
        let ownWin: NSWindow? = (pid == ProcessInfo.processInfo.processIdentifier) ? NSApp.keyWindow : nil

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)

        var focusedEl: AXUIElement?
        var windowEl: AXUIElement?
        var windowTitle: String?
        var role: String?
        var subrole: String?

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let rawFocused = focusedRef, CFGetTypeID(rawFocused) == AXUIElementGetTypeID() {
            let el = rawFocused as! AXUIElement
            var elPid: pid_t = 0
            AXUIElementGetPid(el, &elPid)
            // Принимаем AX-элемент только если он принадлежит переднему приложению (защита от накладных панелей).
            if elPid == pid || elPid == 0 {
                focusedEl = el
                AXUIElementSetMessagingTimeout(el, 0.05)

                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success {
                    role = roleRef as? String
                }
                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef) == .success {
                    subrole = subroleRef as? String
                }
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &winRef) == .success,
                   let rawWin = winRef, CFGetTypeID(rawWin) == AXUIElementGetTypeID() {
                    windowEl = (rawWin as! AXUIElement)
                }
            }
        }

        if windowEl == nil {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 0.05)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let rawWin = winRef, CFGetTypeID(rawWin) == AXUIElementGetTypeID() {
                windowEl = (rawWin as! AXUIElement)
            }
        }

        if let windowEl {
            AXUIElementSetMessagingTimeout(windowEl, 0.05)
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowEl, kAXTitleAttribute as CFString, &titleRef) == .success {
                windowTitle = titleRef as? String
            }
        }

        let caret = CaretLocator.caretScreenRect()

        return SnippetContextSnapshot(
            pid: pid,
            bundleID: bundleID,
            sourceApp: front,
            ownWindow: ownWin,
            focusedElement: focusedEl,
            windowElement: windowEl,
            windowTitle: windowTitle,
            focusedRole: role,
            focusedSubrole: subrole,
            caretRect: caret,
            capturedAt: Date()
        )
    }
}

private enum ContextCheckFailure {
    case appChangedOrTerminated
    case windowChangedOrClosed
    case fieldChanged
    case secureInput
}

/// Координатор жизненного цикла формы динамического сниппета и безопасной вставки (KB-004).
/// Выносит UI и AX-проверки из горячего CGEventTap-колбэка на main thread, проверяет совпадение
/// исходного окна/поля перед вставкой и подавляет повторное срабатывание триггера.
final class SnippetInsertionCoordinator {
    static let shared = SnippetInsertionCoordinator()

    private let stateLock = NSLock()
    private var _isFormActive = false

    private var activeForm: SnippetFormController?
    private var activeSnapshot: SnippetContextSnapshot?
    private var pendingTrigger: String = ""
    private var pendingWhitespace: String = " "
    private var completionHandler: ((SnippetInsertionOutcome?) -> Void)?

    /// Потокобезопасный флаг для CGEventTap: пока открыта форма сниппета, блокируем авто-замены и ре-триггеры.
    var isFormActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isFormActive
    }

    private func setFormActive(_ active: Bool) {
        stateLock.lock()
        _isFormActive = active
        stateLock.unlock()
    }

    func beginInteractiveExpansion(
        snippet: SnippetV2,
        trigger: String,
        whitespace: String,
        completion: @escaping (SnippetInsertionOutcome?) -> Void
    ) {
        // Ставим флаг немедленно (синхронно до выхода из тапа), чтобы следующие нажатия не ушли мимо.
        stateLock.lock()
        if _isFormActive {
            stateLock.unlock()
            completion(nil)
            return
        }
        _isFormActive = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.presentOnMain(snippet: snippet, trigger: trigger, whitespace: whitespace, completion: completion)
        }
    }

    private func presentOnMain(
        snippet: SnippetV2,
        trigger: String,
        whitespace: String,
        completion: @escaping (SnippetInsertionOutcome?) -> Void
    ) {
        guard let snapshot = SnippetContextSnapshot.captureCurrent() else {
            kbLog("snippet-form: не удалось захватить контекст ввода — отмена")
            setFormActive(false)
            completion(nil)
            return
        }

        if snapshot.focusedSubrole == "AXSecureTextField" || !SecureInputPolicy.canWrite("snippet-form-open") {
            kbLog("snippet-form: Secure Input активен в \(snapshot.bundleID) — форма не показана")
            setFormActive(false)
            AppBanner.shared.show(
                title: L10n.t("snip.form.abortTitle"),
                body: L10n.t("snip.form.abortSecure"),
                autoDismiss: 4.0
            )
            completion(nil)
            return
        }

        activeSnapshot = snapshot
        pendingTrigger = trigger
        pendingWhitespace = whitespace
        completionHandler = completion

        let form = SnippetFormController(
            snippet: snippet,
            onConfirm: { [weak self] renderedText in
                self?.handleConfirm(renderedText: renderedText)
            },
            onCancel: { [weak self] in
                self?.handleCancel()
            }
        )
        activeForm = form
        form.show(nearCaretRect: snapshot.caretRect)
    }

    private func handleConfirm(renderedText: String) {
        guard let snapshot = activeSnapshot else {
            finishSession(with: nil)
            return
        }
        let trigger = pendingTrigger
        let ws = pendingWhitespace
        activeForm = nil

        guard !renderedText.isEmpty else {
            kbLog("snippet-form: пустой результат рендера — триггер сохранен")
            restoreFocusAndRun(snapshot: snapshot) { [weak self] in
                AppBanner.shared.show(
                    title: L10n.t("snip.form.abortTitle"),
                    body: L10n.t("snip.form.emptyResult"),
                    autoDismiss: 4.0
                )
                self?.finishSession(with: nil)
            }
            return
        }

        restoreFocusAndRun(snapshot: snapshot) { [weak self] in
            guard let self else { return }
            if let failure = self.verifyTargetContext(snapshot: snapshot) {
                self.reportAbort(failure: failure, bundleID: snapshot.bundleID)
                self.finishSession(with: nil)
                return
            }

            // §7: Если форма была открыта по Enter или Tab, не отправляем их после вставки,
            // чтобы не отправить сообщение в чате и не увести фокус из формы.
            let glue: String
            if ws == " " {
                if let last = renderedText.last, last == " " || last == "\n" || last == "\t" {
                    glue = ""
                } else {
                    glue = " "
                }
            } else {
                glue = ""
            }

            let finalPayload = renderedText + glue
            TextReplacer.replace(
                deleteCount: trigger.count,
                with: finalPayload,
                firstKeySettleMicros: 55_000
            ) { [weak self] in
                kbLog("snippet-form: вставка -\(trigger.count)+\(renderedText.count) симв. в \(snapshot.bundleID)")
                self?.finishSession(with: SnippetInsertionOutcome(insertedText: renderedText, glue: glue))
            }
        }
    }

    private func handleCancel() {
        guard let snapshot = activeSnapshot else {
            finishSession(with: nil)
            return
        }
        let ws = pendingWhitespace
        activeForm = nil

        restoreFocusAndRun(snapshot: snapshot) { [weak self] in
            guard let self else { return }
            // Проглоченный пробел восстанавливаем только если остались в том же окне/поле.
            // Enter и Tab после отмены НЕ пересылаем, чтобы не отправить неготовый триггер в чат.
            if ws == " ", self.verifyTargetContext(snapshot: snapshot) == nil {
                TextReplacer.insert(" ") { [weak self] in
                    kbLog("snippet-form: отмена, пробел восстановлен в \(snapshot.bundleID)")
                    self?.finishSession(with: nil)
                }
            } else {
                kbLog("snippet-form: отмена, триггер сохранён в \(snapshot.bundleID)")
                self.finishSession(with: nil)
            }
        }
    }

    private func finishSession(with outcome: SnippetInsertionOutcome?) {
        let cb = completionHandler
        activeForm = nil
        activeSnapshot = nil
        pendingTrigger = ""
        pendingWhitespace = " "
        completionHandler = nil
        setFormActive(false)
        cb?(outcome)
    }

    // MARK: - Focus Restoration & Context Verification

    private func restoreFocusAndRun(snapshot: SnippetContextSnapshot, deadlineOffset: TimeInterval = 0.35, action: @escaping () -> Void) {
        if snapshot.pid == ProcessInfo.processInfo.processIdentifier {
            snapshot.ownWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: action)
            return
        }

        if let app = snapshot.sourceApp, !app.isTerminated {
            app.activate(options: [])
        } else {
            action()
            return
        }

        let deadline = ProcessInfo.processInfo.systemUptime + deadlineOffset
        func poll() {
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPid == snapshot.pid && !NSApp.isActive {
                // Небольшая пауза на фиксацию firstResponder целевым приложением.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: action)
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                action()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }

    private func verifyTargetContext(snapshot: SnippetContextSnapshot) -> ContextCheckFailure? {
        guard let currentFront = NSWorkspace.shared.frontmostApplication,
              currentFront.processIdentifier == snapshot.pid,
              snapshot.sourceApp?.isTerminated == false else {
            return .appChangedOrTerminated
        }

        guard SecureInputPolicy.canWrite("snippet-form-verify") else {
            return .secureInput
        }

        let isOwnApp = (snapshot.pid == ProcessInfo.processInfo.processIdentifier)
        if isOwnApp, let origOwn = snapshot.ownWindow {
            if NSApp.keyWindow !== origOwn {
                return .windowChangedOrClosed
            }
        }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)

        var currentFocused: AXUIElement?
        var currentFocusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &currentFocusedRef) == .success,
           let raw = currentFocusedRef, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let el = raw as! AXUIElement
            var elPid: pid_t = 0
            AXUIElementGetPid(el, &elPid)
            if elPid != snapshot.pid && elPid != 0 {
                return .appChangedOrTerminated
            }
            currentFocused = el
            AXUIElementSetMessagingTimeout(el, 0.05)
        }

        // Проверяем окно
        if let origWin = snapshot.windowElement {
            var currentWin: AXUIElement?
            if let currentFocused {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(currentFocused, kAXWindowAttribute as CFString, &winRef) == .success,
                   let rawWin = winRef, CFGetTypeID(rawWin) == AXUIElementGetTypeID() {
                    currentWin = (rawWin as! AXUIElement)
                }
            }
            if currentWin == nil {
                let appEl = AXUIElementCreateApplication(snapshot.pid)
                AXUIElementSetMessagingTimeout(appEl, 0.05)
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
                   let rawWin = winRef, CFGetTypeID(rawWin) == AXUIElementGetTypeID() {
                    currentWin = (rawWin as! AXUIElement)
                }
            }
            guard let currentWin else {
                return .windowChangedOrClosed
            }
            if !CFEqual(origWin, currentWin) {
                return .windowChangedOrClosed
            }
        }

        // Проверяем поле ввода (в нативных приложениях CFEqual должен совпадать; в Electron/web допускаем пересозданный proxy с тем же role/subrole).
        if let origEl = snapshot.focusedElement {
            guard let currentFocused else {
                return .fieldChanged
            }
            var curSubroleRef: CFTypeRef?
            var curSubrole: String?
            if AXUIElementCopyAttributeValue(currentFocused, kAXSubroleAttribute as CFString, &curSubroleRef) == .success {
                curSubrole = curSubroleRef as? String
            }
            if curSubrole == "AXSecureTextField" {
                return .secureInput
            }

            if !CFEqual(origEl, currentFocused) {
                if Self.isWebOrElectron(bundleID: snapshot.bundleID) {
                    var curRoleRef: CFTypeRef?
                    var curRole: String?
                    if AXUIElementCopyAttributeValue(currentFocused, kAXRoleAttribute as CFString, &curRoleRef) == .success {
                        curRole = curRoleRef as? String
                    }
                    if curRole != snapshot.focusedRole || curSubrole != snapshot.focusedSubrole {
                        return .fieldChanged
                    }
                } else {
                    return .fieldChanged
                }
            }
        }

        return nil
    }

    private static func isWebOrElectron(bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower.contains("chrome")
            || lower.contains("chromium")
            || lower.contains("brave")
            || lower.contains("edge")
            || lower.contains("arc")
            || lower.contains("opera")
            || lower.contains("vivaldi")
            || lower.contains("electron")
            || lower.contains("vscode")
            || lower.contains("slack")
            || lower.contains("discord")
            || lower.contains("notion")
            || lower.contains("figma")
            || lower.contains("obsidian")
    }

    private func reportAbort(failure: ContextCheckFailure, bundleID: String) {
        let bodyKey: String
        let reasonLog: String
        switch failure {
        case .appChangedOrTerminated:
            bodyKey = "snip.form.abortApp"
            reasonLog = "app_changed"
        case .windowChangedOrClosed:
            bodyKey = "snip.form.abortWindow"
            reasonLog = "window_changed"
        case .fieldChanged:
            bodyKey = "snip.form.abortField"
            reasonLog = "field_changed"
        case .secureInput:
            bodyKey = "snip.form.abortSecure"
            reasonLog = "secure_input"
        }
        kbLog("snippet-form: вставка отменена (\(reasonLog), \(bundleID))")
        AppBanner.shared.show(
            title: L10n.t("snip.form.abortTitle"),
            body: L10n.t(bodyKey),
            autoDismiss: 4.5
        )
    }
}
