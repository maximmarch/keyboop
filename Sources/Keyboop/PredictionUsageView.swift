import AppKit

final class PredictionUsageView: NSStackView {
    private let current = WrappingLabel(string: "")
    private let comparison = NSPopUpButton(frame: .zero, pullsDown: false)
    private let compareRow = NSStackView()
    private let grid = NSGridView()
    private let detail = WrappingLabel(string: "")
    private let store = PredictionUsageStore.shared
    private var builds: [PredictionUsage.Build] = []
    private var reading = false
    private var needsRead = false

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        addFullWidthRow(current)
        compareRow.addArrangedSubview(NSTextField(labelWithString: L10n.t("usage.compare")))
        compareRow.addArrangedSubview(comparison)
        comparison.target = self
        comparison.action = #selector(render)
        addArrangedSubview(compareRow)
        let headers = ["", "RU", "EN", L10n.t("usage.baseRU"), L10n.t("usage.baseEN")]
        grid.addRow(with: headers.map { NSTextField(labelWithString: $0) })
        for key in ["usage.shown", "usage.accepted", "usage.rate", "usage.undone", "usage.saved", "usage.latency"] {
            let label = NSTextField(labelWithString: L10n.t(key))
            let values = (0..<4).map { _ -> NSTextField in
                let field = NSTextField(labelWithString: "—")
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                return field
            }
            grid.addRow(with: [label] + values)
        }
        grid.columnSpacing = 12
        grid.rowSpacing = 4
        for col in 1..<5 { grid.column(at: col).xPlacement = .trailing }
        addArrangedSubview(grid)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        addFullWidthRow(detail)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: PredictionUsageStore.changed, object: nil)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    private func title(_ build: PredictionUsage.Build) -> String {
        "\(build.version) · \(build.id.prefix(8))"
    }

    @objc private func refresh() {
        guard window != nil else { return }
        if reading { needsRead = true; return }
        reading = true
        store.load { [weak self] result in
            guard let self else { return }
            self.reading = false
            switch result {
            case let .success(saved):
                self.builds = saved
                let selected = self.comparison.selectedItem?.representedObject as? String
                let alternatives = saved.filter { $0.id != self.store.build.id }
                if alternatives.map(\.id) != self.comparison.itemArray.compactMap({ $0.representedObject as? String }) {
                    self.comparison.removeAllItems()
                    for build in alternatives {
                        self.comparison.addItem(withTitle: self.title(build))
                        self.comparison.lastItem?.representedObject = build.id
                    }
                    if let selected, let index = alternatives.firstIndex(where: { $0.id == selected }) {
                        self.comparison.selectItem(at: index)
                    }
                }
                self.render()
            case .failure:
                self.detail.stringValue = L10n.t("usage.readError")
            }
            if self.needsRead { self.needsRead = false; self.refresh() }
        }
    }

    @objc private func render() {
        let live = builds.first { $0.id == store.build.id } ?? store.build
        current.stringValue = L10n.t("usage.current", title(live))
        detail.stringValue = L10n.t("usage.detail")
        let baseline = builds.first { $0.id == comparison.selectedItem?.representedObject as? String }
        compareRow.isHidden = baseline == nil
        grid.column(at: 3).isHidden = baseline == nil
        grid.column(at: 4).isHidden = baseline == nil
        let columns = [live.ru, live.en] + (baseline.map { [$0.ru, $0.en] } ?? [])
        for (index, counts) in columns.enumerated() {
            let rate = counts.acceptancePercent.map { String(format: "%.1f%%", $0) } ?? "—"
            let latency = counts.meanMS.map { String(format: "%.0f", $0) } ?? "—"
            let values = [String(counts.shown), String(counts.accepted), rate, String(counts.undone), String(counts.saved), latency]
            for (row, value) in values.enumerated() {
                (grid.cell(atColumnIndex: index + 1, rowIndex: row + 1).contentView as? NSTextField)?.stringValue = value
            }
        }
    }
}
