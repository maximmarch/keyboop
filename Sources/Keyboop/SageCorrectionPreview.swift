import AppKit

final class SageCorrectionPreview: NSObject, NSWindowDelegate {
    private let originalText: String
    private let transformedText: String
    private let title: String
    private let summary: String
    private let onApply: () -> Void
    private let onCancel: () -> Void

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var finished = false

    init(
        originalText: String,
        transformedText: String,
        title: String,
        summary: String,
        onApply: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalText = originalText
        self.transformedText = transformedText
        self.title = title
        self.summary = summary
        self.onApply = onApply
        self.onCancel = onCancel
        super.init()
    }

    deinit {
        removeKeyMonitor()
    }

    func show(nearCaretRect caretRect: NSRect?) {
        let p = buildPanel()
        self.panel = p
        positionPanel(p, nearCaretRect: caretRect)
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private func buildPanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = title
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let summary = NSTextField(labelWithString: self.summary)
        summary.font = .systemFont(ofSize: 12, weight: .semibold)
        summary.textColor = .secondaryLabelColor

        func makeBox(titleKey: String, content: String, dimmed: Bool) -> NSView {
            let lbl = NSTextField(labelWithString: L10n.t(titleKey))
            lbl.font = .systemFont(ofSize: 11, weight: .semibold)
            lbl.textColor = .secondaryLabelColor

            let tv = NSTextView()
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.font = .systemFont(ofSize: 12.5)
            tv.textColor = dimmed ? .secondaryLabelColor : .labelColor
            tv.string = content
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true

            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = true
            sv.borderType = .bezelBorder
            sv.drawsBackground = true
            sv.backgroundColor = NSColor.controlBackgroundColor
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.heightAnchor.constraint(equalToConstant: 96).isActive = true

            let stack = NSStackView(views: [lbl, sv])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            sv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return stack
        }

        let beforeBox = makeBox(titleKey: "typo.preview.before", content: originalText, dimmed: true)
        let afterBox = makeBox(titleKey: "typo.preview.after", content: transformedText, dimmed: false)

        let cancelBtn = NSButton(title: L10n.t("sites.ed.cancel"), target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        let applyBtn = NSButton(title: L10n.t("typo.preview.apply"), target: self, action: #selector(applyClicked))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"

        let btnRow = NSStackView(views: [NSView(), cancelBtn, applyBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 8

        let main = NSStackView(views: [summary, beforeBox, afterBox, btnRow])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false

        beforeBox.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        afterBox.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        btnRow.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true

        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: 480),
        ])

        p.contentView = root
        p.layoutIfNeeded()
        return p
    }

    private func positionPanel(_ p: NSPanel, nearCaretRect caretRect: NSRect?) {
        let size = p.frame.size
        if let caretRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            var x = caretRect.minX
            var y = caretRect.minY - size.height - 8
            if y < vf.minY + 12 { y = min(vf.maxY - size.height - 12, caretRect.maxY + 8) }
            x = min(max(x, vf.minX + 12), vf.maxX - size.width - 12)
            y = min(max(y, vf.minY + 12), vf.maxY - size.height - 12)
            p.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 40))
    }

    @objc private func applyClicked() {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onApply()
    }

    @objc private func cancelClicked() {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        onCancel()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        panel = nil
        onCancel()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 53 { self.cancelClicked(); return nil }
            if event.keyCode == 36 { self.applyClicked(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
