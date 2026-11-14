import Foundation

// KB-022 · Paste Queue — модель элемента очереди последовательной вставки.
//
// ⚠️ ЭТОТ ФАЙЛ НАМЕРЕННО БЕЗ AppKit. Модель, хранилище и транзакции очереди собираются отдельным
// юнит-тестом (`swiftc` без всего приложения), поэтому сюда нельзя тянуть ни NSPasteboard, ни
// Accessibility. Всё системное живёт в `ClipboardQueueAdapter.swift` и `PasteQueueSystem.swift`.

/// Откуда элемент попал в очередь. Только для подписи в интерфейсе: само исходное приложение,
/// его окно и прочий контекст здесь не хранятся.
enum PasteQueueSource: String, Equatable {
    case clipboard   // «Добавить содержимое буфера в очередь»
    case history     // из истории буфера/диктовок
    case selection   // «Добавить выделение в очередь» через Accessibility
    case manual      // набрано или исправлено руками в окне очереди
}

/// Что известно о вставке конкретного элемента.
enum PasteQueueItemState: Equatable {
    case pending          // ещё не вставляли
    case confirmed        // Accessibility подтвердил, что текст появился в поле
    case sentUnconfirmed  // события отправлены, но целевое приложение подтверждения не даёт
    case partial          // ошибка посреди отправки: текст мог вставиться частично
}

/// Что делать, когда вставлен последний элемент (FR-08).
enum PasteQueueCompletionMode: String, CaseIterable {
    case keepPosition   // оставить очередь и позицию (по умолчанию)
    case restart        // начать сначала
    case clear          // очистить очередь
}

/// Самостоятельный снимок текста (FR-02). Строка в Swift — значение, поэтому изменение буфера
/// обмена или удаление записи из истории этот элемент не трогает по построению.
struct PasteQueueItem: Equatable, Identifiable {
    let id: UUID
    var text: String
    let source: PasteQueueSource
    let createdAt: Date
    var isSensitive: Bool
    var label: String?
    var state: PasteQueueItemState = .pending

    init(id: UUID = UUID(), text: String, source: PasteQueueSource, createdAt: Date = Date(),
         isSensitive: Bool = false, label: String? = nil) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.isSensitive = isSensitive
        self.label = label
    }

    /// Короткая подпись для индикатора и списка. Приватный элемент наружу не показывается вовсе.
    func preview(maxLength: Int = 40, masked: String = "••••••") -> String {
        if isSensitive { return masked }
        if let label, !label.isEmpty { return label }
        let flat = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ⏎ ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}

/// Пределы MVP (FR-10).
enum PasteQueueLimits {
    static let maxItems = 50
    static let maxItemBytes = 65_536   // 64 КиБ UTF-8 на элемент
}

/// Почему элемент не добавлен. Сам текст в причину не попадает никогда.
enum PasteQueueAddError: Error, Equatable {
    case empty
    case tooLarge
    case queueFull
    case concealed       // менеджер паролей / скрытое содержимое
    case secureInput     // открыто поле пароля — буфер не читаем
    case noText          // в буфере нет текста
    case selectionUnavailable
}
