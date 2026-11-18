import AppKit

/// Updates the controls in place so a progress notification never removes the active field editor.
final class PredictionModelControls: NSStackView {
    private let runtime = PredictionRuntime.shared
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton(title: "", target: nil, action: nil)
    private let modelRow = NSStackView()
    private let testButton = NSButton(title: L10n.t("prediction.probe"), target: nil, action: nil)
    private let compareButton = NSButton(title: "", target: nil, action: nil)
    private let comparisonResults = NSStackView()
    private var comparison: PredictionComparison?
    private let testResult = NSTextField(wrappingLabelWithString: "")
    private lazy var testClient = PredictiveLocalModel()
    private var testRequest: WordCompletionRequest?
    private var firstWordMS: Int?
    private var waitingForWake = false
    private var testedModelID: String?
    private var testedExternal = false
    private let samplePrompt = "Спасибо за обратную "

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        source.addItems(withTitles: [L10n.t("prediction.source.managed"), L10n.t("prediction.source.external")])
        source.setAccessibilityLabel(L10n.t("prediction.source"))
        source.target = self
        source.action = #selector(changeSource)
        let sourceRow = NSStackView(views: [NSTextField(labelWithString: L10n.t("prediction.source")), source])
        addArrangedSubview(sourceRow)

        for item in PredictionRuntime.models {
            model.addItem(withTitle: "\(item.title) · \(L10n.size(item.sizeLabel))")
            model.lastItem?.representedObject = item.id
        }
        model.setAccessibilityLabel(L10n.t("prediction.weights"))
        model.target = self
        model.action = #selector(changeModel)
        action.target = self
        action.action = #selector(manageDownload)
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        for control in [model, action] as [NSControl] {
            modelRow.addArrangedSubview(control)
        }
        addArrangedSubview(modelRow)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        testButton.target = self
        testButton.action = #selector(testModel)
        compareButton.target = self
        compareButton.action = #selector(compareModels)
        addArrangedSubview(NSStackView(views: [testButton, compareButton]))
        testResult.font = .systemFont(ofSize: 12)
        testResult.isHidden = true
        addArrangedSubview(testResult)
        testResult.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        comparisonResults.orientation = .vertical
        comparisonResults.alignment = .leading
        comparisonResults.spacing = 8
        comparisonResults.isHidden = true
        addArrangedSubview(comparisonResults)
        comparisonResults.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                              name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                              name: .predictionRuntimeChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    @objc private func refresh() {
        let external = runtime.usesExternalServer
        source.selectItem(at: external ? 1 : 0)
        source.isEnabled = !runtime.isDownloading
        modelRow.isHidden = external
        model.selectItem(at: model.indexOfItem(withRepresentedObject: runtime.selectedModelID))
        model.isEnabled = !runtime.isDownloading
        let key: String
        if runtime.isDownloading { key = "prediction.cancelDownload" }
        else if runtime.hasSelectedModel { key = "prediction.deleteDownload" }
        else { key = "prediction.download" }
        action.title = L10n.t(key)
        let infillMessage = AppSettings.shared.predictionInfillEnabled
            ? "\n" + L10n.t(runtime.infillStatus.messageKey) : ""
        status.stringValue = runtime.statusText + infillMessage
        if testedModelID != nil && (external != testedExternal || runtime.selectedModelID != testedModelID ||
                                    !AppSettings.shared.predictiveLocalModelEnabled) {
            clearTest()
        }
        refreshTestButtons()
        if waitingForWake, runtime.canTestModel, let connection = runtime.connection() {
            beginReadyTest(connection)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearTest() }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window { clearTest() }
    }

    private func clearTest() {
        comparison?.cancel()
        comparison = nil
        testRequest?.cancel()
        testRequest = nil
        firstWordMS = nil
        testedModelID = nil
        waitingForWake = false
        testResult.stringValue = ""
        testResult.isHidden = true
        refreshTestButtons()
    }

    private func refreshTestButtons() {
        testButton.isEnabled = runtime.canTestModel && testRequest == nil && comparison == nil
        compareButton.title = L10n.t(comparison == nil ? "prediction.compare" : "prediction.compare.cancel")
        compareButton.isEnabled = comparison != nil || testButton.isEnabled
    }

    @objc private func testModel() { startTest(comparing: false) }

    @objc private func compareModels() {
        if comparison != nil {
            clearTest()
        } else {
            startTest(comparing: true)
        }
    }

    private func startTest(comparing: Bool) {
        guard runtime.canTestModel else { return }
        clearTest()
        // The request also identifies this test while the managed server wakes up.
        let request = WordCompletionRequest()
        testRequest = request
        if comparing { comparison = PredictionComparison() }
        testedExternal = runtime.usesExternalServer
        testedModelID = runtime.selectedModelID
        testResult.stringValue = L10n.t("prediction.probe.waiting")
        testResult.isHidden = false
        refreshTestButtons()
        if let connection = runtime.connection() {
            beginReadyTest(connection)
        } else {
            waitingForWake = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60)) { [weak self, weak request] in
                guard let self, let request, self.testRequest === request, self.waitingForWake else { return }
                self.endTest(message: L10n.t("prediction.modelNotReady"))
            }
        }
    }

    private func beginReadyTest(_ connection: PredictionConnection) {
        waitingForWake = false
        if let comparison {
            runComparison(comparison, connection: connection)
        } else if let testRequest {
            runTest(testRequest, connection: connection)
        }
    }

    private func runComparison(_ run: PredictionComparison, connection: PredictionConnection) {
        run.start(baseURL: connection.baseURL, apiKey: connection.apiKey, confidence: .forModel(connection.modelID)) { [weak self, weak run] completed, total in
            guard let self, let run, self.comparison === run else { return }
            // Each completed case is real use, even on a Mac where the full run takes a few minutes.
            _ = self.runtime.connection()
            self.testResult.stringValue = L10n.t("prediction.compare.progress", completed, total)
        } completion: { [weak self, weak run] result in
            guard let self, let run, self.comparison === run else { return }
            switch result {
            case let .success(summaries):
                self.updateComparisonResults(summaries)
                self.testResult.isHidden = true
                self.endTest(message: nil)
            case let .failure(error):
                self.endTest(message: L10n.t("prediction.compare.failed", error.localizedDescription))
            }
        }
    }

    private func updateComparisonResults(_ summaries: [PredictionComparison.Summary]) {
        let external = runtime.usesExternalServer
        let id = external ? "external" : runtime.selectedModelID
        let title = external ? L10n.t("prediction.source.external")
            : PredictionRuntime.models.first(where: { $0.id == id })?.title ?? id
        let key = NSUserInterfaceItemIdentifier(id)
        comparisonResults.arrangedSubviews.first(where: { $0.identifier == key })?.removeFromSuperview()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let headers = ["mode", "shown", "correct", "latency", "errors"]
        var rows: [[NSView]] = [headers.map { NSTextField(labelWithString: L10n.t("prediction.compare." + $0)) }]
        for result in summaries {
            let latency = result.firstP95MS.map { L10n.t("prediction.compare.ms", Int($0.rounded())) } ?? "—"
            let values = [L10n.t("prediction.compare." + result.mode), "\(result.shown)/\(result.cases)",
                          String(result.correct), latency, String(result.errors)]
            rows.append(values.map { NSTextField(labelWithString: $0) })
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 12
        grid.rowSpacing = 2
        grid.xPlacement = .leading
        grid.toolTip = L10n.t("prediction.compare.metrics")
        for (index, row) in rows.enumerated() {
            for case let label as NSTextField in row {
                label.font = .systemFont(ofSize: 11, weight: index == 0 ? .medium : .regular)
                label.isSelectable = true
            }
        }
        let report = NSStackView(views: [heading, grid])
        report.orientation = .vertical
        report.alignment = .leading
        report.spacing = 3
        report.identifier = key
        comparisonResults.addArrangedSubview(report)
        comparisonResults.isHidden = false
    }

    private func runTest(_ request: WordCompletionRequest, connection: PredictionConnection) {
        waitingForWake = false
        let started = ProcessInfo.processInfo.systemUptime
        testClient.predict(before: samplePrompt, contextWord: "обратную", completing: false,
                           endpoint: connection.baseURL, apiKey: connection.apiKey, request: request,
                           deadline: .now() + .seconds(5)) { [weak self] event in
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.testRequest === request, !request.isCancelled else { return }
                switch event {
                case let .partial(text):
                    self.showSample(text, elapsedMS: elapsedMS)
                case let .finished(text):
                    if let text { self.showSample(text, elapsedMS: elapsedMS) }
                    self.endTest(message: text == nil ? L10n.t("prediction.lowConfidence") : nil)
                case let .failed(key):
                    self.endTest(message: L10n.t(key))
                }
            }
        }
    }

    private func showSample(_ text: String, elapsedMS: Int) {
        if firstWordMS == nil { firstWordMS = elapsedMS }
        testResult.stringValue = L10n.t("prediction.probe.result", samplePrompt + text, firstWordMS ?? elapsedMS)
    }

    private func endTest(message: String?) {
        if let message { testResult.stringValue = message }
        testRequest = nil
        comparison = nil
        waitingForWake = false
        refreshTestButtons()
    }

    @objc private func changeSource() {
        runtime.usesExternalServer = source.indexOfSelectedItem == 1
        refresh()
    }

    @objc private func changeModel() {
        guard let id = model.selectedItem?.representedObject as? String else { return }
        runtime.selectedModelID = id
        refresh()
    }

    @objc private func manageDownload() {
        clearTest()
        if runtime.isDownloading { runtime.cancelDownload() }
        else if runtime.hasSelectedModel { runtime.deleteSelected() }
        else { runtime.downloadSelected() }
        refresh()
    }
}

enum PredictionGlossaryEditor {
    static func edit(settings: AppSettings) {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 144)
        let text = NSTextView(frame: frame)
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 6, height: 5)
        text.string = settings.predictionGlossary
        text.setAccessibilityLabel(L10n.t("completion.glossary"))
        text.setAccessibilityIdentifier("keyboop-prediction-glossary")

        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text

        let alert = NSAlert()
        alert.messageText = L10n.t("completion.glossary")
        alert.informativeText = L10n.t("completion.glossary.help")
        alert.accessoryView = scroll
        alert.addButton(withTitle: L10n.t("completion.glossary.save"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.window.initialFirstResponder = text
        if alert.runModal() == .alertFirstButtonReturn {
            settings.predictionGlossary = text.string
        }
    }
}

/// A regular editable text field exercises the global event tap, AX caret reader and real accept shortcut.
final class PredictionPreviewView: NSStackView {
    private let diagnostic = NSTextField(wrappingLabelWithString: "")
    private var permissionKey: String?

    init() {
        super.init(frame: .zero)
        alignment = .leading
        orientation = .vertical
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let field = NSTextField(string: "")
        field.placeholderString = L10n.t("prediction.preview.example")
        field.setAccessibilityLabel(L10n.t("prediction.preview"))
        field.setAccessibilityIdentifier("keyboop-prediction-preview")
        addArrangedSubview(field)
        diagnostic.font = .systemFont(ofSize: 12)
        diagnostic.textColor = .secondaryLabelColor
        addArrangedSubview(diagnostic)
        for view in [field, diagnostic] {
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: .predictionDiagnosticChanged, object: nil)
        center.addObserver(self, selector: #selector(refreshPermissions), name: NSApplication.didBecomeActiveNotification, object: NSApp)
        center.addObserver(self, selector: #selector(refresh), name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refreshPermissions() }
    }

    @objc private func refreshPermissions() {
        if !Permissions.isTrusted() { permissionKey = "prediction.preview.needAX" }
        else if !Permissions.inputMonitoringGranted() { permissionKey = "prediction.preview.needInput" }
        else { permissionKey = nil }
        refresh()
    }

    @objc private func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        if !AppSettings.shared.wordSuggestionsEnabled {
            diagnostic.stringValue = L10n.t("prediction.preview.enable")
        } else if let permissionKey {
            diagnostic.stringValue = L10n.t(permissionKey)
        } else {
            let result = PredictionDiagnostic.shared
            diagnostic.stringValue = [result.lastKey, result.geometryKey].compactMap { $0 }.map { L10n.t($0) }.joined(separator: " ")
        }
    }
}
