import AppKit
import Carbon

/// Invoked explicitly from the status menu. The model never observes ongoing typing.
final class SageCorrectionCoordinator {
    static let shared = SageCorrectionCoordinator()

    private var checking = false
    private var preview: TypographyPreviewPanelController?

    func checkSelection(in app: NSRunningApplication?, openSettings: () -> Void, didApply: @escaping () -> Void) {
        guard !checking, preview == nil else { show("sage.error.busy"); return }
        switch SageRuntime.shared.state {
        case .missing, .failed:
            openSettings()
            return
        case .downloading:
            show("sage.status.downloading")
            return
        case .unavailable:
            show("sage.error.unavailable")
            return
        case .ready:
            break
        }

        guard !IsSecureEventInputEnabled() else { show("typo.sel.secure"); return }
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let selection = SelectionText.correctionTarget(in: app.processIdentifier) else {
            show("sage.selection.required")
            return
        }
        guard selection.text.utf8.count <= SageRuntime.maxInputBytes else { show("sage.error.tooLong"); return }
        guard SageCorrectionText.supports(selection.text) else { show("sage.selection.russian"); return }

        let caret = CaretLocator.caretScreenRect()
        checking = true
        show("sage.checking")
        SageRuntime.shared.correct(selection.text) { [weak self] result in
            guard let self else { return }
            self.checking = false
            guard selection.isCurrent() else { self.show("sage.selection.changed"); return }
            switch result {
            case .failure(let error):
                self.showMessage(error.localizedDescription)
            case .success(let answer):
                guard let corrected = SageCorrectionText.validated(answer, for: selection.text) else {
                    self.show("sage.selection.unsafeResult")
                    return
                }
                guard !corrected.utf16.elementsEqual(selection.text.utf16) else {
                    self.show("typo.sel.noChanges")
                    return
                }
                self.showPreview(corrected, for: selection, in: app, near: caret, didApply: didApply)
            }
        }
    }

    private func showPreview(_ corrected: String, for selection: SelectionText.CorrectionTarget,
                             in app: NSRunningApplication, near caret: NSRect?, didApply: @escaping () -> Void) {
        let panel = TypographyPreviewPanelController(
            originalText: selection.text,
            transformedText: corrected,
            title: L10n.t("sage.command"),
            summary: L10n.t("sage.preview"),
            onApply: { [weak self] in
                guard let self else { return }
                self.preview = nil
                guard !app.isTerminated else { self.show("sage.selection.changed"); return }
                self.checking = true
                app.activate(options: [])
                self.apply(corrected, to: selection, until: .now() + .milliseconds(450), didApply: didApply)
            },
            onCancel: { [weak self] in
                self?.preview = nil
                app.activate(options: [])
            }
        )
        preview = panel
        panel.show(nearCaretRect: caret)
    }

    private func apply(_ corrected: String, to selection: SelectionText.CorrectionTarget,
                       until deadline: DispatchTime, didApply: @escaping () -> Void) {
        if !NSApp.isActive, selection.isCurrent() {
            checking = false
            if selection.replace(with: corrected) {
                didApply()
            } else {
                show("sage.selection.writeFailed")
            }
            return
        }
        guard DispatchTime.now() < deadline else {
            checking = false
            show("sage.selection.changed")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            self?.apply(corrected, to: selection, until: deadline, didApply: didApply)
        }
    }

    private func show(_ key: String) {
        showMessage(L10n.t(key))
    }

    private func showMessage(_ message: String) {
        AppBanner.shared.show(title: L10n.t("sage.command"), body: message, autoDismiss: 3.5)
    }
}
