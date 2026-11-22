import AppKit

final class PredictionSyncView: NSStackView {
    private let sync = PredictionSync.shared
    private let folder = NSButton(title: L10n.t("sync.folder"), target: nil, action: nil)
    private let toggle = NSButton(title: "", target: nil, action: nil)
    private let now = NSButton(title: L10n.t("sync.now"), target: nil, action: nil)
    private let personal = NSButton(checkboxWithTitle: L10n.t("sync.personal"), target: nil, action: nil)
    private let status = WrappingLabel(string: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        addFullWidthRow(WrappingLabel(string: L10n.t("sync.help")))
        let actions = NSStackView(views: [folder, toggle, now])
        actions.spacing = 6
        addArrangedSubview(actions)
        addArrangedSubview(personal)
        addFullWidthRow(status)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        folder.target = self; folder.action = #selector(choose)
        toggle.target = self; toggle.action = #selector(toggleSync)
        now.target = self; now.action = #selector(run)
        personal.target = self; personal.action = #selector(togglePersonal)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: PredictionSync.changed, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func choose() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.t("sync.connect")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.sync.choose(url) }
            catch { self.status.stringValue = L10n.t("sync.retry") }
        }
    }

    @objc private func toggleSync() { sync.setEnabled(!sync.enabled) }
    @objc private func togglePersonal() { sync.setSharesPersonal(personal.state == .on) }
    @objc private func run() { sync.syncNow() }

    @objc private func refresh() {
        toggle.isHidden = sync.folderPath == nil
        toggle.title = L10n.t(sync.enabled ? "sync.pause" : "sync.resume")
        now.isHidden = !sync.enabled
        now.isEnabled = sync.status != "sync.working"
        personal.isEnabled = sync.enabled
        personal.state = sync.sharesPersonal ? .on : .off
        var lines = [sync.folderPath, L10n.t(sync.status)].compactMap { $0 }
        if sync.enabled, sync.sharesPersonal, !AppSettings.shared.personalPredictionEnabled {
            lines.append(L10n.t("sync.learningOff"))
        }
        if let last = sync.lastSuccess { lines.append(L10n.t("sync.last", last.formatted(date: .abbreviated, time: .shortened))) }
        status.stringValue = lines.joined(separator: "\n")
    }
}
