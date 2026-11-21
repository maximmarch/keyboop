import AppKit

/// Чекбоксы правил типографики по группам и пояснение различий между обычным, неразрывным и узким пробелами (KB-021 §4).
final class TypographyRuleCheckListView: NSView {
    var onChanged: (() -> Void)?

    private var checkboxes: [TypographyRuleID: NSButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        let store = TypographySettingsStore.shared
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let groups: [(titleKey: String, rules: [(id: TypographyRuleID, titleKey: String, hintKey: String?)])] = [
            ("typo.grp.quotes", [
                (.ruQuotes, "typo.rule.ruQuotes", "typo.rule.ruQuotes.hint"),
                (.nestedQuotes, "typo.rule.nestedQuotes", "typo.rule.nestedQuotes.hint"),
                (.enQuotes, "typo.rule.enQuotes", "typo.rule.enQuotes.hint"),
                (.enApostrophe, "typo.rule.enApostrophe", nil),
            ]),
            ("typo.grp.dashes", [
                (.emDash, "typo.rule.emDash", "typo.rule.emDash.hint"),
                (.enDashRanges, "typo.rule.enDashRanges", "typo.rule.enDashRanges.hint"),
            ]),
            ("typo.grp.spaces", [
                (.nbspUnits, "typo.rule.nbspUnits", "typo.rule.nbspUnits.hint"),
                (.narrowNbsp, "typo.rule.narrowNbsp", "typo.rule.narrowNbsp.hint"),
            ]),
            ("typo.grp.symbols", [
                (.ellipsis, "typo.rule.ellipsis", "typo.rule.ellipsis.hint"),
                (.copyright, "typo.rule.copyright", nil),
                (.registered, "typo.rule.registered", nil),
                (.trademark, "typo.rule.trademark", nil),
            ]),
        ]

        for grp in groups {
            let hdr = NSTextField(labelWithString: L10n.t(grp.titleKey))
            hdr.font = .systemFont(ofSize: 12, weight: .semibold)
            hdr.textColor = .secondaryLabelColor
            let grpStack = NSStackView()
            grpStack.orientation = .vertical
            grpStack.alignment = .leading
            grpStack.spacing = 6
            grpStack.addArrangedSubview(hdr)

            for item in grp.rules {
                let btn = NSButton(checkboxWithTitle: L10n.t(item.titleKey), target: self, action: #selector(ruleToggled(_:)))
                btn.font = .systemFont(ofSize: 12.5)
                btn.state = store.isRuleEnabled(item.id) ? .on : .off
                btn.identifier = NSUserInterfaceItemIdentifier(item.id.rawValue)
                btn.lineBreakMode = .byTruncatingTail
                btn.toolTip = btn.title
                checkboxes[item.id] = btn

                if let hk = item.hintKey {
                    let hintLbl = WrappingLabel(string: L10n.t(hk))
                    hintLbl.font = .systemFont(ofSize: 11)
                    hintLbl.textColor = .secondaryLabelColor
                    let hintRow = NSStackView(views: [hintLbl])
                    hintRow.orientation = .horizontal
                    hintRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                    let row = NSStackView()
                    row.orientation = .vertical
                    row.alignment = .leading
                    row.spacing = 2
                    row.addFullWidthRow(btn)
                    row.addFullWidthRow(hintRow)
                    grpStack.addFullWidthRow(row)
                } else {
                    grpStack.addFullWidthRow(btn)
                }
            }
            root.addFullWidthRow(grpStack)
        }

        // Карточка пояснения пробелов U+0020 vs U+00A0 vs U+202F (§4).
        let nbspBox = NSView()
        nbspBox.wantsLayer = true
        nbspBox.layer?.cornerRadius = 8
        nbspBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        nbspBox.layer?.borderWidth = 0.5
        nbspBox.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        nbspBox.translatesAutoresizingMaskIntoConstraints = false

        let nbspTitle = WrappingLabel(string: L10n.t("typo.nbspInfo.title"))
        nbspTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        nbspTitle.textColor = .labelColor

        let nbspBody = WrappingLabel(string: L10n.t("typo.nbspInfo.body"))
        nbspBody.font = .systemFont(ofSize: 11)
        nbspBody.textColor = .secondaryLabelColor
        let infoStack = NSStackView()
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.addFullWidthRow(nbspTitle)
        infoStack.addFullWidthRow(nbspBody)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        nbspBox.addSubview(infoStack)

        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: nbspBox.topAnchor, constant: 8),
            infoStack.bottomAnchor.constraint(equalTo: nbspBox.bottomAnchor, constant: -8),
            infoStack.leadingAnchor.constraint(equalTo: nbspBox.leadingAnchor, constant: 10),
            infoStack.trailingAnchor.constraint(equalTo: nbspBox.trailingAnchor, constant: -10),
        ])
        root.addFullWidthRow(nbspBox)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func reloadStates() {
        let store = TypographySettingsStore.shared
        for (id, btn) in checkboxes {
            btn.state = store.isRuleEnabled(id) ? .on : .off
        }
    }

    @objc private func ruleToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = TypographyRuleID(rawValue: raw) else { return }
        TypographySettingsStore.shared.setRuleEnabled(id, sender.state == .on)
        onChanged?()
    }
}

/// Управление отдельными исключениями приложений для умной типографики (FR-08).
final class TypographyExcludedAppsView: NSView {
    var onChanged: (() -> Void)?

    private let listStack = NSStackView()
    private let emptyLbl = WrappingLabel(string: L10n.t("typo.exc.empty"))
    private let runningPopup = NSPopUpButton()
    private var runningBundleIDs: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
        reloadList()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6

        emptyLbl.font = .systemFont(ofSize: 12)
        emptyLbl.textColor = .secondaryLabelColor

        runningPopup.controlSize = .regular
        runningPopup.target = self
        runningPopup.action = #selector(addRunningApp(_:))

        let chooseBtn = NSButton(title: L10n.t("exc.addApp"), target: self, action: #selector(chooseAppClicked))
        chooseBtn.bezelStyle = .rounded

        let buttonsRow = NSStackView(views: [runningPopup, chooseBtn])
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        buttonsRow.alignment = .centerY

        let defaultHint = WrappingLabel(string: L10n.t("typo.exc.defaultHint"))
        defaultHint.font = .systemFont(ofSize: 11)
        defaultHint.textColor = .secondaryLabelColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.addFullWidthRow(listStack)
        root.addArrangedSubview(buttonsRow)
        root.addFullWidthRow(defaultHint)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func reloadList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let excluded = Array(TypographySettingsStore.shared.excludedBundleIDs).sorted()

        if excluded.isEmpty {
            listStack.addFullWidthRow(emptyLbl)
        } else {
            for bid in excluded {
                listStack.addFullWidthRow(makeAppRow(bundleID: bid))
            }
        }

        runningPopup.removeAllItems()
        runningPopup.addItem(withTitle: L10n.t("exc.fromRunning"))
        let excludedSet = Set(excluded)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != "ru.keyboop.app" }
            .filter { !excludedSet.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        runningBundleIDs = running.compactMap(\.bundleIdentifier)
        for app in running {
            runningPopup.addItem(withTitle: app.localizedName ?? (app.bundleIdentifier ?? "?"))
        }
    }

    private func makeAppRow(bundleID: String) -> NSView {
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        var displayName = bundleID
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            iconView.image = NSWorkspace.shared.icon(forFile: appURL.path)
            if let bundle = Bundle(url: appURL) {
                displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? FileManager.default.displayName(atPath: appURL.path)
            }
        } else {
            iconView.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }

        let nameLbl = NSTextField(labelWithString: "\(displayName)  (\(bundleID))")
        nameLbl.font = .systemFont(ofSize: 12.5)
        nameLbl.lineBreakMode = .byTruncatingMiddle
        nameLbl.toolTip = nameLbl.stringValue

        let delBtn = NSButton(title: "", target: self, action: #selector(removeApp(_:)))
        delBtn.bezelStyle = .regularSquare
        delBtn.isBordered = false
        delBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "remove")
        delBtn.contentTintColor = .tertiaryLabelColor
        delBtn.identifier = NSUserInterfaceItemIdentifier(bundleID)

        let name = NSStackView(views: [iconView, nameLbl])
        name.orientation = .horizontal
        name.spacing = 8
        name.alignment = .centerY
        return NSStackView.modelControlRow(name, delBtn)
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard let bid = sender.identifier?.rawValue else { return }
        TypographySettingsStore.shared.setAppExcluded(bid, excluded: false)
        reloadList()
        onChanged?()
    }

    @objc private func addRunningApp(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem - 1
        sender.selectItem(at: 0)
        guard idx >= 0, idx < runningBundleIDs.count else { return }
        TypographySettingsStore.shared.setAppExcluded(runningBundleIDs[idx], excluded: true)
        reloadList()
        onChanged?()
    }

    @objc private func chooseAppClicked() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let bid = Bundle(url: url)?.bundleIdentifier {
            TypographySettingsStore.shared.setAppExcluded(bid, excluded: true)
            reloadList()
            onChanged?()
        }
    }
}

/// Изолированная область «Попробовать» внутри окна настроек (KB-021 §4).
/// Не зависит от системного перехватчика `Engine` (при активном окне настроек глобальный ввод изолирован)
/// и применяет правила напрямую через `TypographyEngine`.
final class TypographySandboxView: NSView, NSTextViewDelegate {
    private let textView = NSTextView()
    private let statusLabel = WrappingLabel(string: "")
    private let undoButton = NSButton(title: L10n.t("typo.sandbox.undo"), target: nil, action: nil)

    private var isMutatingInternally = false
    private var lastUndoSnapshot: (before: String, after: String, rules: [TypographyRuleID])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        let hintLbl = WrappingLabel(string: L10n.t("typo.sandbox.desc"))
        hintLbl.font = .systemFont(ofSize: 11.5)
        hintLbl.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self
        textView.string = L10n.t("typo.sandbox.initial")
        scroll.documentView = textView

        let formatAllBtn = NSButton(title: L10n.t("typo.sandbox.formatNow"), target: self, action: #selector(formatNowClicked))
        formatAllBtn.bezelStyle = .rounded

        undoButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.isEnabled = false

        let sampleQuotesBtn = NSButton(title: L10n.t("typo.sandbox.sampleQuotes"), target: self, action: #selector(loadSampleQuotes))
        sampleQuotesBtn.bezelStyle = .rounded
        sampleQuotesBtn.controlSize = .small

        let sampleCodeBtn = NSButton(title: L10n.t("typo.sandbox.sampleCode"), target: self, action: #selector(loadSampleCode))
        sampleCodeBtn.bezelStyle = .rounded
        sampleCodeBtn.controlSize = .small

        let clearBtn = NSButton(title: L10n.t("typo.sandbox.clear"), target: self, action: #selector(clearClicked))
        clearBtn.bezelStyle = .rounded
        clearBtn.controlSize = .small

        let actionsRow = NSStackView(views: [formatAllBtn, undoButton, NSView(), sampleQuotesBtn, sampleCodeBtn, clearBtn])
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 6
        actionsRow.alignment = .centerY

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L10n.t("typo.sandbox.ready")

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        [hintLbl, scroll, actionsRow, statusLabel].forEach { root.addFullWidthRow($0) }
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    func textDidChange(_ notification: Notification) {
        guard !isMutatingInternally else { return }
        let store = TypographySettingsStore.shared
        let current = textView.string
        guard !current.isEmpty else {
            lastUndoSnapshot = nil
            undoButton.isEnabled = false
            statusLabel.stringValue = L10n.t("typo.sandbox.ready")
            return
        }

        // Проверяем только при вводе границы / закрывающей кавычки / скобки, не трогая вставку целиком без триггера.
        guard let lastCh = current.last,
              lastCh.isWhitespace || "\"').,!? ;:".contains(lastCh) else {
            return
        }

        let context = TypographyContext(
            mode: .typing,
            languageMode: store.language,
            activeLayoutHint: nil,
            bundleID: "ru.keyboop.app.sandbox",
            rules: store.effectiveRules()
        )
        guard let patch = TypographyEngine.analyzeTypingTail(current, context: context) else {
            return
        }

        guard let cutIdx = current.index(current.endIndex, offsetBy: -patch.deleteCount, limitedBy: current.startIndex) else {
            return
        }
        let updated = String(current[..<cutIdx]) + patch.replacementSuffix
        applySandboxText(updated, previous: current, rules: patch.appliedRuleIDs)
    }

    @objc private func formatNowClicked() {
        let store = TypographySettingsStore.shared
        let current = textView.string
        guard !current.isEmpty else { return }
        let context = TypographyContext(
            mode: .selection,
            languageMode: store.language,
            activeLayoutHint: nil,
            bundleID: "ru.keyboop.app.sandbox",
            rules: store.effectiveRules()
        )
        let result = TypographyEngine.analyze(current, context: context)
        guard result.changed else {
            statusLabel.stringValue = L10n.t("typo.sandbox.noChanges")
            return
        }
        applySandboxText(result.transformedText, previous: current, rules: result.appliedRuleIDs)
    }

    @objc private func undoClicked() {
        guard let snap = lastUndoSnapshot, textView.string == snap.after else { return }
        isMutatingInternally = true
        textView.string = snap.before
        isMutatingInternally = false
        lastUndoSnapshot = nil
        undoButton.isEnabled = false
        statusLabel.stringValue = L10n.t("typo.sandbox.undone")
    }

    @objc private func loadSampleQuotes() {
        lastUndoSnapshot = nil
        undoButton.isEnabled = false
        isMutatingInternally = true
        textView.string = L10n.t("typo.sandbox.prose")
        isMutatingInternally = false
        statusLabel.stringValue = L10n.t("typo.sandbox.sampleLoaded")
    }

    @objc private func loadSampleCode() {
        lastUndoSnapshot = nil
        undoButton.isEnabled = false
        isMutatingInternally = true
        textView.string = "git commit --amend --no-edit && curl https://example.com/a--b?x=1"
        isMutatingInternally = false
        statusLabel.stringValue = L10n.t("typo.sandbox.sampleLoaded")
    }

    @objc private func clearClicked() {
        lastUndoSnapshot = nil
        undoButton.isEnabled = false
        isMutatingInternally = true
        textView.string = ""
        isMutatingInternally = false
        statusLabel.stringValue = L10n.t("typo.sandbox.ready")
    }

    private func applySandboxText(_ updated: String, previous: String, rules: [TypographyRuleID]) {
        isMutatingInternally = true
        textView.string = updated
        textView.setSelectedRange(NSRange(location: (updated as NSString).length, length: 0))
        isMutatingInternally = false

        lastUndoSnapshot = (before: previous, after: updated, rules: rules)
        undoButton.isEnabled = true

        let nbspCount = updated.unicodeScalars.filter { $0.value == 0x00A0 || $0.value == 0x202F }.count
        let names = rules.map { L10n.t("typo.rule.\($0.rawValue)") }.joined(separator: ", ")
        statusLabel.stringValue = String(format: L10n.t("typo.sandbox.applied"), names, nbspCount)
    }
}
