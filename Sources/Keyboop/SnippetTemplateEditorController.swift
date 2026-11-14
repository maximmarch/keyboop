import AppKit

/// Редактор сниппета/динамического шаблона KB-004 (sheet в окне настроек).
/// Поддерживает переключение «Обычный текст» ↔ «Шаблон с переменными», вставку переменных,
/// настройку пользовательских полей, подсветку ошибок до сохранения и live-предпросмотр.
final class SnippetTemplateEditorController: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private let editingID: UUID?
    private let createdAt: Date
    private let onSave: (SnippetV2) -> String?

    private var sheetWindow: NSWindow?
    private weak var hostWindow: NSWindow?
    private var completionHandler: (() -> Void)?

    private var kind: SnippetKind
    private var fieldOrder: [String] = []
    private var fieldsByKey: [String: SnippetField] = [:]

    private let triggerField = NSTextField()
    private let kindControl = NSSegmentedControl()
    private let enabledSwitch = NSSwitch()
    private let privateSwitch = NSSwitch()
    private let allowClipboardSwitch = NSSwitch()
    private var allowClipboardContainer: NSView?

    private let insertVarButton = NSButton(title: L10n.t("snip.tpl.addVar"), target: nil, action: nil)
    private let bodyTextView = NSTextView()
    private var isApplyingHighlight = false

    private var fieldsSectionContainer: NSView?
    private let fieldsListStack = NSStackView()
    private var fieldsEmptyLabel = NSTextField(labelWithString: "")

    private let previewTextView = NSTextView()
    private let diagnosticLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: L10n.t("sites.ed.save"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t("sites.ed.cancel"), target: nil, action: nil)

    init(editing: SnippetV2?, onSave: @escaping (SnippetV2) -> String?) {
        self.editingID = editing?.id
        self.createdAt = editing?.createdAt ?? Date()
        self.kind = editing?.kind ?? .template
        self.onSave = onSave
        super.init()

        if let editing {
            for field in editing.fields.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                fieldsByKey[field.key] = field
                if !fieldOrder.contains(field.key) {
                    fieldOrder.append(field.key)
                }
            }
        }

        configureControls(editing: editing)
    }

    private func configureControls(editing: SnippetV2?) {
        triggerField.placeholderString = L10n.t("snip.phTrigger")
        triggerField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        triggerField.stringValue = editing?.trigger ?? ""
        triggerField.delegate = self

        kindControl.segmentCount = 2
        kindControl.setLabel(L10n.t("snip.tpl.kindPlain"), forSegment: 0)
        kindControl.setLabel(L10n.t("snip.tpl.kindTemplate"), forSegment: 1)
        kindControl.selectedSegment = (kind == .plain) ? 0 : 1
        kindControl.target = self
        kindControl.action = #selector(kindChanged)

        enabledSwitch.state = (editing?.enabled ?? true) ? .on : .off
        privateSwitch.state = (editing?.isPrivate ?? false) ? .on : .off
        allowClipboardSwitch.state = (editing?.allowClipboard ?? false) ? .on : .off
        allowClipboardSwitch.target = self
        allowClipboardSwitch.action = #selector(flagChanged)

        insertVarButton.bezelStyle = .rounded
        insertVarButton.target = self
        insertVarButton.action = #selector(showInsertVarMenu(_:))

        bodyTextView.isEditable = true
        bodyTextView.isRichText = false
        bodyTextView.allowsUndo = true
        bodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        bodyTextView.isAutomaticDashSubstitutionEnabled = false
        bodyTextView.isAutomaticTextReplacementEnabled = false
        bodyTextView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        bodyTextView.textContainerInset = NSSize(width: 6, height: 6)
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.string = editing?.body ?? ""
        bodyTextView.delegate = self

        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.drawsBackground = false
        previewTextView.font = .systemFont(ofSize: 12.5)
        previewTextView.textContainerInset = NSSize(width: 6, height: 6)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = false
        previewTextView.textContainer?.widthTracksTextView = true

        diagnosticLabel.font = .systemFont(ofSize: 11.5)
        diagnosticLabel.textColor = .systemRed

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
    }

    func presentSheet(over window: NSWindow, onDismiss: @escaping () -> Void) {
        self.hostWindow = window
        self.completionHandler = onDismiss

        let sheet = buildSheetWindow()
        self.sheetWindow = sheet

        syncFieldsFromTemplate()
        rebuildFieldsUI()
        updateKindVisibility()
        refreshValidationAndPreview()

        window.beginSheet(sheet) { [weak self] _ in
            self?.sheetWindow = nil
            let handler = self?.completionHandler
            self?.completionHandler = nil
            handler?()
        }
        sheet.makeFirstResponder(triggerField.stringValue.isEmpty ? triggerField : bodyTextView)
    }

    private func buildSheetWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = editingID == nil ? L10n.t("snip.tpl.addTitle") : L10n.t("snip.tpl.editTitle")

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Строка 1: Триггер + Тип
        let trigLbl = NSTextField(labelWithString: L10n.t("snip.tpl.trigger"))
        trigLbl.font = .systemFont(ofSize: 12, weight: .medium)
        triggerField.translatesAutoresizingMaskIntoConstraints = false
        triggerField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let kindLbl = NSTextField(labelWithString: L10n.t("snip.tpl.kind"))
        kindLbl.font = .systemFont(ofSize: 12, weight: .medium)

        let topRow = NSStackView(views: [trigLbl, triggerField, NSView(), kindLbl, kindControl])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        // Строка 2: Флаги (Включён, Приватный, Разрешить буфер)
        let enLbl = NSTextField(labelWithString: L10n.t("snip.tpl.enabled"))
        enLbl.font = .systemFont(ofSize: 12)
        let enBox = NSStackView(views: [enabledSwitch, enLbl])
        enBox.orientation = .horizontal; enBox.spacing = 6

        let privLbl = NSTextField(labelWithString: L10n.t("snip.tpl.private"))
        privLbl.font = .systemFont(ofSize: 12)
        let privBox = NSStackView(views: [privateSwitch, privLbl])
        privBox.orientation = .horizontal; privBox.spacing = 6

        let clipLbl = NSTextField(labelWithString: L10n.t("snip.tpl.allowClipboard"))
        clipLbl.font = .systemFont(ofSize: 12)
        let clipBox = NSStackView(views: [allowClipboardSwitch, clipLbl])
        clipBox.orientation = .horizontal; clipBox.spacing = 6
        allowClipboardContainer = clipBox

        let flagsRow = NSStackView(views: [enBox, privBox, clipBox, NSView()])
        flagsRow.orientation = .horizontal
        flagsRow.alignment = .centerY
        flagsRow.spacing = 16

        // Заголовок редактора текста + кнопка «Добавить переменную»
        let bodyLbl = NSTextField(labelWithString: L10n.t("snip.tpl.body"))
        bodyLbl.font = .systemFont(ofSize: 12, weight: .semibold)
        let bodyHeader = NSStackView(views: [bodyLbl, NSView(), insertVarButton])
        bodyHeader.orientation = .horizontal
        bodyHeader.alignment = .centerY

        let bodyScroll = NSScrollView()
        bodyScroll.documentView = bodyTextView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        // Поля формы
        let fieldsTitle = NSTextField(labelWithString: L10n.t("snip.tpl.fieldsHeader"))
        fieldsTitle.font = .systemFont(ofSize: 12, weight: .semibold)

        fieldsListStack.orientation = .vertical
        fieldsListStack.alignment = .leading
        fieldsListStack.spacing = 6
        fieldsListStack.translatesAutoresizingMaskIntoConstraints = false

        fieldsEmptyLabel = NSTextField(labelWithString: L10n.t("snip.tpl.noFields"))
        fieldsEmptyLabel.font = .systemFont(ofSize: 11.5)
        fieldsEmptyLabel.textColor = .secondaryLabelColor

        let fieldsDoc = NSView()
        fieldsDoc.translatesAutoresizingMaskIntoConstraints = false
        fieldsDoc.addSubview(fieldsListStack)

        let fieldsScroll = NSScrollView()
        fieldsScroll.documentView = fieldsDoc
        fieldsScroll.hasVerticalScroller = true
        fieldsScroll.autohidesScrollers = true
        fieldsScroll.borderType = .bezelBorder
        fieldsScroll.drawsBackground = true
        fieldsScroll.backgroundColor = NSColor.controlBackgroundColor
        fieldsScroll.translatesAutoresizingMaskIntoConstraints = false
        fieldsScroll.heightAnchor.constraint(equalToConstant: 155).isActive = true

        NSLayoutConstraint.activate([
            fieldsListStack.topAnchor.constraint(equalTo: fieldsDoc.topAnchor, constant: 6),
            fieldsListStack.leadingAnchor.constraint(equalTo: fieldsDoc.leadingAnchor, constant: 6),
            fieldsListStack.trailingAnchor.constraint(equalTo: fieldsDoc.trailingAnchor, constant: -6),
            fieldsListStack.bottomAnchor.constraint(equalTo: fieldsDoc.bottomAnchor, constant: -6),
            fieldsDoc.widthAnchor.constraint(equalTo: fieldsScroll.contentView.widthAnchor),
        ])

        let fieldsContainer = NSStackView(views: [fieldsTitle, fieldsEmptyLabel, fieldsScroll])
        fieldsContainer.orientation = .vertical
        fieldsContainer.alignment = .leading
        fieldsContainer.spacing = 6
        fieldsScroll.widthAnchor.constraint(equalTo: fieldsContainer.widthAnchor).isActive = true
        fieldsSectionContainer = fieldsContainer

        // Предпросмотр
        let previewLbl = NSTextField(labelWithString: L10n.t("snip.form.preview"))
        previewLbl.font = .systemFont(ofSize: 12, weight: .semibold)

        let previewScroll = NSScrollView()
        previewScroll.documentView = previewTextView
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .bezelBorder
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = NSColor.controlBackgroundColor
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true

        // Кнопки
        let btnRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        for v in [topRow, flagsRow, bodyHeader, bodyScroll, fieldsContainer, previewLbl, previewScroll, diagnosticLabel, btnRow] {
            mainStack.addArrangedSubview(v)
        }
        for v in [topRow, flagsRow, bodyHeader, bodyScroll, fieldsContainer, previewScroll, diagnosticLabel, btnRow] {
            v.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }

        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            root.widthAnchor.constraint(equalToConstant: 640),
        ])

        w.contentView = root
        return w
    }

    // MARK: - Actions & Sync

    @objc private func kindChanged() {
        kind = (kindControl.selectedSegment == 0) ? .plain : .template
        updateKindVisibility()
        syncFieldsFromTemplate()
        rebuildFieldsUI()
        refreshValidationAndPreview()
    }

    @objc private func flagChanged() {
        refreshValidationAndPreview()
    }

    private func updateKindVisibility() {
        let isTemplate = (kind == .template)
        insertVarButton.isHidden = !isTemplate
        allowClipboardContainer?.isHidden = !isTemplate
        fieldsSectionContainer?.isHidden = !isTemplate
    }

    @objc private func showInsertVarMenu(_ sender: NSButton) {
        let menu = NSMenu()

        func addItem(_ title: String, _ token: String) {
            let item = NSMenuItem(title: title, action: #selector(insertVariableFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token
            menu.addItem(item)
        }

        addItem(L10n.t("snip.tpl.varDate"), "{{date}}")
        addItem(L10n.t("snip.tpl.varDateFmt"), "{{date:dd.MM.yyyy}}")
        addItem(L10n.t("snip.tpl.varTime"), "{{time}}")
        addItem(L10n.t("snip.tpl.varDateTime"), "{{datetime}}")
        addItem(L10n.t("snip.tpl.varClipboard"), "{{clipboard}}")
        menu.addItem(NSMenuItem.separator())
        let suggested = nextCustomVariableToken()
        addItem(L10n.t("snip.tpl.varCustom", suggested), "{{\(suggested)}}")

        let pt = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: pt, in: sender)
    }

    private func nextCustomVariableToken() -> String {
        let candidates = ["name", "topic", "company", "amount", "field"]
        let existing = Set(fieldOrder)
        for c in candidates where !existing.contains(c) { return c }
        var idx = 1
        while existing.contains("var_\(idx)") { idx += 1 }
        return "var_\(idx)"
    }

    @objc private func insertVariableFromMenu(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        if kind != .template {
            kind = .template
            kindControl.selectedSegment = 1
            updateKindVisibility()
        }
        let range = bodyTextView.selectedRange()
        bodyTextView.insertText(token, replacementRange: range)
        sheetWindow?.makeFirstResponder(bodyTextView)
    }

    private func syncFieldsFromTemplate() {
        guard kind == .template else { return }
        let parsed = SnippetTemplateParser.parse(bodyTextView.string)
        let present = parsed.fieldKeysInOrder
        let presentSet = Set(present)

        // Сохраняем текущий пользовательский порядок для сохранившихся ключей, новые добавляем в конец.
        var nextOrder = fieldOrder.filter { presentSet.contains($0) }
        for k in present where !nextOrder.contains(k) {
            nextOrder.append(k)
        }
        fieldOrder = nextOrder

        for (idx, k) in fieldOrder.enumerated() {
            var field = fieldsByKey[k] ?? SnippetField(key: k, label: k)
            field.sortOrder = idx
            fieldsByKey[k] = field
        }
    }

    private func rebuildFieldsUI() {
        for v in fieldsListStack.arrangedSubviews {
            fieldsListStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        fieldsEmptyLabel.isHidden = !fieldOrder.isEmpty

        for (idx, key) in fieldOrder.enumerated() {
            guard let field = fieldsByKey[key] else { continue }
            let row = makeFieldConfigRow(field, index: idx, total: fieldOrder.count)
            fieldsListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fieldsListStack.widthAnchor).isActive = true
        }
    }

    private func makeFieldConfigRow(_ field: SnippetField, index: Int, total: Int) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let keyBadge = NSTextField(labelWithString: "{{\(field.key)}}")
        keyBadge.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        keyBadge.textColor = .systemBlue
        keyBadge.translatesAutoresizingMaskIntoConstraints = false
        keyBadge.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let labelField = NSTextField()
        labelField.identifier = NSUserInterfaceItemIdentifier("fld_label:\(field.key)")
        labelField.placeholderString = L10n.t("snip.tpl.fldLabelPh")
        labelField.stringValue = field.label
        labelField.font = .systemFont(ofSize: 12)
        labelField.delegate = self
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let typePop = NSPopUpButton()
        typePop.identifier = NSUserInterfaceItemIdentifier("fld_type:\(field.key)")
        typePop.addItems(withTitles: [
            L10n.t("snip.tpl.typeText"),
            L10n.t("snip.tpl.typeMultiline"),
            L10n.t("snip.tpl.typeDate"),
            L10n.t("snip.tpl.typeChoice"),
        ])
        let typeOrder: [SnippetFieldType] = [.text, .multiline, .date, .choice]
        typePop.selectItem(at: typeOrder.firstIndex(of: field.type) ?? 0)
        typePop.target = self
        typePop.action = #selector(fieldTypeChanged(_:))
        typePop.translatesAutoresizingMaskIntoConstraints = false
        typePop.widthAnchor.constraint(equalToConstant: 112).isActive = true

        let defaultField = NSTextField()
        defaultField.identifier = NSUserInterfaceItemIdentifier("fld_def:\(field.key)")
        defaultField.placeholderString = L10n.t("snip.tpl.fldDefPh")
        defaultField.stringValue = field.defaultValue
        defaultField.font = .systemFont(ofSize: 12)
        defaultField.delegate = self

        let reqBtn = NSButton(checkboxWithTitle: L10n.t("snip.tpl.fldReq"), target: self, action: #selector(fieldRequiredToggled(_:)))
        reqBtn.identifier = NSUserInterfaceItemIdentifier("fld_req:\(field.key)")
        reqBtn.state = field.required ? .on : .off
        reqBtn.font = .systemFont(ofSize: 11.5)

        let upBtn = NSButton(title: "↑", target: self, action: #selector(moveFieldUp(_:)))
        upBtn.identifier = NSUserInterfaceItemIdentifier("fld_up:\(field.key)")
        upBtn.bezelStyle = .rounded
        upBtn.isEnabled = index > 0
        upBtn.translatesAutoresizingMaskIntoConstraints = false
        upBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let downBtn = NSButton(title: "↓", target: self, action: #selector(moveFieldDown(_:)))
        downBtn.identifier = NSUserInterfaceItemIdentifier("fld_dn:\(field.key)")
        downBtn.bezelStyle = .rounded
        downBtn.isEnabled = index < total - 1
        downBtn.translatesAutoresizingMaskIntoConstraints = false
        downBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let top = NSStackView(views: [keyBadge, labelField, typePop, defaultField, reqBtn, upBtn, downBtn])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        container.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        if field.type == .choice {
            let optLbl = NSTextField(labelWithString: L10n.t("snip.tpl.fldOptions"))
            optLbl.font = .systemFont(ofSize: 11)
            optLbl.textColor = .secondaryLabelColor
            optLbl.translatesAutoresizingMaskIntoConstraints = false
            optLbl.widthAnchor.constraint(equalToConstant: 92).isActive = true

            let optField = NSTextField()
            optField.identifier = NSUserInterfaceItemIdentifier("fld_opts:\(field.key)")
            optField.placeholderString = L10n.t("snip.tpl.fldOptionsPh")
            optField.stringValue = field.options.joined(separator: ", ")
            optField.font = .systemFont(ofSize: 11.5)
            optField.delegate = self

            let optRow = NSStackView(views: [optLbl, optField])
            optRow.orientation = .horizontal
            optRow.alignment = .centerY
            optRow.spacing = 6
            container.addArrangedSubview(optRow)
            optRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        return container
    }

    // MARK: - Field Edits & Reordering

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        if tf === triggerField {
            refreshValidationAndPreview()
            return
        }
        guard let rawId = tf.identifier?.rawValue else { return }
        if rawId.hasPrefix("fld_label:") {
            let key = String(rawId.dropFirst("fld_label:".count))
            fieldsByKey[key]?.label = tf.stringValue
        } else if rawId.hasPrefix("fld_def:") {
            let key = String(rawId.dropFirst("fld_def:".count))
            fieldsByKey[key]?.defaultValue = tf.stringValue
            refreshValidationAndPreview()
        } else if rawId.hasPrefix("fld_opts:") {
            let key = String(rawId.dropFirst("fld_opts:".count))
            let items = tf.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            fieldsByKey[key]?.options = items
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === bodyTextView else { return }
        let oldOrder = fieldOrder
        syncFieldsFromTemplate()
        if fieldOrder != oldOrder {
            rebuildFieldsUI()
        }
        refreshValidationAndPreview()
    }

    @objc private func fieldTypeChanged(_ sender: NSPopUpButton) {
        guard let rawId = sender.identifier?.rawValue,
              rawId.hasPrefix("fld_type:") else { return }
        let key = String(rawId.dropFirst("fld_type:".count))
        let typeOrder: [SnippetFieldType] = [.text, .multiline, .date, .choice]
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < typeOrder.count else { return }
        fieldsByKey[key]?.type = typeOrder[idx]
        rebuildFieldsUI()
        refreshValidationAndPreview()
    }

    @objc private func fieldRequiredToggled(_ sender: NSButton) {
        guard let rawId = sender.identifier?.rawValue,
              rawId.hasPrefix("fld_req:") else { return }
        let key = String(rawId.dropFirst("fld_req:".count))
        fieldsByKey[key]?.required = (sender.state == .on)
    }

    @objc private func moveFieldUp(_ sender: NSButton) {
        guard let rawId = sender.identifier?.rawValue,
              rawId.hasPrefix("fld_up:") else { return }
        let key = String(rawId.dropFirst("fld_up:".count))
        guard let idx = fieldOrder.firstIndex(of: key), idx > 0 else { return }
        fieldOrder.swapAt(idx, idx - 1)
        normalizeFieldOrders()
        rebuildFieldsUI()
    }

    @objc private func moveFieldDown(_ sender: NSButton) {
        guard let rawId = sender.identifier?.rawValue,
              rawId.hasPrefix("fld_dn:") else { return }
        let key = String(rawId.dropFirst("fld_dn:".count))
        guard let idx = fieldOrder.firstIndex(of: key), idx < fieldOrder.count - 1 else { return }
        fieldOrder.swapAt(idx, idx + 1)
        normalizeFieldOrders()
        rebuildFieldsUI()
    }

    private func normalizeFieldOrders() {
        for (idx, k) in fieldOrder.enumerated() {
            fieldsByKey[k]?.sortOrder = idx
        }
    }

    // MARK: - Syntax Highlighting, Diagnostics & Preview

    private func buildDraftSnippet() -> SnippetV2 {
        let orderedFields = fieldOrder.enumerated().compactMap { idx, key -> SnippetField? in
            guard var f = fieldsByKey[key] else { return nil }
            f.sortOrder = idx
            return f
        }
        return SnippetV2(
            id: editingID ?? UUID(),
            trigger: triggerField.stringValue.trimmingCharacters(in: .whitespaces),
            kind: kind,
            body: bodyTextView.string,
            fields: orderedFields,
            sortOrder: 0,
            enabled: enabledSwitch.state == .on,
            allowClipboard: allowClipboardSwitch.state == .on,
            isPrivate: privateSwitch.state == .on,
            createdAt: createdAt,
            updatedAt: Date(),
            schemaVersion: SnippetV2.currentSchemaVersion
        )
    }

    private func applySyntaxHighlight(parsed: ParsedSnippetTemplate) {
        guard let storage = bodyTextView.textStorage, !isApplyingHighlight else { return }
        isApplyingHighlight = true
        defer { isApplyingHighlight = false }

        let text = bodyTextView.string
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.removeAttribute(.underlineStyle, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: fullRange)

        if kind == .template {
            for token in parsed.tokens {
                let range: Range<String.Index>?
                switch token {
                case .builtin(let b): range = b.range
                case .field(_, let r): range = r
                case .text: range = nil
                }
                if let range {
                    let nsRange = NSRange(range, in: text)
                    if nsRange.location + nsRange.length <= storage.length {
                        storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: nsRange)
                    }
                }
            }
            for diag in parsed.diagnostics {
                let nsRange = NSRange(diag.range, in: text)
                if nsRange.location + nsRange.length <= storage.length {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: nsRange)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
                }
            }
        }
        storage.endEditing()
    }

    private func refreshValidationAndPreview() {
        let draft = buildDraftSnippet()
        let parsed = SnippetTemplateParser.parse(draft.body)
        applySyntaxHighlight(parsed: parsed)

        var errors: [String] = []
        let trig = draft.trigger
        if trig.isEmpty {
            errors.append(L10n.t("snip.tpl.errEmptyTrigger"))
        } else if trig.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            errors.append(L10n.t("snip.tpl.errSpaceTrigger"))
        } else if draft.enabled,
                  let conflict = SnippetStore.shared.conflictingActiveSnippet(forTrigger: trig, excludingID: editingID) {
            errors.append(L10n.t("snip.tpl.errDupTrigger", conflict.trigger))
        }

        if kind == .template && !parsed.isValid {
            let messages = parsed.diagnostics.prefix(2).map(Self.localizedDiagnostic)
            errors.append(contentsOf: messages)
        }

        // Предпросмотр (в настройках не читаем реальный буфер обмена; показываем явный маркер)
        if kind == .plain {
            previewTextView.string = SnippetVariableResolver.sanitize(draft.body)
        } else if parsed.isValid {
            let res = SnippetVariableResolver.resolve(
                snippet: draft,
                fieldValues: [:],
                fallbackToDefaults: true,
                clipboardReader: { L10n.t("snip.tpl.clipboardPreviewSample") }
            )
            previewTextView.string = res.text
            if res.clipboardBlocked {
                errors.append(L10n.t("snip.tpl.warnClipboardOff"))
            }
        } else {
            previewTextView.string = ""
        }

        // clipboardBlocked — это предупреждение, не блокирует сохранение, если синтаксис и триггер валидны
        let hasHardError = trig.isEmpty
            || trig.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || (draft.enabled && SnippetStore.shared.conflictingActiveSnippet(forTrigger: trig, excludingID: editingID) != nil)
            || (kind == .template && !parsed.isValid)

        diagnosticLabel.stringValue = errors.joined(separator: "\n")
        diagnosticLabel.textColor = hasHardError ? .systemRed : .systemOrange
        diagnosticLabel.isHidden = errors.isEmpty
        saveButton.isEnabled = !hasHardError
    }

    static func localizedDiagnostic(_ d: SnippetTemplateDiagnostic) -> String {
        switch d.kind {
        case .unclosedOpenBrace:      return L10n.t("snip.tpl.diagUnclosed")
        case .unmatchedCloseBrace:    return L10n.t("snip.tpl.diagUnmatchedClose")
        case .emptyPlaceholder:       return L10n.t("snip.tpl.diagEmptyVar")
        case .nestedOpenBrace:        return L10n.t("snip.tpl.diagNested")
        case .invalidVariableName:    return L10n.t("snip.tpl.diagBadName", d.detail)
        case .emptyFormat:            return L10n.t("snip.tpl.diagEmptyFmt", d.detail)
        case .builtinTakesNoArgument: return L10n.t("snip.tpl.diagClipArg")
        case .unknownBuiltinFunction: return L10n.t("snip.tpl.diagUnknownFn", d.detail)
        }
    }

    @objc private func saveClicked() {
        let draft = buildDraftSnippet()
        if let err = onSave(draft) {
            diagnosticLabel.stringValue = err
            diagnosticLabel.textColor = .systemRed
            diagnosticLabel.isHidden = false
            NSSound.beep()
            return
        }
        closeSheet(NSApplication.ModalResponse.OK)
    }

    @objc private func cancelClicked() {
        closeSheet(NSApplication.ModalResponse.cancel)
    }

    private func closeSheet(_ response: NSApplication.ModalResponse) {
        guard let sheet = sheetWindow, let host = hostWindow else { return }
        host.endSheet(sheet, returnCode: response)
    }
}
