import AppKit

/// Модальная/плавающая форма заполнения динамического сниппета с live-предпросмотром (KB-004).
/// Не сохраняет введённые пользователем значения на диск/в defaults и не пишет их в лог.
final class SnippetFormController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private let snippet: SnippetV2
    private let fields: [SnippetField]
    private var values: [String: String]
    private let onConfirm: (String) -> Void
    private let onCancel: () -> Void

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var finished = false

    private var textControls: [String: NSTextField] = [:]
    private var multilineControls: [String: NSTextView] = [:]
    private var dateControls: [String: NSDatePicker] = [:]
    private var choiceControls: [String: (pop: NSPopUpButton, options: [String])] = [:]

    private let previewTextView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let insertButton = NSButton(title: L10n.t("snip.form.insert"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t("snip.form.cancel"), target: nil, action: nil)

    private static let dateDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .current
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    init(
        snippet: SnippetV2,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.fields = snippet.resolvedFormFields()
        self.values = SnippetVariableResolver.initialFieldValues(for: snippet)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init()

        // Для полей типа `.date` сразу подставляем дату по умолчанию (или сегодняшнюю),
        // чтобы форма и предпросмотр сразу показывали актуальную дату.
        for field in fields where field.type == .date {
            let parsedDate = Self.parseInitialDate(field.defaultValue) ?? Date()
            if (values[field.key] ?? "").isEmpty {
                values[field.key] = Self.dateDisplayFormatter.string(from: parsedDate)
            }
        }
        // Для обязательного `.choice` выбираем первый пункт, если defaultValue пуст.
        for field in fields where field.type == .choice && !field.options.isEmpty {
            let cur = values[field.key] ?? ""
            if cur.isEmpty, field.required {
                values[field.key] = field.options[0]
            } else if !cur.isEmpty, !field.options.contains(cur) {
                values[field.key] = field.options[0]
            }
        }
    }

    deinit {
        removeKeyMonitor()
    }

    func show(nearCaretRect caretRect: NSRect?) {
        let p = buildPanel()
        self.panel = p

        positionPanel(p, nearCaretRect: caretRect)
        installKeyMonitor()
        updatePreviewAndValidation()

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        if let first = firstFocusableControl() {
            p.makeFirstResponder(first)
        }
    }

    func closeSilently() {
        finished = true
        removeKeyMonitor()
        wipeInMemoryValues()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func wipeInMemoryValues() {
        values.removeAll()
        for (_, tf) in textControls { tf.stringValue = "" }
        for (_, tv) in multilineControls { tv.string = "" }
        previewTextView.string = ""
    }

    // MARK: - UI Construction

    private func buildPanel() -> NSPanel {
        let title = L10n.t("snip.form.title", snippet.trigger)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = title
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Прокручиваемая область полей (безопасно при большом числе переменных).
        let fieldsStack = NSStackView()
        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = 8
        fieldsStack.translatesAutoresizingMaskIntoConstraints = false

        for field in fields {
            let row = buildFieldRow(field)
            fieldsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fieldsStack.widthAnchor).isActive = true
        }

        let fieldsScroll = NSScrollView()
        fieldsScroll.drawsBackground = false
        fieldsScroll.hasVerticalScroller = true
        fieldsScroll.autohidesScrollers = true
        fieldsScroll.borderType = .noBorder
        fieldsScroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(fieldsStack)
        fieldsScroll.documentView = doc

        NSLayoutConstraint.activate([
            fieldsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            fieldsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            fieldsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            fieldsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: fieldsScroll.contentView.widthAnchor),
        ])

        let estimatedFieldsHeight = fields.reduce(CGFloat(0)) { acc, field in
            acc + (field.type == .multiline ? 76 : 32) + 8
        }
        let maxFieldsHeight: CGFloat = 240
        let fieldsHeight = min(max(36, estimatedFieldsHeight), maxFieldsHeight)
        fieldsScroll.heightAnchor.constraint(equalToConstant: fieldsHeight).isActive = true

        // Предпросмотр (FR-4)
        let previewTitle = NSTextField(labelWithString: L10n.t("snip.form.preview"))
        previewTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        previewTitle.textColor = .secondaryLabelColor

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.font = .systemFont(ofSize: 12.5)
        previewTextView.textContainerInset = NSSize(width: 6, height: 6)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.textContainer?.widthTracksTextView = true

        let previewScroll = NSScrollView()
        previewScroll.documentView = previewTextView
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .bezelBorder
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = NSColor.controlBackgroundColor
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true

        // Статус валидации
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemOrange
        statusLabel.maximumNumberOfLines = 2

        // Кнопки
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        insertButton.bezelStyle = .rounded
        insertButton.keyEquivalent = "\r"
        insertButton.hasDestructiveAction = false
        insertButton.target = self
        insertButton.action = #selector(insertClicked)

        let buttonsRow = NSStackView(views: [NSView(), cancelButton, insertButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.alignment = .centerY

        mainStack.addArrangedSubview(fieldsScroll)
        mainStack.addArrangedSubview(previewTitle)
        mainStack.addArrangedSubview(previewScroll)
        mainStack.addArrangedSubview(statusLabel)
        mainStack.addArrangedSubview(buttonsRow)

        fieldsScroll.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        previewScroll.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        buttonsRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: 440),
        ])

        p.contentView = root
        p.layoutIfNeeded()
        return p
    }

    private func buildFieldRow(_ field: SnippetField) -> NSView {
        let labelText = field.required ? "\(field.displayLabel) *" : field.displayLabel
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 125).isActive = true

        let control: NSView
        switch field.type {
        case .text:
            let tf = NSTextField()
            tf.identifier = NSUserInterfaceItemIdentifier(field.key)
            tf.stringValue = values[field.key] ?? ""
            tf.placeholderString = field.required ? L10n.t("snip.form.requiredPh") : L10n.t("snip.form.optionalPh")
            tf.font = .systemFont(ofSize: 12.5)
            tf.delegate = self
            textControls[field.key] = tf
            control = tf

        case .multiline:
            let tv = NSTextView()
            tv.isEditable = true
            tv.isRichText = false
            tv.allowsUndo = true
            tv.font = .systemFont(ofSize: 12.5)
            tv.string = values[field.key] ?? ""
            tv.textContainerInset = NSSize(width: 4, height: 4)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
            tv.delegate = self
            multilineControls[field.key] = tv

            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = true
            sv.borderType = .bezelBorder
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.heightAnchor.constraint(equalToConstant: 72).isActive = true
            control = sv

        case .date:
            let dp = NSDatePicker()
            dp.datePickerStyle = .textFieldAndStepper
            dp.datePickerElements = .yearMonthDay
            dp.dateValue = Self.parseInitialDate(field.defaultValue) ?? Date()
            dp.identifier = NSUserInterfaceItemIdentifier(field.key)
            dp.target = self
            dp.action = #selector(datePickerChanged(_:))
            dateControls[field.key] = dp
            control = dp

        case .choice:
            if field.options.isEmpty {
                let tf = NSTextField()
                tf.identifier = NSUserInterfaceItemIdentifier(field.key)
                tf.stringValue = values[field.key] ?? ""
                tf.font = .systemFont(ofSize: 12.5)
                tf.delegate = self
                textControls[field.key] = tf
                control = tf
            } else {
                let pop = NSPopUpButton()
                var opts = field.options
                if !field.required && !opts.contains("") {
                    opts.insert("", at: 0)
                    pop.addItem(withTitle: L10n.t("snip.form.chooseNone"))
                    pop.addItems(withTitles: field.options)
                } else {
                    pop.addItems(withTitles: opts)
                }
                let cur = values[field.key] ?? ""
                if let idx = opts.firstIndex(of: cur) {
                    pop.selectItem(at: idx)
                } else {
                    pop.selectItem(at: 0)
                    values[field.key] = opts.first ?? ""
                }
                pop.identifier = NSUserInterfaceItemIdentifier(field.key)
                pop.target = self
                pop.action = #selector(choiceChanged(_:))
                choiceControls[field.key] = (pop, opts)
                control = pop
            }
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = field.type == .multiline ? .top : .centerY
        row.spacing = 10
        return row
    }

    private func firstFocusableControl() -> NSView? {
        for field in fields {
            if let tf = textControls[field.key] { return tf }
            if let tv = multilineControls[field.key] { return tv }
            if let dp = dateControls[field.key] { return dp }
            if let ch = choiceControls[field.key]?.pop { return ch }
        }
        return nil
    }

    private func positionPanel(_ p: NSPanel, nearCaretRect caretRect: NSRect?) {
        let size = p.frame.size
        let targetPoint: NSPoint
        let visibleFrame: NSRect
        if let caretRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? NSScreen.main {
            visibleFrame = screen.visibleFrame
            targetPoint = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 8)
            var origin = targetPoint
            if origin.y < visibleFrame.minY + 12 {
                origin.y = min(visibleFrame.maxY - size.height - 12, caretRect.maxY + 8)
            }
            origin.x = min(max(origin.x, visibleFrame.minX + 12), visibleFrame.maxX - size.width - 12)
            origin.y = min(max(origin.y, visibleFrame.minY + 12), visibleFrame.maxY - size.height - 12)
            p.setFrameOrigin(origin)
            return
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        p.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2 + 40
        ))
    }

    // MARK: - Controls & Live Preview

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField,
              let key = tf.identifier?.rawValue else { return }
        values[key] = tf.stringValue
        updatePreviewAndValidation()
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        for (key, view) in multilineControls where view === tv {
            values[key] = tv.string
            break
        }
        updatePreviewAndValidation()
    }

    @objc private func datePickerChanged(_ sender: NSDatePicker) {
        guard let key = sender.identifier?.rawValue else { return }
        values[key] = Self.dateDisplayFormatter.string(from: sender.dateValue)
        updatePreviewAndValidation()
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,
              let entry = choiceControls[key] else { return }
        let idx = sender.indexOfSelectedItem
        if idx >= 0 && idx < entry.options.count {
            values[key] = entry.options[idx]
        }
        updatePreviewAndValidation()
    }

    private func currentRenderResult() -> SnippetRenderResult {
        // Буфер обмена читаем ТОЛЬКО при явном `allowClipboard == true` на самом шаблоне.
        let clipReader: (() -> String?)? = snippet.allowClipboard ? {
            NSPasteboard.general.string(forType: .string)
        } : nil

        return SnippetVariableResolver.resolve(
            snippet: snippet,
            fieldValues: values,
            fallbackToDefaults: false,
            clipboardReader: clipReader
        )
    }

    private func updatePreviewAndValidation() {
        let result = currentRenderResult()
        previewTextView.string = result.text

        var notes: [String] = []
        if !result.missingRequiredFieldKeys.isEmpty {
            let labels = result.missingRequiredFieldKeys.map { key in
                fields.first(where: { $0.key == key })?.displayLabel ?? key
            }
            notes.append(L10n.t("snip.form.missingRequired", labels.joined(separator: ", ")))
        }
        if result.clipboardBlocked {
            notes.append(L10n.t("snip.form.clipboardBlocked"))
        }
        if result.missingRequiredFieldKeys.isEmpty && result.text.isEmpty {
            notes.append(L10n.t("snip.form.emptyResult"))
        }

        statusLabel.stringValue = notes.joined(separator: " • ")
        statusLabel.isHidden = notes.isEmpty
        insertButton.isEnabled = result.canInsert
    }

    // MARK: - Actions & Window Lifecycle

    @objc private func insertClicked() {
        guard !finished else { return }
        let result = currentRenderResult()
        guard result.canInsert else {
            updatePreviewAndValidation()
            NSSound.beep()
            return
        }
        let textToInsert = result.text
        finished = true
        removeKeyMonitor()
        wipeInMemoryValues()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onConfirm(textToInsert)
    }

    @objc private func cancelClicked() {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        wipeInMemoryValues()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onCancel()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        wipeInMemoryValues()
        panel = nil
        onCancel()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 53 { // Escape
                self.cancelClicked()
                return nil
            }
            if event.keyCode == 36 && event.modifierFlags.contains(.command) { // Cmd+Return
                if self.insertButton.isEnabled {
                    self.insertClicked()
                } else {
                    NSSound.beep()
                }
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private static func parseInitialDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for fmt in ["dd.MM.yyyy", "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy"] {
            let f = DateFormatter()
            f.locale = .autoupdatingCurrent
            f.timeZone = .current
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }
}
