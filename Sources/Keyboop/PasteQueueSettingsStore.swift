import Foundation

/// KB-022 · Настройки очереди вставки. ТОЛЬКО параметры поведения — ни одного байта содержимого
/// очереди здесь нет и быть не должно (FR-09: очередь не сохраняется в обычные настройки).
final class PasteQueueSettingsStore {
    static let shared = PasteQueueSettingsStore()

    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { d = defaults }

    /// Сочетание «Вставить следующий элемент очереди». По умолчанию НЕ назначено (FR-05).
    var hotkeyKeyCode: Int {
        get { d.object(forKey: "pasteQueueKeyCode") == nil ? -1 : d.integer(forKey: "pasteQueueKeyCode") }
        set { d.set(newValue, forKey: "pasteQueueKeyCode") }
    }
    var hotkeyModifiers: UInt64 {
        get { UInt64(bitPattern: Int64(d.integer(forKey: "pasteQueueMods"))) }
        set { d.set(Int(bitPattern: UInt(newValue)), forKey: "pasteQueueMods") }
    }
    var hotkeyLabel: String {
        get { d.string(forKey: "pasteQueueKeyLabel") ?? "" }
        set { d.set(newValue, forKey: "pasteQueueKeyLabel") }
    }
    var hotkeyEnabled: Bool { hotkeyKeyCode >= 0 }

    /// Что делать после последнего элемента. По умолчанию — оставить очередь и позицию.
    var completionMode: PasteQueueCompletionMode {
        get { PasteQueueCompletionMode(rawValue: d.string(forKey: "pasteQueueCompletion") ?? "") ?? .keepPosition }
        set { d.set(newValue.rawValue, forKey: "pasteQueueCompletion"); apply() }
    }
    /// Режим Б: двигает ли ручная вставка выбранного элемента позицию. По умолчанию — нет.
    var manualPickAdvances: Bool {
        get { d.bool(forKey: "pasteQueueManualAdvances") }
        set { d.set(newValue, forKey: "pasteQueueManualAdvances"); apply() }
    }
    /// Разделитель режима В («вставить все»). Это настройка, а не содержимое очереди.
    var joinDelimiter: String {
        get { d.string(forKey: "pasteQueueDelimiter") ?? "; " }
        set { d.set(newValue, forKey: "pasteQueueDelimiter") }
    }

    /// Перенести поведенческие настройки в живое хранилище очереди.
    func apply(to store: PasteQueueStore = .shared) {
        store.completionMode = completionMode
        store.manualPickAdvances = manualPickAdvances
    }
}
