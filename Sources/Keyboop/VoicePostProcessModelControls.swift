import AppKit
import UniformTypeIdentifiers

/// Both settings sections reflect the same selection and download state.
final class VoicePostProcessModelControls: NSStackView {
    private let runtime = PredictionRuntime.dictation
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let action = NSButton(title: "", target: nil, action: nil)
    private let importButton = NSButton(title: L10n.t("voice.postprocess.importGGUF"), target: nil, action: nil)
    private let status = WrappingLabel(string: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let label = NSTextField(labelWithString: L10n.t("voice.postprocess.model"))
        label.font = .systemFont(ofSize: 13)
        addArrangedSubview(label)

        model.setAccessibilityLabel(label.stringValue)
        model.cell?.lineBreakMode = .byTruncatingTail
        model.target = self
        model.action = #selector(selectModel)
        for item in PredictionRuntime.dictationModels {
            model.addItem(withTitle: item.title)
            model.lastItem?.representedObject = item.id
        }

        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(manageModel)
        addFullWidthRow(NSStackView.modelControlRow(model, action))

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importModel)
        addFullWidthRow(NSStackView.modelControlRow(status, importButton))
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .dictationModelRuntimeChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func refresh() {
        let installed = runtime.installedModelIDs
        let selected = runtime.selectedModelID
        for (index, item) in PredictionRuntime.dictationModels.enumerated() {
            let size = L10n.size(item.sizeLabel)
            let marker = installed.contains(item.id) ? " · " + L10n.t("voice.installed") : ""
            model.item(at: index)?.title = "\(item.title) · \(size)\(marker)"
        }
        model.selectItem(at: model.indexOfItem(withRepresentedObject: selected))
        model.toolTip = model.titleOfSelectedItem
        let downloading = runtime.isDownloading
        let importing = runtime.isImporting
        model.isEnabled = !downloading && !importing
        let key = downloading ? "prediction.cancelDownload"
            : (installed.contains(selected) ? "prediction.deleteDownload" : "prediction.download")
        action.title = L10n.t(key)
        let supported = PredictionRuntime.hasBuiltInServer
        action.isEnabled = !importing && (supported || installed.contains(selected) || downloading)
        importButton.isHidden = !supported || downloading || importing || installed.contains(selected)
        status.stringValue = supported ? runtime.statusText : L10n.t("prediction.runtime.serverMissing")
    }

    @objc private func selectModel() {
        guard let id = model.selectedItem?.representedObject as? String else { return }
        runtime.selectedModelID = id
        refresh()
    }

    @objc private func manageModel() {
        if runtime.isDownloading { runtime.cancelDownload() }
        else if runtime.hasSelectedModel { runtime.deleteSelected() }
        else { runtime.downloadSelected() }
        refresh()
    }

    @objc private func importModel() {
        guard let window, let modelID = model.selectedItem?.representedObject as? String else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = L10n.t("voice.postprocess.importPrompt") + " " + (model.titleOfSelectedItem ?? "")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            self?.runtime.importSelected(from: source, modelID: modelID)
            self?.refresh()
        }
    }
}
