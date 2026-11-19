import AppKit

/// Shows download state in place, so a progress update never rebuilds the settings window.
final class SageSettingsControls: NSStackView {
    private let runtime = SageRuntime.shared
    private let status = WrappingLabel(string: "")
    private let enabledSwitch = NSSwitch()
    private let dictationSwitch = NSSwitch()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let action = NSButton(title: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let title = NSTextField(labelWithString: L10n.t("sage.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        enabledSwitch.setAccessibilityLabel(L10n.t("sage.enabled"))
        enabledSwitch.target = self
        enabledSwitch.action = #selector(changeEnabled)
        let titleRow = NSStackView.modelControlRow(title, enabledSwitch)
        addFullWidthRow(titleRow)
        setCustomSpacing(4, after: titleRow)

        let detail = WrappingLabel(string: L10n.t("sage.detail"))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        addFullWidthRow(detail)

        dictationSwitch.target = self
        dictationSwitch.action = #selector(changeDictation)
        addControl(dictationSwitch, key: "voice.sage.enable")

        mode.addItems(withTitles: SageTypingMode.allCases.map { L10n.t($0.localizationKey) })
        mode.target = self
        mode.action = #selector(changeTypingMode)
        addControl(mode, key: "sage.typing.mode")

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(manageModel)
        addFullWidthRow(NSStackView.modelControlRow(status, action))
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SageRuntime.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    private func addControl(_ control: NSControl, key: String) {
        let label = NSTextField(labelWithString: L10n.t(key))
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        control.setAccessibilityLabel(label.stringValue)
        addFullWidthRow(NSStackView.modelControlRow(label, control))
    }

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
