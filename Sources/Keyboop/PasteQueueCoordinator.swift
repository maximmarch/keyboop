import Foundation

// KB-022 · Paste Queue — транзакции вставки.
//
// Алгоритм (FR-06): есть ли следующий элемент → допускает ли контекст вставку → операция с
// уникальным идентификатором → прямая печать Unicode → статус → продвижение по политике →
// ненавязчивое уведомление.
//
// Система (AX, TextReplacer, тосты) спрятана за `PasteQueueEnvironment`: так транзакции
// проверяются юнит-тестом без приложения, а живая реализация лежит в `PasteQueueSystem.swift`.
//
// ⚠️ ПРАВИЛА, КОТОРЫЕ ЗДЕСЬ НЕЛЬЗЯ ОСЛАБЛЯТЬ.
//  • Отказ до отправки — позиция не меняется.
//  • Частичная отправка — пауза и предупреждение, НИКАКОГО автоматического повтора (дубликаты).
//  • Никакого запасного пути через системный буфер обмена: поле не принимает Unicode — говорим
//    об этом словами.
//  • Текст элементов не пишется в лог: только длины и номера.
//
// ⚠️ БЕЗ AppKit — файл собирается в юнит-тест отдельно от приложения.

/// Что показать человеку после действия. Локализует живая среда.
enum PasteQueueAnnouncement: Equatable {
    case progress(position: Int, total: Int, nextPreview: String?)   // «2 / 3 · Следующий: …»
    case sentUnconfirmed(position: Int, total: Int, nextPreview: String?)
    case completed(total: Int)                                       // «Очередь завершена: 3 из 3»
    case refused(PasteQueueRefusal)
    case partial                                                     // «Вставка могла выполниться частично»
    case pickedSent(confirmed: Bool)
    case allSent(count: Int, confirmed: Bool)
}

protocol PasteQueueEnvironment: AnyObject {
    /// Проверка контекста ДО отправки: пауза, Secure Input, своё окно, фокус, правила.
    func preflight() -> PasteQueueRefusal?
    /// Напечатать текст безопасной прямой вставкой Unicode и сообщить итог (на главном потоке).
    func send(_ text: String, completion: @escaping (PasteQueueSendResult) -> Void)
    func announce(_ a: PasteQueueAnnouncement)
    func log(_ message: String)
}

final class PasteQueueCoordinator {
    static let shared = PasteQueueCoordinator(store: .shared)

    let store: PasteQueueStore
    /// Живую среду подключает Engine при старте; пока её нет, вставка честно отказывает.
    weak var environment: PasteQueueEnvironment?

    init(store: PasteQueueStore) { self.store = store }

    /// Режим А — следующий элемент (горячая клавиша, меню, кнопка панели).
    func pasteNext() { run(.next) }
    /// Режим Б — выбранный элемент.
    func paste(itemID: UUID) { run(.pick(itemID)) }
    /// Режим В — все элементы одним блоком через разделитель.
    func pasteAll(delimiter: String) { run(.all(delimiter: delimiter)) }

    private func run(_ kind: PasteQueueOperationKind) {
        guard let env = environment else {
            store.noteRefusal(.unsupportedTarget)
            return
        }
        let op: PasteQueueOperation
        switch store.beginInsertion(kind) {
        case .failure(let reason):
            // Пустая и пройденная очередь — не ошибка вставки, а состояние: показываем его.
            if reason == .completed {
                env.announce(.completed(total: store.items.count))
            } else {
                env.announce(.refused(reason))
            }
            if reason != .busy { store.noteRefusal(reason) }
            env.log("очередь вставки: отказ (\(reason.rawValue))")
            return
        case .success(let o):
            op = o
        }
        if let reason = env.preflight() {
            store.finishInsertion(op.id, result: .refused(reason))
            env.announce(.refused(reason))
            env.log("очередь вставки: отказ до отправки (\(reason.rawValue)), позиция не менялась")
            return
        }
        env.log("очередь вставки: операция \(op.id.uuidString.prefix(8)) — \(op.text.count) симв.")
        env.send(op.text) { [weak self] result in
            self?.complete(op, result: result)
        }
    }

    private func complete(_ op: PasteQueueOperation, result: PasteQueueSendResult) {
        guard let env = environment else {
            store.finishInsertion(op.id, result: result); return
        }
        guard let status = store.finishInsertion(op.id, result: result) else { return }
        let total = store.items.count
        let pos = min(store.currentIndex + 1, max(total, 1))
        let nextPreview = store.nextItem?.preview(maxLength: 28)
        switch result {
        case .refused(let reason):
            env.announce(.refused(reason))
            env.log("очередь вставки: исполнитель отказал (\(reason.rawValue)), позиция не менялась")
        case .partial:
            env.announce(.partial)
            env.log("очередь вставки: ошибка посреди отправки — очередь на паузе, повтора нет")
        case .sent(let confirmed):
            env.log("очередь вставки: отправлено, \(confirmed ? "подтверждено AX" : "подтверждение недоступно")")
            switch op.kind {
            case .next:
                if case .completed(let n) = status {
                    env.announce(.completed(total: n))
                } else if confirmed {
                    env.announce(.progress(position: pos, total: total, nextPreview: nextPreview))
                } else {
                    env.announce(.sentUnconfirmed(position: pos, total: total, nextPreview: nextPreview))
                }
            case .pick:
                if case .completed(let n) = status { env.announce(.completed(total: n)) }
                else { env.announce(.pickedSent(confirmed: confirmed)) }
            case .all:
                env.announce(.allSent(count: op.itemIDs.count, confirmed: confirmed))
            }
        }
    }
}

extension PasteQueueStore {
    /// Отказ без начатой операции (пустая очередь, пауза): позиция не меняется, меняется только
    /// строка статуса над списком.
    func noteRefusal(_ reason: PasteQueueRefusal) {
        guard !isInserting else { return }
        if case .completed = lastStatus, reason == .completed { return }
        setStatus(.refused(reason))
    }
}
