import AppKit
import Carbon

/// Coordinates explicit selection checks and optional proofreading after a typing pause.
final class SageCorrectionCoordinator {
    static let shared = SageCorrectionCoordinator()

    private var checking = false
    private var preview: SageCorrectionPreview?
    private let typingWorker = DispatchQueue(label: "ru.keyboop.sage-typing", qos: .userInitiated)
    private var suggestionBanner: AppBanner?
    private var typingDebounce: DispatchWorkItem?
    private var typingID: UUID?
    private var runningTypingID: UUID?
    private var typingAt: TimeInterval = 0

    func cancelTyping(through eventTime: TimeInterval = .infinity) {
        guard typingID != nil, typingAt <= eventTime else { return }
        typingID = nil
        typingDebounce?.cancel()
        typingDebounce = nil
        if let runningTypingID {
            SageRuntime.shared.cancelTypingCorrection(runningTypingID)
            self.runningTypingID = nil
        }
        suggestionBanner?.dismiss()
        suggestionBanner = nil
    }

    func observeTyping(_ key: Character, in pid: pid_t, at eventTime: TimeInterval, mode: SageTypingMode,
                       isEligible: @escaping () -> Bool, didApply: @escaping () -> Void) {
        guard mode != .off, !checking, preview == nil else { return }
        let id = UUID()
        typingID = id
        typingAt = eventTime
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.typingID == id else { return }
            self.typingDebounce = nil
            guard isEligible(), AppSettings.shared.sageTypingMode == mode, SageRuntime.shared.state == .ready else {
                self.cancelTyping()
                return
            }
            self.typingWorker.async { [weak self] in
                let target = SelectionText.typingTarget(in: pid, afterTyping: key)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.typingID == id else { return }
                    guard let target, isEligible(), AppSettings.shared.sageTypingMode == mode else {
                        self.cancelTyping()
                        return
                    }
                    self.proofread(target, id: id, mode: mode, isEligible: isEligible, didApply: didApply)
                }
            }
        }
        typingDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(850), execute: work)
    }

    private func proofread(_ target: SelectionText.TypingTarget, id: UUID, mode: SageTypingMode,
                           isEligible: @escaping () -> Bool, didApply: @escaping () -> Void) {
        runningTypingID = id
        SageRuntime.shared.correct(target.text, requestID: id) { [weak self] result in
            guard let self, self.typingID == id else { return }
            self.runningTypingID = nil
            guard isEligible(), AppSettings.shared.sageTypingMode == mode,
                  case let .success(answer) = result,
                  let edit = SageCorrectionText.typingEdit(from: target.text, to: answer) else {
                self.cancelTyping()
                return
            }
            let apply = { [weak self] in
                guard let self, self.typingID == id else { return }
                self.cancelTyping()
                guard isEligible(), AppSettings.shared.sageTypingMode == mode,
                      target.replace(edit) else { return }
                didApply()
            }
            switch mode {
            case .automatic:
                apply()
            case .confirmation:
                guard target.isCurrent() else { self.cancelTyping(); return }
                let corrected = (target.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                let banner = AppBanner()
                self.suggestionBanner = banner
                banner.show(
                    title: L10n.t("sage.typing.preview"), body: corrected,
                    actions: [.init(title: L10n.t("typo.preview.apply"), coral: true, handler: apply)],
                    autoDismiss: 12,
                    shouldPresent: { [weak self] in self?.typingID == id && isEligible() },
                    onAbandon: { [weak self] in
                        guard let self, self.typingID == id else { return }
                        self.cancelTyping()
                    }
                )
            case .off:
                self.cancelTyping()
            }
        }
    }

    func checkSelection(in app: NSRunningApplication?, openSettings: () -> Void, didApply: @escaping () -> Void) {
        guard !checking, preview == nil else { show("sage.error.busy"); return }
        cancelTyping()
        guard AppSettings.shared.sageEnabled else { openSettings(); return }
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
            guard AppSettings.shared.sageEnabled else { return }
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
        let panel = SageCorrectionPreview(
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
        guard AppSettings.shared.sageEnabled else { checking = false; return }
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
