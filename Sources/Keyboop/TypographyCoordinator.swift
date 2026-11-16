import AppKit
import ApplicationServices
import Carbon

/// Запись для точной отмены последнего автоматического типографического преобразования (FR-09).
struct TypographyUndoEntry: Equatable {
    let bundleID: String
    let originalSuffix: String
    let replacedSuffix: String
    let createdAt: Date
}

/// Координатор умной типографики KB-021 (§5):
/// - ведёт локальный скользящий буфер хвоста без блокирующих AX-вызовов в `CGEventTap`
/// - запускает правила типографики строго ПОСЛЕ раскладки и опечаток
/// - обеспечивает безопасную отмену (FR-09) и ручное форматирование выделения с предпросмотром (FR-07)
final class TypographyCoordinator {
    static let shared = TypographyCoordinator()

    private let store = TypographySettingsStore.shared
    private let maxTailChars = 160

    private var typingTail = ""
    private var lastUndoEntry: TypographyUndoEntry?
    private var suppressUntilResetOrNewToken = false
    private var isApplying = false

    // MARK: - Синхронизация с вводом (main queue)

    func appendTypedText(_ s: String) {
        guard !s.isEmpty else { return }
        typingTail += s
        trimTail()
        // Если пользователь продолжает печатать после отмены/исправления: проверяем актуальность undo.
        invalidateUndoIfDiverged()
        suppressUntilResetOrNewToken = false
    }

    func appendBoundary(_ ws: String) {
        guard !ws.isEmpty else { return }
        typingTail += ws
        trimTail()
        invalidateUndoIfDiverged()
        suppressUntilResetOrNewToken = false
    }

    func applyBackspace(eraseAllWord: Bool) {
        if eraseAllWord {
            resetContext()
            return
        }
        if !typingTail.isEmpty {
            typingTail.removeLast()
        } else {
            lastUndoEntry = nil
        }
        invalidateUndoIfDiverged()
    }

    func replaceTail(oldSuffix: String, newSuffix: String) {
        if !oldSuffix.isEmpty, typingTail.hasSuffix(oldSuffix) {
            typingTail.removeLast(oldSuffix.count)
            typingTail += newSuffix
        } else {
            typingTail += newSuffix
        }
        trimTail()
        invalidateUndoIfDiverged()
    }

    func resetContext() {
        typingTail = ""
        lastUndoEntry = nil
        suppressUntilResetOrNewToken = false
    }

    private func trimTail() {
        if typingTail.count > maxTailChars {
            typingTail.removeFirst(typingTail.count - maxTailChars)
        }
    }

    private func invalidateUndoIfDiverged() {
        guard let entry = lastUndoEntry else { return }
        if !typingTail.hasSuffix(entry.replacedSuffix) {
            lastUndoEntry = nil
        }
    }

    // MARK: - Автоматическая обработка при наборе

    /// Проверяет и применяет типографические правила к хвосту набора.
    /// Вызывается ПОСЛЕ завершения проверки раскладки и опечаток (§5 приоритет 5).
    func evaluateTypingIfNeeded(
        resolvedContext: ResolvedInputContext,
        activeLayoutHint: String?,
        beginSynthetic: () -> Void,
        endSynthetic: @escaping () -> Void
    ) {
        guard resolvedContext.effectiveTypography,
              !Pause.active,
              !NSApp.isActive,
              !SnippetInsertionCoordinator.shared.isFormActive,
              !suppressUntilResetOrNewToken,
              !isApplying,
              !typingTail.isEmpty else { return }

        guard store.enabled else { return }

        let context = TypographyContext(
            mode: .typing,
            languageMode: store.language,
            activeLayoutHint: activeLayoutHint,
            bundleID: resolvedContext.bundleID,
            rules: store.effectiveRules()
        )

        guard let patch = TypographyEngine.analyzeTypingTail(typingTail, context: context) else { return }
        guard SecureInputPolicy.canWrite("typography-auto -\(patch.deleteCount)+\(patch.replacementSuffix.count)") else {
            return
        }

        isApplying = true
        beginSynthetic()

        let origSuffix = patch.originalSuffix
        let replSuffix = patch.replacementSuffix
        let bundleID = resolvedContext.bundleID

        TextReplacer.replace(deleteCount: patch.deleteCount, with: replSuffix, firstKeySettleMicros: 35_000) { [weak self] in
            guard let self else {
                endSynthetic()
                return
            }
            if self.typingTail.hasSuffix(origSuffix) {
                self.typingTail.removeLast(origSuffix.count)
                self.typingTail += replSuffix
                self.trimTail()
            }
            self.lastUndoEntry = TypographyUndoEntry(
                bundleID: bundleID,
                originalSuffix: origSuffix,
                replacedSuffix: replSuffix,
                createdAt: Date()
            )
            self.isApplying = false
            kbLog("typography: авто -\(patch.deleteCount)+\(replSuffix.count) симв. (\(patch.appliedRuleIDs.map(\.rawValue).joined(separator: ",")))")
            endSynthetic()
        }
    }

    // MARK: - Безопасная отмена последнего исправления (FR-09)

    func undoLastTypography(
        currentBundleID: String,
        beginSynthetic: () -> Void,
        endSynthetic: @escaping () -> Void
    ) -> Bool {
        guard !NSApp.isActive,
              !isApplying,
              let entry = lastUndoEntry,
              entry.bundleID == currentBundleID,
              typingTail.hasSuffix(entry.replacedSuffix) else {
            return false
        }

        guard SecureInputPolicy.canWrite("typography-undo -\(entry.replacedSuffix.count)+\(entry.originalSuffix.count)") else {
            return false
        }

        isApplying = true
        suppressUntilResetOrNewToken = true
        lastUndoEntry = nil
        beginSynthetic()

        TextReplacer.replace(
            deleteCount: entry.replacedSuffix.count,
            with: entry.originalSuffix,
            firstKeySettleMicros: 35_000
        ) { [weak self] in
            guard let self else {
                endSynthetic()
                return
            }
            if self.typingTail.hasSuffix(entry.replacedSuffix) {
                self.typingTail.removeLast(entry.replacedSuffix.count)
                self.typingTail += entry.originalSuffix
                self.trimTail()
            }
            self.isApplying = false
            kbLog("typography: отмена -\(entry.replacedSuffix.count)+\(entry.originalSuffix.count) симв.")
            endSynthetic()
        }
        return true
    }
}
