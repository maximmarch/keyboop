import AppKit

/// Shows download state in place, so a progress update never rebuilds the settings window.
final class SageSettingsControls: NSStackView {
    private let runtime = SageRuntime.shared
    private let status = NSTextField(wrappingLabelWithString: "")
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
        for label in [detail, status] {
            label.font = .systemFont(ofSize: 12)
            addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        }

        action.target = self
        action.action = #selector(manageModel)
        addArrangedSubview(action)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SageRuntime.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func refresh() {
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

    @objc private func manageModel() {
        switch runtime.state {
        case .unavailable: break
        case .missing, .failed: runtime.download()
        case .downloading: runtime.cancelDownload()
        case .ready: runtime.deleteModel()
        }
    }
}
