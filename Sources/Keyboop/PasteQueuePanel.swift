import AppKit

// KB-022 · Панель очереди последовательной вставки (вкладка «Очередь» в окне истории).
//
// Содержит:
//  • Компактный индикатор над списком (`2 / 3 · Следующий элемент: …`, статус паузы/завершения);
//  • Таблицу очереди: `№`, `Текст`, `Состояние` (`Вставлено` / `Отправлено` / `Частично` /
//    `Следующий` / `Ожидает`), двойной клик или Return — просмотр и правка перед вставкой;
//  • Кнопки управления, вставки следующего/выбранного/всех элементов и полное управление с
//    клавиатуры (`↑/↓` выбор, `⌥↑/⌥↓` перестановка, `⌫` удаление, `↩` просмотр/правка, `⌘↩`
//    вставка выбранного);
//  • Поддержку приватности: маскировка `isSensitive` элементов и сигнал родительскому окну,
//    чтобы скрыть окно при демонстрации экрана (`NSWindow.sharingType = .none`).

final class PasteQueuePanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store = PasteQueueStore.shared

    var onSensitivityChanged: ((Bool) -> Void)?

    private let indicatorBox = NSView()
    private let indicatorLabel = NSTextField(labelWithString: "")
    private let resumeBtn = NSButton(title: "", target: nil, action: nil)

    private let table = PasteQueueTableView()
    private let scroll = NSScrollView()

    private let addClipBtn = NSButton(title: "", target: nil, action: nil)
    private let addHistBtn = NSButton(title: "", target: nil, action: nil)
    private let upBtn = NSButton(title: "", target: nil, action: nil)
    private let downBtn = NSButton(title: "", target: nil, action: nil)
    private let editBtn = NSButton(title: "", target: nil, action: nil)
    private let privBtn = NSButton(title: "", target: nil, action: nil)
    private let delBtn = NSButton(title: "", target: nil, action: nil)

    private let backBtn = NSButton(title: "", target: nil, action: nil)
    private let makeNextBtn = NSButton(title: "", target: nil, action: nil)
    private let restartBtn = NSButton(title: "", target: nil, action: nil)
    private let clearBtn = NSButton(title: "", target: nil, action: nil)

    private let pasteNextBtn = NSButton(title: "", target: nil, action: nil)
    private let pastePickedBtn = NSButton(title: "", target: nil, action: nil)
    private let pasteAllBtn = NSButton(title: "", target: nil, action: nil)

    private let footerHint = NSTextField(wrappingLabelWithString: "")
    private var lastSensitive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(queueChanged),
            name: .keyboopPasteQueueChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .keyboopLanguageChanged, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func focusTable() { window?.makeFirstResponder(table) }

    private func build() {
        indicatorBox.wantsLayer = true
        indicatorBox.layer?.cornerRadius = 8
        indicatorBox.layer?.cornerCurve = .continuous
        indicatorBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        indicatorBox.translatesAutoresizingMaskIntoConstraints = false

        indicatorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        indicatorLabel.textColor = .labelColor
        indicatorLabel.lineBreakMode = .byTruncatingTail
        indicatorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indicatorLabel.translatesAutoresizingMaskIntoConstraints = false

        resumeBtn.bezelStyle = .rounded
        resumeBtn.controlSize = .small
        resumeBtn.target = self; resumeBtn.action = #selector(resumeQueue)
        resumeBtn.isHidden = true
        resumeBtn.translatesAutoresizingMaskIntoConstraints = false
        indicatorBox.addSubview(indicatorLabel)
        indicatorBox.addSubview(resumeBtn)

        // Таблица: № | Текст | Состояние
        let colNum = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("num"))
        colNum.width = 28; colNum.minWidth = 24; colNum.maxWidth = 38
        let colText = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        colText.minWidth = 100
        let colState = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        colState.width = 90; colState.minWidth = 76; colState.maxWidth = 115

        table.addTableColumn(colNum)
        table.addTableColumn(colText)
        table.addTableColumn(colState)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        colText.resizingMask = .autoresizingMask
        colNum.resizingMask = []
        colState.resizingMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.onKey = { [weak self] event in self?.handleTableKey(event) ?? false }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Панель инструментов над таблицей: добавление и действия над выбранным элементом.
        configureToolbarBtn(addClipBtn, symbol: "doc.on.clipboard", action: #selector(addFromClipboard))
        configureToolbarBtn(addHistBtn, symbol: "clock.arrow.circlepath", action: #selector(addFromHistory))
        configureToolbarBtn(upBtn, symbol: "chevron.up", action: #selector(moveItemUp))
        configureToolbarBtn(downBtn, symbol: "chevron.down", action: #selector(moveItemDown))
        configureToolbarBtn(editBtn, symbol: "pencil", action: #selector(editSelected))
        configureToolbarBtn(privBtn, symbol: "eye.slash", action: #selector(toggleSensitive))
        configureToolbarBtn(delBtn, symbol: "trash", action: #selector(removeSelected))

        let topBar = NSStackView(views: [
            addClipBtn, addHistBtn, spacerView(), upBtn, downBtn, editBtn, privBtn, delBtn
        ])
        topBar.orientation = .horizontal
        topBar.spacing = 4
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // Строка управления сессией: назад / сделать следующим / сначала / очистить.
        [backBtn, makeNextBtn, restartBtn, clearBtn].forEach {
            $0.bezelStyle = .rounded; $0.controlSize = .small; $0.target = self
        }
        backBtn.action = #selector(stepBack)
        makeNextBtn.action = #selector(makeSelectedNext)
        restartBtn.action = #selector(restartQueue)
        clearBtn.action = #selector(clearQueue)

        let sessionRow = NSStackView(views: [backBtn, makeNextBtn, restartBtn, clearBtn])
        sessionRow.orientation = .horizontal
        sessionRow.spacing = 6
        sessionRow.distribution = .fillProportionally
        sessionRow.translatesAutoresizingMaskIntoConstraints = false

        // Кнопки вставки: Режим А (следующий), Режим Б (выбранный), Режим В (все).
        pasteNextBtn.bezelStyle = .rounded
        pasteNextBtn.keyEquivalent = ""
        pasteNextBtn.target = self; pasteNextBtn.action = #selector(pasteNext)

        pastePickedBtn.bezelStyle = .rounded
        pastePickedBtn.target = self; pastePickedBtn.action = #selector(pasteSelected)

        pasteAllBtn.bezelStyle = .rounded
        pasteAllBtn.target = self; pasteAllBtn.action = #selector(pasteAll)

        let pasteRow = NSStackView(views: [pasteNextBtn, pastePickedBtn, pasteAllBtn])
        pasteRow.orientation = .horizontal
        pasteRow.spacing = 6
        pasteRow.distribution = .fillProportionally
        pasteRow.translatesAutoresizingMaskIntoConstraints = false

        footerHint.font = .systemFont(ofSize: 10.5)
        footerHint.textColor = .secondaryLabelColor
        footerHint.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indicatorBox)
        addSubview(topBar)
        addSubview(scroll)
        addSubview(sessionRow)
        addSubview(pasteRow)
        addSubview(footerHint)

        NSLayoutConstraint.activate([
            indicatorBox.topAnchor.constraint(equalTo: topAnchor),
            indicatorBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicatorBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            indicatorBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

            indicatorLabel.leadingAnchor.constraint(equalTo: indicatorBox.leadingAnchor, constant: 10),
            indicatorLabel.topAnchor.constraint(equalTo: indicatorBox.topAnchor, constant: 7),
            indicatorLabel.bottomAnchor.constraint(equalTo: indicatorBox.bottomAnchor, constant: -7),
            indicatorLabel.trailingAnchor.constraint(lessThanOrEqualTo: resumeBtn.leadingAnchor, constant: -8),
            resumeBtn.centerYAnchor.constraint(equalTo: indicatorBox.centerYAnchor),
            resumeBtn.trailingAnchor.constraint(equalTo: indicatorBox.trailingAnchor, constant: -8),

            topBar.topAnchor.constraint(equalTo: indicatorBox.bottomAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: sessionRow.topAnchor, constant: -8),

            sessionRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            sessionRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionRow.bottomAnchor.constraint(equalTo: pasteRow.topAnchor, constant: -6),

            pasteRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            pasteRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            pasteRow.bottomAnchor.constraint(equalTo: footerHint.topAnchor, constant: -6),

            footerHint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            footerHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            footerHint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyLabels()
    }

    private func configureToolbarBtn(_ b: NSButton, symbol: String, action: Selector) {
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageOnly
        b.target = self; b.action = action
    }

    private func spacerView() -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    private func applyLabels() {
        table.tableColumns[0].title = L10n.t("pq.col.num")
        table.tableColumns[1].title = L10n.t("pq.col.text")
        table.tableColumns[2].title = L10n.t("pq.col.state")

        addClipBtn.toolTip = L10n.t("pq.btn.addClipboard")
        addHistBtn.toolTip = L10n.t("pq.btn.addHistory")
        upBtn.toolTip = L10n.t("pq.btn.up")
        downBtn.toolTip = L10n.t("pq.btn.down")
        editBtn.toolTip = L10n.t("pq.btn.edit")
        privBtn.toolTip = L10n.t("pq.btn.private")
        delBtn.toolTip = L10n.t("pq.btn.remove")

        resumeBtn.title = L10n.t("pq.btn.resume")
        backBtn.title = L10n.t("pq.btn.back")
        makeNextBtn.title = L10n.t("pq.btn.makeNext")
        restartBtn.title = L10n.t("pq.btn.restart")
        clearBtn.title = L10n.t("pq.btn.clear")

        pasteNextBtn.title = L10n.t("pq.btn.pasteNext")
        pastePickedBtn.title = L10n.t("pq.btn.pastePicked")
        pasteAllBtn.title = L10n.t("pq.btn.pasteAll")
    }

    @objc private func queueChanged() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    @objc func reload() {
        applyLabels()
        let selectedIDs = selectedItemIDs()
        table.reloadData()
        restoreSelection(selectedIDs)
        updateIndicator()
        updateButtons()
        updateFooterHint()
        let hasSensitive = store.items.contains(where: \.isSensitive)
        if hasSensitive != lastSensitive {
            lastSensitive = hasSensitive
            onSensitivityChanged?(hasSensitive)
        }
    }

    private func updateIndicator() {
        if store.items.isEmpty {
            indicatorLabel.stringValue = L10n.t("pq.indicator.empty")
            indicatorBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            resumeBtn.isHidden = true
            return
        }
        if store.isPausedAfterPartial {
            indicatorLabel.stringValue = L10n.t("pq.indicator.paused")
            indicatorBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.20).cgColor
            resumeBtn.isHidden = false
            return
        }
        resumeBtn.isHidden = true
        indicatorBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        let total = store.items.count
        if store.isCompleted {
            indicatorLabel.stringValue = L10n.t("pq.completed", total, total)
        } else {
            let pos = store.currentIndex + 1
            let preview = store.nextItem?.preview(maxLength: 28) ?? ""
            if case .sentUnconfirmed = store.lastStatus {
                indicatorLabel.stringValue = L10n.t("pq.sentUnconfirmed", pos, total, preview)
            } else {
                indicatorLabel.stringValue = L10n.t("pq.progress", pos, total, preview)
            }
        }
    }

    private func updateButtons() {
        let count = store.items.count
        let sel = table.selectedRowIndexes
        let singleRow = sel.count == 1 ? sel.first : nil

        addClipBtn.isEnabled = count < PasteQueueLimits.maxItems
        upBtn.isEnabled = singleRow.map { $0 > 0 } ?? false
        downBtn.isEnabled = singleRow.map { $0 + 1 < count } ?? false
        editBtn.isEnabled = singleRow != nil
        privBtn.isEnabled = !sel.isEmpty
        delBtn.isEnabled = !sel.isEmpty

        backBtn.isEnabled = !store.items.isEmpty && store.currentIndex > 0
        makeNextBtn.isEnabled = singleRow != nil
        restartBtn.isEnabled = !store.items.isEmpty
        clearBtn.isEnabled = !store.items.isEmpty

        pasteNextBtn.isEnabled = !store.items.isEmpty && !store.isCompleted && !store.isPausedAfterPartial
        pastePickedBtn.isEnabled = singleRow != nil
        pasteAllBtn.isEnabled = !store.items.isEmpty
    }

    private func updateFooterHint() {
        let s = PasteQueueSettingsStore.shared
        let keyHint = s.hotkeyEnabled && !s.hotkeyLabel.isEmpty
            ? L10n.t("pq.hint.key", s.hotkeyLabel)
            : L10n.t("pq.hint.noKey")
        footerHint.stringValue = keyHint + "\n" + L10n.t("pq.hint.private")
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { store.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < store.items.count, let col = tableColumn?.identifier.rawValue else { return nil }
        let item = store.items[row]
        let isNext = (row == store.currentIndex && !store.isPausedAfterPartial)

        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        switch col {
        case "num":
            label.stringValue = isNext ? "▶ \(row + 1)" : "\(row + 1)"
            label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: isNext ? .semibold : .regular)
            label.textColor = isNext ? DS.coral : .secondaryLabelColor
        case "text":
            label.stringValue = item.preview(maxLength: 90)
            label.font = .systemFont(ofSize: 12.5, weight: isNext ? .medium : .regular)
            label.textColor = item.isSensitive ? .secondaryLabelColor : .labelColor
        case "state":
            label.stringValue = stateTitle(for: item, row: row)
            label.font = .systemFont(ofSize: 11, weight: isNext ? .semibold : .regular)
            label.textColor = stateColor(for: item, row: row)
            label.alignment = .right
        default:
            break
        }
        let wrap = NSView()
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)
        ])
        return wrap
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func stateTitle(for item: PasteQueueItem, row: Int) -> String {
        switch item.state {
        case .confirmed:       return L10n.t("pq.state.confirmed")
        case .sentUnconfirmed: return L10n.t("pq.state.sent")
        case .partial:         return L10n.t("pq.state.partial")
        case .pending:
            return row == store.currentIndex ? L10n.t("pq.state.next") : L10n.t("pq.state.pending")
        }
    }

    private func stateColor(for item: PasteQueueItem, row: Int) -> NSColor {
        switch item.state {
        case .confirmed:       return .systemGreen
        case .sentUnconfirmed: return .secondaryLabelColor
        case .partial:         return .systemOrange
        case .pending:         return row == store.currentIndex ? DS.coral : .tertiaryLabelColor
        }
    }

    // MARK: Keyboard navigation

    private func handleTableKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 51 where mods.isEmpty, 117 where mods.isEmpty:   // Backspace / Forward Delete
            removeSelected(); return true
        case 126 where mods == .option:    // ⌥↑
            moveItemUp(); return true
        case 125 where mods == .option:    // ⌥↓
            moveItemDown(); return true
        case 36 where mods == .command:    // ⌘↩ — вставить выбранный
            pasteSelected(); return true
        case 36 where mods.isEmpty:        // ↩ — просмотр и правка
            editSelected(); return true
        default:
            return false
        }
    }

    // MARK: Actions

    private func selectedItemIDs() -> Set<UUID> {
        Set(table.selectedRowIndexes.compactMap {
            $0 >= 0 && $0 < store.items.count ? store.items[$0].id : nil
        })
    }

    private func restoreSelection(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let idx = IndexSet(store.items.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        if !idx.isEmpty { table.selectRowIndexes(idx, byExtendingSelection: false) }
    }

    private func selectedSingleItem() -> PasteQueueItem? {
        guard table.selectedRowIndexes.count == 1, let r = table.selectedRowIndexes.first,
              r >= 0, r < store.items.count else { return nil }
        return store.items[r]
    }

    @objc private func addFromClipboard() { PasteQueueSystem.addClipboard() }

    @objc private func addFromHistory() {
        if HistoryGate.enabled {
            VoiceIndicator.shared.showToast(L10n.t("pq.history.locked")); return
        }
        let entries = Array(VoiceHistory.shared.all().reversed())
        guard !entries.isEmpty else {
            VoiceIndicator.shared.showToast(L10n.t("pq.history.empty")); return
        }
        let picker = HistoryBatchPickerWindow(entries: entries) { chosen in
            PasteQueueSystem.addHistory(chosen)
        }
        if let parent = window {
            picker.runSheet(over: parent)
        }
    }

    @objc private func moveItemUp() {
        guard let item = selectedSingleItem() else { return }
        _ = store.move(id: item.id, by: -1)
    }

    @objc private func moveItemDown() {
        guard let item = selectedSingleItem() else { return }
        _ = store.move(id: item.id, by: 1)
    }

    @objc private func removeSelected() {
        let ids = selectedItemIDs()
        guard !ids.isEmpty else { return }
        store.remove(ids: ids)
    }

    @objc private func toggleSensitive() {
        let ids = selectedItemIDs()
        guard !ids.isEmpty else { return }
        let turnOn = store.items.filter { ids.contains($0.id) }.contains { !$0.isSensitive }
        for id in ids { store.setSensitive(id: id, turnOn) }
    }

    @objc private func editSelected() {
        guard let item = selectedSingleItem() else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("pq.edit.title")
        alert.addButton(withTitle: L10n.t("pq.edit.save"))
        alert.addButton(withTitle: L10n.t("pq.cancel"))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.string = item.text
        tv.isEditable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv

        let priv = NSButton(checkboxWithTitle: L10n.t("pq.btn.private"), target: nil, action: nil)
        priv.state = item.isSensitive ? .on : .off
        priv.translatesAutoresizingMaskIntoConstraints = false

        let box = NSStackView(views: [scroll, priv])
        box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
        box.frame = NSRect(x: 0, y: 0, width: 340, height: 170)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        alert.accessoryView = box
        alert.window.initialFirstResponder = tv
        guard let parent = window else { return }
        alert.beginSheetModal(for: parent) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            if let err = self?.store.updateText(id: item.id, to: tv.string) {
                VoiceIndicator.shared.showToast(PasteQueueSystem.addErrorText(err))
                return
            }
            self?.store.setSensitive(id: item.id, priv.state == .on)
        }
    }

    @objc private func stepBack() { store.stepBack() }
    @objc private func makeSelectedNext() {
        guard let item = selectedSingleItem() else { return }
        store.setNext(id: item.id)
    }
    @objc private func resumeQueue() { store.resume() }
    @objc private func restartQueue() { store.restart() }
    @objc private func clearQueue() { store.clear() }

    @objc private func pasteNext() {
        PasteQueueSystem.runAfterYieldingFocus { PasteQueueCoordinator.shared.pasteNext() }
    }

    @objc private func pasteSelected() {
        guard let item = selectedSingleItem() else { return }
        PasteQueueSystem.runAfterYieldingFocus { PasteQueueCoordinator.shared.paste(itemID: item.id) }
    }

    @objc private func pasteAll() {
        guard !store.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("pq.all.title")
        alert.informativeText = L10n.t("pq.all.delimiter")
        alert.addButton(withTitle: L10n.t("pq.all.go"))
        alert.addButton(withTitle: L10n.t("pq.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = PasteQueueSettingsStore.shared.joinDelimiter
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let parent = window else { return }
        alert.beginSheetModal(for: parent) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let raw = field.stringValue
            PasteQueueSettingsStore.shared.joinDelimiter = raw
            let delimiter = raw.replacingOccurrences(of: "\\n", with: "\n")
                               .replacingOccurrences(of: "\\t", with: "\t")
            PasteQueueSystem.runAfterYieldingFocus {
                PasteQueueCoordinator.shared.pasteAll(delimiter: delimiter)
            }
        }
    }
}

/// NSTableView, отдающий клавиатурные команды панели очереди (⌥↑/⌥↓, ⌫, ↩, ⌘↩).
private final class PasteQueueTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Пакетный выбор записей истории для добавления в очередь (FR-01).
private final class HistoryBatchPickerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let entries: [VoiceHistory.Entry]
    private let onPick: ([VoiceHistory.Entry]) -> Void
    private var sheetWindow: NSWindow?
    private let table = NSTableView()
    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    init(entries: [VoiceHistory.Entry], onPick: @escaping ([VoiceHistory.Entry]) -> Void) {
        self.entries = entries
        self.onPick = onPick
    }

    func runSheet(over parent: NSWindow) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                         styleMask: [.titled], backing: .buffered, defer: false)
        self.sheetWindow = w
        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        w.contentView = root

        let title = NSTextField(labelWithString: L10n.t("pq.history.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: L10n.t("pq.history.hint"))
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        col.resizingMask = .autoresizingMask
        table.headerView = nil
        table.addTableColumn(col)
        table.allowsMultipleSelection = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: L10n.t("pq.cancel"), target: self, action: #selector(cancelSheet))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let add = NSButton(title: L10n.t("pq.history.add"), target: self, action: #selector(commitSheet))
        add.bezelStyle = .rounded; add.keyEquivalent = "\r"

        let btns = NSStackView(views: [cancel, add])
        btns.orientation = .horizontal; btns.spacing = 8
        btns.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title); root.addSubview(hint); root.addSubview(scroll); root.addSubview(btns)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: btns.topAnchor, constant: -12),
            btns.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            btns.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        // Удерживаем себя, пока открыт sheet.
        objc_setAssociatedObject(w, "picker", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parent.beginSheet(w) { _ in
            objc_setAssociatedObject(w, "picker", nil, .OBJC_ASSOCIATION_ASSIGN)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let flat = e.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        let label = NSTextField(labelWithString: "\(df.string(from: e.date)) · \(flat)")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    @objc private func cancelSheet() {
        guard let w = sheetWindow, let p = w.sheetParent else { return }
        p.endSheet(w, returnCode: .cancel)
    }

    @objc private func commitSheet() {
        let chosen = table.selectedRowIndexes.compactMap { $0 >= 0 && $0 < entries.count ? entries[$0] : nil }
        guard let w = sheetWindow, let p = w.sheetParent else { return }
        p.endSheet(w, returnCode: .OK)
        if !chosen.isEmpty { onPick(chosen) }
    }
}
