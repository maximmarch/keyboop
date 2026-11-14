import AppKit
import Carbon

/// KB-022 · Живая среда очереди вставки: проверки контекста, печать через Engine/TextReplacer,
/// подтверждение через Accessibility, тосты. Плюс общие действия для меню, окна и хоткея.
final class PasteQueueSystem: PasteQueueEnvironment {
    static let shared = PasteQueueSystem()

    /// Исполнитель печати. Ставит Engine: он держит `muted` на время полёта синтетики, чтобы
    /// вставленный текст не попал в авто-переключение, опечатки и типографику как новый набор.
    /// Возвращает false, если Engine занят своей синтетикой (тогда ничего не отправлено).
    var executor: ((String, @escaping (TextReplacer.QueueTypingResult) -> Void) -> Bool)?

    private init() {}

    /// Подключить среду к координатору и применить настройки. Зовёт Engine при старте.
    func install() {
        PasteQueueSettingsStore.shared.apply()
        PasteQueueCoordinator.shared.environment = self
    }

    // MARK: PasteQueueEnvironment

    func preflight() -> PasteQueueRefusal? {
        if Pause.active { return .keyboopPaused }
        // Курсор в нашем окне: печатать туда чужой текст нельзя, угадывать «предыдущее окно» —
        // гонка с фокусом, которую проект не заводит (см. Engine.pasteLastDictation).
        if NSApp.isActive { return .ownWindow }
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return .noFocus }
        if TextReplacer.isRemoteDesktopBundleID(bid) { return .unsupportedTarget }
        // Человек выключил Keyboop для этой программы — уважаем это и для явной вставки.
        let ctx = RuleResolver.resolveCurrent(bundleID: bid)
        if ctx.appHardExcluded, Engine.appMode(for: bid) == "off" { return .keyboopOff }
        if !SecureInputPolicy.canWrite("очередь вставки: проверка") { return .secureInput }
        // Фокус проверяем В МОМЕНТ вставки: после смены приложения текст уходит только туда, где
        // система видит фокусный элемент.
        if !AXScreenCheck.hasFocusedElement() { return .noFocus }
        return nil
    }

    func send(_ text: String, completion: @escaping (PasteQueueSendResult) -> Void) {
        guard let executor else { completion(.refused(.unsupportedTarget)); return }
        let probe = Self.confirmationSuffix(text)
        // Если хвост уже стоит перед кареткой ДО вставки, «увидели после» ничего не докажет.
        let ambiguous = probe.map { AXScreenCheck.caretEndsWith($0) == true } ?? true
        let started = executor(text) { result in
            switch result {
            case .refusedSecure:      completion(.refused(.secureInput))
            case .refusedUnsupported: completion(.refused(.unsupportedTarget))
            case .partial:            completion(.partial)
            case .sent:
                guard let probe, !ambiguous else { completion(.sent(confirmed: false)); return }
                // Поле принимает текст асинхронно — даём ему мгновение, затем спрашиваем экран.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    completion(.sent(confirmed: AXScreenCheck.caretEndsWith(probe) == true))
                }
            }
        }
        if !started { completion(.refused(.busy)) }
    }

    /// Хвост последней строки для сверки с экраном: переводы строк в AX у разных программ
    /// выглядят по-разному, поэтому сравниваем только текст после последнего из них.
    static func confirmationSuffix(_ text: String) -> String? {
        let lastLine = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).last
            .map(String.init) ?? text
        let tail = String(lastLine.suffix(24))
        return tail.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tail
    }

    func announce(_ a: PasteQueueAnnouncement) {
        VoiceIndicator.shared.showToast(Self.message(for: a))
    }

    func log(_ message: String) { kbLog(message) }

    static func message(for a: PasteQueueAnnouncement) -> String {
        switch a {
        case .progress(let p, let t, let next):
            return next.map { L10n.t("pq.progress", p, t, $0) } ?? L10n.t("pq.completed", t, t)
        case .sentUnconfirmed(let p, let t, let next):
            return L10n.t("pq.sentUnconfirmed", p, t, next ?? "—")
        case .completed(let t):     return L10n.t("pq.completed", t, t)
        case .refused(let r):       return refusalText(r)
        case .partial:              return L10n.t("pq.partial")
        case .pickedSent(let c):    return L10n.t(c ? "pq.picked" : "pq.pickedUnconfirmed")
        case .allSent(let n, _):    return L10n.t("pq.allSent", n)
        }
    }

    static func refusalText(_ r: PasteQueueRefusal) -> String {
        switch r {
        case .empty:     return L10n.t("pq.empty")
        case .completed: return L10n.t("pq.completed", PasteQueueStore.shared.items.count, PasteQueueStore.shared.items.count)
        default:         return L10n.t("pq.refused.\(r.rawValue)")
        }
    }

    static func addErrorText(_ e: PasteQueueAddError) -> String {
        switch e {
        case .empty:                return L10n.t("pq.add.empty")
        case .tooLarge:             return L10n.t("pq.add.tooLarge")
        case .queueFull:            return L10n.t("pq.add.queueFull")
        case .concealed:            return L10n.t("pq.add.concealed")
        case .secureInput:          return L10n.t("pq.add.secureInput")
        case .noText:               return L10n.t("pq.add.noText")
        case .selectionUnavailable: return L10n.t("pq.add.selectionUnavailable")
        }
    }

    // MARK: действия (меню, окно, хоткей)

    static func addClipboard() {
        report(ClipboardQueueAdapter.readClipboard().map { [$0] }, source: "буфер")
    }

    static func addSelection() {
        report(ClipboardQueueAdapter.readSelection().map { [$0] }, source: "выделение")
    }

    static func addHistory(_ entries: [VoiceHistory.Entry]) {
        report(.success(ClipboardQueueAdapter.items(from: entries)), source: "история")
    }

    private static func report(_ r: Result<[PasteQueueItem], PasteQueueAddError>, source: String) {
        switch r {
        case .failure(let e):
            kbLog("очередь вставки: \(source) не добавлен (\(e))")   // причина, не содержимое
            VoiceIndicator.shared.showToast(addErrorText(e))
        case .success(let items):
            let store = PasteQueueStore.shared
            let res = store.addBatch(items)
            kbLog("очередь вставки: +\(res.added) (\(source)), всего \(store.items.count)")
            if res.added == 0, let e = res.skipped.first {
                VoiceIndicator.shared.showToast(addErrorText(e)); return
            }
            var msg = L10n.t("pq.added", res.added, store.items.count)
            if !res.skipped.isEmpty { msg += L10n.t("pq.skipped", res.skipped.count) }
            VoiceIndicator.shared.showToast(msg)
        }
    }

    /// Вставка, запущенная из НАШЕГО окна (кнопки панели). Окно Keyboop прячется, фокус
    /// возвращается программе, которая была под ним, и только после этого идёт обычная транзакция
    /// со всеми проверками — включая наличие фокусного поля. Не угадали фокус — честный отказ.
    static func runAfterYieldingFocus(_ action: @escaping () -> Void) {
        guard NSApp.isActive else { action(); return }
        var token: NSObjectProtocol?
        var done = false
        let fire = {
            guard !done else { return }
            done = true
            if let token { NotificationCenter.default.removeObserver(token) }
            // Дать системе довести смену фокуса до поля программы.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: action)
        }
        token = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                       object: nil, queue: .main) { _ in fire() }
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { fire() }
    }
}
