import AppKit
import Carbon

protocol PasteboardReading {
    var pasteboardTypeNames: [String] { get }
    var pasteboardPlainString: String? { get }
}

extension NSPasteboard: PasteboardReading {
    var pasteboardTypeNames: [String] {
        var names = Set((types ?? []).map(\.rawValue))
        pasteboardItems?.forEach { item in item.types.forEach { names.insert($0.rawValue) } }
        return Array(names)
    }
    var pasteboardPlainString: String? { string(forType: .string) }
}

/// KB-022 · Мост между очередью вставки и существующими источниками: историей, буфером обмена и
/// выделением. Собственного наблюдения за буфером здесь нет и не будет — история уже ведёт его
/// (`ClipboardWatcher`), а очередь берёт из неё готовые записи.
enum ClipboardQueueAdapter {
    /// Записи истории → самостоятельные снимки (FR-02). Строка копируется по значению: удаление
    /// записи из истории или новая запись в буфере элемент очереди не трогают.
    static func items(from entries: [VoiceHistory.Entry]) -> [PasteQueueItem] {
        entries.map { PasteQueueItem(text: $0.text, source: .history) }
    }

    /// «Добавить содержимое буфера в очередь». Буфер читается ТОЛЬКО по явной команде человека.
    /// Секреты менеджеров паролей (`ClipboardCapturePolicy.concealedTypes`) не берём вовсе, при
    /// поднятом Secure Input буфер не читаем.
    static func readClipboard(pasteboard: PasteboardReading = NSPasteboard.general) -> Result<PasteQueueItem, PasteQueueAddError> {
        if IsSecureEventInputEnabled() { return .failure(.secureInput) }
        let types = pasteboard.pasteboardTypeNames
        if types.contains(where: { ClipboardCapturePolicy.concealedTypes.contains($0) }) {
            return .failure(.concealed)
        }
        guard let text = pasteboard.pasteboardPlainString else { return .failure(.noText) }
        if let e = PasteQueueStore.validate(text) { return .failure(e) }
        return .success(PasteQueueItem(text: text, source: .clipboard))
    }

    /// «Добавить выделение в очередь» — только через Accessibility, системный буфер не меняется.
    static func readSelection() -> Result<PasteQueueItem, PasteQueueAddError> {
        if IsSecureEventInputEnabled() { return .failure(.secureInput) }
        guard let sel = SelectionText.readAXOnly() else { return .failure(.selectionUnavailable) }
        if let e = PasteQueueStore.validate(sel.text) { return .failure(e) }
        return .success(PasteQueueItem(text: sel.text, source: .selection))
    }
}
