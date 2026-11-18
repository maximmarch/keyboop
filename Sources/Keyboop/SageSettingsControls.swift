import AppKit

/// Shows download state in place, so a progress update never rebuilds the settings window.
final class SageSettingsControls: NSStackView {
    private let runtime = SageRuntime.shared
    private let status = NSTextField(wrappingLabelWithString: "")
    private let enabledSwitch = NSSwitch()
    private let dictationSwitch = NSSwitch()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let action = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        let title = NSTextField(labelWithString: L10n.t("sage.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        addArrangedSubview(title)

        let detail = NSTextField(wrappingLabelWithString: L10n.t("sage.detail"))
        detail.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true

        func addSwitch(_ toggle: NSSwitch, title: String, action: Selector) {
            let label = NSTextField(labelWithString: L10n.t(title))
            label.font = .systemFont(ofSize: 12)
            toggle.setAccessibilityLabel(label.stringValue)
            toggle.target = self
            toggle.action = action
            let row = NSStackView(views: [label, toggle])
            row.alignment = .centerY
            row.spacing = 8
            addArrangedSubview(row)
        }
        addSwitch(enabledSwitch, title: "sage.enabled", action: #selector(changeEnabled))
        addSwitch(dictationSwitch, title: "voice.sage.enable", action: #selector(changeDictation))

        mode.addItems(withTitles: SageTypingMode.allCases.map { L10n.t($0.localizationKey) })
        mode.target = self
        mode.action = #selector(changeTypingMode)
        let modeLabel = NSTextField(labelWithString: L10n.t("sage.typing.mode"))
        modeLabel.font = .systemFont(ofSize: 12)
        mode.setAccessibilityLabel(modeLabel.stringValue)
        let modeRow = NSStackView(views: [modeLabel, mode])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        addArrangedSubview(modeRow)

        status.font = .systemFont(ofSize: 12)
        addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true

        action.target = self
        action.action = #selector(manageModel)
        addArrangedSubview(action)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SageRuntime.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func refresh() {
        let settings = AppSettings.shared
        enabledSwitch.state = settings.sageEnabled ? .on : .off
        dictationSwitch.state = settings.voiceSageProofreading ? .on : .off
        dictationSwitch.isEnabled = settings.sageEnabled
        mode.isEnabled = settings.sageEnabled
        if let index = SageTypingMode.allCases.firstIndex(of: AppSettings.shared.sageTypingMode) {
            mode.selectItem(at: index)
        }
        let byteCount = ByteCountFormatter.string(fromByteCount: runtime.downloadByteCount, countStyle: .file)
        let download = L10n.t("sage.download", byteCount)
        action.isEnabled = true
        switch runtime.state {
        case .unavailable:
            status.stringValue = L10n.t("sage.error.unavailable")
            action.title = download
            action.isEnabled = false
        case .missing:
            status.stringValue = L10n.t("sage.status.missing")
            action.title = download
        case .downloading(let progress):
            status.stringValue = L10n.t("sage.status.progress", Int((100 * progress).rounded(.down)))
            action.title = L10n.t("prediction.cancelDownload")
        case .ready:
            status.stringValue = L10n.t("sage.status.ready")
            action.title = L10n.t("prediction.deleteDownload")
        case .failed(let error):
            status.stringValue = L10n.t(error.localizationKey)
            action.title = download
        }
    }

    @objc private func changeEnabled() {
        AppSettings.shared.sageEnabled = enabledSwitch.state == .on
        SageCorrectionCoordinator.shared.cancelTyping()
        refresh()
    }

    @objc private func changeDictation() {
        AppSettings.shared.voiceSageProofreading = dictationSwitch.state == .on
    }

    @objc private func changeTypingMode() {
        guard SageTypingMode.allCases.indices.contains(mode.indexOfSelectedItem) else { return }
        AppSettings.shared.sageTypingMode = SageTypingMode.allCases[mode.indexOfSelectedItem]
        SageCorrectionCoordinator.shared.cancelTyping()
    }

    @objc private func manageModel() {
        switch runtime.state {
        case .unavailable: break
        case .missing, .failed: runtime.download()
        case .downloading: runtime.cancelDownload()
        case .ready: runtime.deleteModel()
        }
    }
}
