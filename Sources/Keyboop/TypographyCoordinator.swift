import AppKit
import ApplicationServices
import Carbon

/// Запись для точной отмены последнего автоматического типографического преобразования (FR-09).
struct TypographyUndoEntry: Equatable {
    let bundleID: String
    let originalSuffix: String
    let replacedSuffix: String
    let createdAt: Date
}

/// Координатор умной типографики KB-021 (§5):
/// - ведёт локальный скользящий буфер хвоста без блокирующих AX-вызовов в `CGEventTap`
/// - запускает правила типографики строго ПОСЛЕ раскладки и опечаток
/// - обеспечивает безопасную отмену (FR-09) и ручное форматирование выделения с предпросмотром (FR-07)
final class TypographyCoordinator {
    static let shared = TypographyCoordinator()

    private let store = TypographySettingsStore.shared
    private let maxTailChars = 160

    private var typingTail = ""
    private var lastUndoEntry: TypographyUndoEntry?
    private var suppressUntilResetOrNewToken = false
    private var previewController: TypographyPreviewPanelController?
    private var isApplying = false

    // MARK: - Синхронизация с вводом (main queue)

    func appendTypedText(_ s: String) {
        guard !s.isEmpty else { return }
        typingTail += s
        trimTail()
        // Если пользователь продолжает печатать после отмены/исправления: проверяем актуальность undo.
        invalidateUndoIfDiverged()
        suppressUntilResetOrNewToken = false
    }

    func appendBoundary(_ ws: String) {
        guard !ws.isEmpty else { return }
        typingTail += ws
        trimTail()
        invalidateUndoIfDiverged()
        suppressUntilResetOrNewToken = false
    }

    func applyBackspace(eraseAllWord: Bool) {
        if eraseAllWord {
            resetContext()
            return
        }
        if !typingTail.isEmpty {
            typingTail.removeLast()
        } else {
            lastUndoEntry = nil
        }
        invalidateUndoIfDiverged()
    }

    func replaceTail(oldSuffix: String, newSuffix: String) {
        if !oldSuffix.isEmpty, typingTail.hasSuffix(oldSuffix) {
            typingTail.removeLast(oldSuffix.count)
            typingTail += newSuffix
        } else {
            typingTail += newSuffix
        }
        trimTail()
        invalidateUndoIfDiverged()
    }

    func resetContext() {
        typingTail = ""
        lastUndoEntry = nil
        suppressUntilResetOrNewToken = false
    }

    private func trimTail() {
        if typingTail.count > maxTailChars {
            typingTail.removeFirst(typingTail.count - maxTailChars)
        }
    }

    private func invalidateUndoIfDiverged() {
        guard let entry = lastUndoEntry else { return }
        if !typingTail.hasSuffix(entry.replacedSuffix) {
            lastUndoEntry = nil
        }
    }

    // MARK: - Автоматическая обработка при наборе

    /// Проверяет и применяет типографические правила к хвосту набора.
    /// Вызывается ПОСЛЕ завершения проверки раскладки и опечаток (§5 приоритет 5).
    func evaluateTypingIfNeeded(
        resolvedContext: ResolvedInputContext,
        activeLayoutHint: String?,
        beginSynthetic: () -> Void,
        endSynthetic: @escaping () -> Void
    ) {
        guard resolvedContext.effectiveTypography,
              !Pause.active,
              !NSApp.isActive,
              !SnippetInsertionCoordinator.shared.isFormActive,
              !suppressUntilResetOrNewToken,
              !isApplying,
              !typingTail.isEmpty else { return }

        guard store.enabled else { return }

        let context = TypographyContext(
            mode: .typing,
            languageMode: store.language,
            activeLayoutHint: activeLayoutHint,
            bundleID: resolvedContext.bundleID,
            rules: store.effectiveRules()
        )

        guard let patch = TypographyEngine.analyzeTypingTail(typingTail, context: context) else { return }
        guard SecureInputPolicy.canWrite("typography-auto -\(patch.deleteCount)+\(patch.replacementSuffix.count)") else {
            return
        }

        isApplying = true
        beginSynthetic()

        let origSuffix = patch.originalSuffix
        let replSuffix = patch.replacementSuffix
        let bundleID = resolvedContext.bundleID

        TextReplacer.replace(deleteCount: patch.deleteCount, with: replSuffix, firstKeySettleMicros: 35_000) { [weak self] in
            guard let self else {
                endSynthetic()
                return
            }
            if self.typingTail.hasSuffix(origSuffix) {
                self.typingTail.removeLast(origSuffix.count)
                self.typingTail += replSuffix
                self.trimTail()
            }
            self.lastUndoEntry = TypographyUndoEntry(
                bundleID: bundleID,
                originalSuffix: origSuffix,
                replacedSuffix: replSuffix,
                createdAt: Date()
            )
            self.isApplying = false
            kbLog("typography: авто -\(patch.deleteCount)+\(replSuffix.count) симв. (\(patch.appliedRuleIDs.map(\.rawValue).joined(separator: ",")))")
            endSynthetic()
        }
    }

    // MARK: - Безопасная отмена последнего исправления (FR-09)

    func undoLastTypography(
        currentBundleID: String,
        beginSynthetic: () -> Void,
        endSynthetic: @escaping () -> Void
    ) -> Bool {
        guard !NSApp.isActive,
              !isApplying,
              let entry = lastUndoEntry,
              entry.bundleID == currentBundleID,
              typingTail.hasSuffix(entry.replacedSuffix) else {
            return false
        }

        guard SecureInputPolicy.canWrite("typography-undo -\(entry.replacedSuffix.count)+\(entry.originalSuffix.count)") else {
            return false
        }

        isApplying = true
        suppressUntilResetOrNewToken = true
        lastUndoEntry = nil
        beginSynthetic()

        TextReplacer.replace(
            deleteCount: entry.replacedSuffix.count,
            with: entry.originalSuffix,
            firstKeySettleMicros: 35_000
        ) { [weak self] in
            guard let self else {
                endSynthetic()
                return
            }
            if self.typingTail.hasSuffix(entry.replacedSuffix) {
                self.typingTail.removeLast(entry.replacedSuffix.count)
                self.typingTail += entry.originalSuffix
                self.trimTail()
            }
            self.isApplying = false
            kbLog("typography: отмена -\(entry.replacedSuffix.count)+\(entry.originalSuffix.count) симв.")
            endSynthetic()
        }
        return true
    }

    // MARK: - Ручное форматирование выделенного текста (FR-07)

    func formatSelectedText(
        activeLayoutHint: String?,
        beginSynthetic: @escaping () -> Void,
        endSynthetic: @escaping () -> Void
    ) {
        if IsSecureEventInputEnabled() {
            AppBanner.shared.show(
                title: L10n.t("typo.sel.title"),
                body: L10n.t("typo.sel.secure"),
                autoDismiss: 3.5
            )
            return
        }
        guard !NSApp.isActive else { return }

        guard let (selected, writeBack) = SelectionText.readAXOnly(), !selected.isEmpty else {
            let bodyKey = SelectionText.lastReadRefusedMultiline ? "typo.sel.geckoMultiline" : "typo.sel.noSelection"
            AppBanner.shared.show(
                title: L10n.t("typo.sel.title"),
                body: L10n.t(bodyKey),
                autoDismiss: 3.5
            )
            kbLog("typography-sel: выделение недоступно через AX (буфер обмена не трогаем)")
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? Engine.frontmostBundleID()
        let context = TypographyContext(
            mode: .selection,
            languageMode: store.language,
            activeLayoutHint: activeLayoutHint,
            bundleID: bundleID,
            rules: store.effectiveRules(),
            allowUnsafeProseInMixed: true
        )

        let result = TypographyEngine.analyze(selected, context: context)
        guard result.changed else {
            AppBanner.shared.show(
                title: L10n.t("typo.sel.title"),
                body: L10n.t("typo.sel.noChanges"),
                autoDismiss: 2.5
            )
            return
        }

        let needsPreview = store.showSelectionPreview && (selected.contains("\n") || result.operations.count >= 2 || selected.count > 80)
        if !needsPreview {
            applySelectionReplacement(
                result: result,
                writeBack: writeBack,
                beginSynthetic: beginSynthetic,
                endSynthetic: endSynthetic
            )
            return
        }

        let caretRect = CaretLocator.caretScreenRect()
        let controller = TypographyPreviewPanelController(
            originalText: result.originalText,
            transformedText: result.transformedText,
            appliedRules: result.appliedRuleIDs,
            onApply: { [weak self, weak frontApp] in
                self?.previewController = nil
                self?.restoreAppFocusAndApply(
                    targetApp: frontApp,
                    result: result,
                    writeBack: writeBack,
                    beginSynthetic: beginSynthetic,
                    endSynthetic: endSynthetic
                )
            },
            onCancel: { [weak self, weak frontApp] in
                self?.previewController = nil
                frontApp?.activate(options: [])
            }
        )
        previewController = controller
        controller.show(nearCaretRect: caretRect)
    }

    private func restoreAppFocusAndApply(
        targetApp: NSRunningApplication?,
        result: TypographyResult,
        writeBack: ((String) -> Bool)?,
        beginSynthetic: @escaping () -> Void,
        endSynthetic: @escaping () -> Void
    ) {
        guard let targetApp, !targetApp.isTerminated else { return }
        let targetPid = targetApp.processIdentifier
        targetApp.activate(options: [])

        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        func poll() {
            let currentPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if currentPid == targetPid && !NSApp.isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else { return }
                    self?.applySelectionReplacement(
                        result: result,
                        writeBack: writeBack,
                        beginSynthetic: beginSynthetic,
                        endSynthetic: endSynthetic
                    )
                }
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }

    private func applySelectionReplacement(
        result: TypographyResult,
        writeBack: ((String) -> Bool)?,
        beginSynthetic: @escaping () -> Void,
        endSynthetic: @escaping () -> Void
    ) {
        guard SecureInputPolicy.canWrite("typography-sel \(result.transformedText.count) симв.") else {
            AppBanner.shared.show(
                title: L10n.t("typo.sel.title"),
                body: L10n.t("typo.sel.secure"),
                autoDismiss: 3.5
            )
            return
        }
        resetContext()
        beginSynthetic()
        let viaAX = writeBack?(result.transformedText) ?? false
        if viaAX {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                endSynthetic()
            }
        } else {
            TextReplacer.insert(result.transformedText) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    endSynthetic()
                }
            }
        }
        kbLog("typography-sel: \(result.originalText.count)→\(result.transformedText.count) симв. (\(viaAX ? "AX" : "insert"))")
    }
}

/// Компактное окно предпросмотра для ручного форматирования выделения (FR-07).
final class TypographyPreviewPanelController: NSObject, NSWindowDelegate {
    private let originalText: String
    private let transformedText: String
    private let appliedRules: [TypographyRuleID]
    private let onApply: () -> Void
    private let onCancel: () -> Void

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var finished = false

    init(
        originalText: String,
        transformedText: String,
        appliedRules: [TypographyRuleID],
        onApply: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalText = originalText
        self.transformedText = transformedText
        self.appliedRules = appliedRules
        self.onApply = onApply
        self.onCancel = onCancel
        super.init()
    }

    deinit {
        removeKeyMonitor()
    }

    func show(nearCaretRect caretRect: NSRect?) {
        let p = buildPanel()
        self.panel = p
        positionPanel(p, nearCaretRect: caretRect)
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = L10n.t("typo.preview.title")
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let summary = NSTextField(labelWithString: L10n.t("typo.preview.summary", appliedRules.count))
        summary.font = .systemFont(ofSize: 12, weight: .semibold)
        summary.textColor = .secondaryLabelColor

        func makeBox(titleKey: String, content: String, dimmed: Bool) -> NSView {
            let lbl = NSTextField(labelWithString: L10n.t(titleKey))
            lbl.font = .systemFont(ofSize: 11, weight: .semibold)
            lbl.textColor = .secondaryLabelColor

            let tv = NSTextView()
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.font = .systemFont(ofSize: 12.5)
            tv.textColor = dimmed ? .secondaryLabelColor : .labelColor
            tv.string = content
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true

            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = true
            sv.borderType = .bezelBorder
            sv.drawsBackground = true
            sv.backgroundColor = NSColor.controlBackgroundColor
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.heightAnchor.constraint(equalToConstant: 96).isActive = true

            let stack = NSStackView(views: [lbl, sv])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            sv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return stack
        }

        let beforeBox = makeBox(titleKey: "typo.preview.before", content: originalText, dimmed: true)
        let afterBox = makeBox(titleKey: "typo.preview.after", content: transformedText, dimmed: false)

        let cancelBtn = NSButton(title: L10n.t("sites.ed.cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        let applyBtn = NSButton(title: L10n.t("typo.preview.apply"), target: self, action: #selector(applyClicked))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"

        let btnRow = NSStackView(views: [NSView(), cancelBtn, applyBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let main = NSStackView(views: [summary, beforeBox, afterBox, btnRow])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false

        beforeBox.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        afterBox.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        btnRow.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true

        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: 480),
        ])

        p.contentView = root
        p.layoutIfNeeded()
        return p
    }

    private func positionPanel(_ p: NSPanel, nearCaretRect caretRect: NSRect?) {
        let size = p.frame.size
        if let caretRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            var x = caretRect.minX
            var y = caretRect.minY - size.height - 8
            if y < vf.minY + 12 { y = min(vf.maxY - size.height - 12, caretRect.maxY + 8) }
            x = min(max(x, vf.minX + 12), vf.maxX - size.width - 12)
            y = min(max(y, vf.minY + 12), vf.maxY - size.height - 12)
            p.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 40))
    }

    @objc private func applyClicked() {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onApply()
    }

    @objc private func cancelClicked() {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onCancel()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel = nil
        onCancel()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 53 { self.cancelClicked(); return nil }
            if event.keyCode == 36 { self.applyClicked(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
