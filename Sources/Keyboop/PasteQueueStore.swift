import Foundation

// KB-022 · Paste Queue — хранилище очереди.
//
// Одна активная сессия, только в оперативной памяти (FR-03, FR-10). На диск, в UserDefaults и в
// iCloud содержимое не попадает НИКОГДА: при выходе из приложения очередь исчезает вместе с
// процессом. Настройки очереди (сочетание, режим завершения) живут отдельно, в
// `PasteQueueSettingsStore`, и текста элементов не содержат.
//
// Все изменения идут с главного потока, последовательно. Одновременно две вставки невозможны:
// `beginInsertion` выдаёт операцию только когда предыдущая закрыта (`finishInsertion`).
//
// ⚠️ БЕЗ AppKit — файл собирается в юнит-тест отдельно от приложения.

extension Notification.Name {
    /// Очередь вставки изменилась (элементы, позиция, статус). Объект — `PasteQueueStore`.
    static let keyboopPasteQueueChanged = Notification.Name("keyboopPasteQueueChanged")
}

/// Итог последней операции — для индикатора над списком. Текста элементов здесь нет.
enum PasteQueueOperationStatus: Equatable {
    case idle
    case confirmed(index: Int)
    case sentUnconfirmed(index: Int)
    case refused(PasteQueueRefusal)
    case partial(index: Int)
    case completed(total: Int)
}

/// Почему вставка не началась. Позиция очереди при любом отказе не меняется (FR-07).
enum PasteQueueRefusal: String, Error, Equatable {
    case empty              // очередь пуста
    case completed          // все элементы уже вставлены
    case paused             // после частичной вставки — ждём решения человека
    case busy               // предыдущая вставка ещё идёт
    case keyboopPaused      // Keyboop на паузе
    case secureInput        // поле пароля / Secure Input
    case ownWindow          // активно окно Keyboop — вставлять некуда
    case noFocus            // нет фокусного поля (смена приложения, фокус потерян)
    case keyboopOff         // правило приложения или сайта выключает Keyboop
    case unsupportedTarget  // поле не принимает синтетический Unicode (удалённый рабочий стол и т.п.)
    case notFound           // выбранный элемент уже удалён
}

/// Как прошла отправка, по мнению исполнителя (`PasteQueueEnvironment.send`).
enum PasteQueueSendResult: Equatable {
    /// События отправлены целиком. `confirmed`: true — Accessibility видит текст в поле,
    /// false — подтверждение недоступно (FR-07: «Отправлено, подтверждение недоступно»).
    case sent(confirmed: Bool)
    /// Отказ ДО первого события: ничего не напечатано.
    case refused(PasteQueueRefusal)
    /// Ошибка посреди отправки: часть текста могла уйти.
    case partial
}

/// Вид операции вставки.
enum PasteQueueOperationKind: Equatable {
    case next                 // режим А — следующий элемент
    case pick(UUID)           // режим Б — выбранный элемент
    case all(delimiter: String) // режим В — все элементы одним блоком
}

/// Выданная операция. `id` уникален: завершить можно только ту операцию, которую начали.
struct PasteQueueOperation: Equatable {
    let id: UUID
    let kind: PasteQueueOperationKind
    let itemIDs: [UUID]
    let text: String
}

final class PasteQueueStore {
    static let shared = PasteQueueStore()

    private(set) var items: [PasteQueueItem] = []
    /// Индекс следующего элемента. `== items.count` — очередь пройдена.
    private(set) var currentIndex = 0
    private(set) var sessionCreatedAt: Date?
    private(set) var isPausedAfterPartial = false
    private(set) var lastStatus: PasteQueueOperationStatus = .idle
    private(set) var inFlight: PasteQueueOperation?

    var completionMode: PasteQueueCompletionMode = .keepPosition
    /// Режим Б: двигает ли ручная вставка выбранного элемента текущую позицию. По умолчанию — нет.
    var manualPickAdvances = false

    /// Для тестов: не рассылать уведомления.
    var postsNotifications = true

    init() {}

    // MARK: состояние

    var isActive: Bool { !items.isEmpty }
    var isCompleted: Bool { !items.isEmpty && currentIndex >= items.count }
    var isInserting: Bool { inFlight != nil }
    var nextItem: PasteQueueItem? { currentIndex < items.count ? items[currentIndex] : nil }
    var pastedCount: Int { items.filter { $0.state != .pending }.count }

    // MARK: добавление (FR-01, FR-02, FR-10)

    static func validate(_ text: String) -> PasteQueueAddError? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.utf8.count > PasteQueueLimits.maxItemBytes { return .tooLarge }
        return nil
    }

    @discardableResult
    func add(_ item: PasteQueueItem) -> PasteQueueAddError? {
        if let e = Self.validate(item.text) { return e }
        guard items.count < PasteQueueLimits.maxItems else { return .queueFull }
        if items.isEmpty { sessionCreatedAt = Date() }
        var copy = item
        copy.state = .pending
        items.append(copy)
        changed()
        return nil
    }

    /// Пакетное добавление (несколько записей истории за одну операцию). Добавляется всё, что
    /// влезает в пределы; возвращает число добавленных и причины пропуска остальных.
    func addBatch(_ batch: [PasteQueueItem]) -> (added: Int, skipped: [PasteQueueAddError]) {
        var added = 0
        var skipped: [PasteQueueAddError] = []
        let wasNotifying = postsNotifications
        postsNotifications = false
        for item in batch {
            if let e = add(item) { skipped.append(e) } else { added += 1 }
        }
        postsNotifications = wasNotifying
        if added > 0 { changed() }
        return (added, skipped)
    }

    // MARK: операции над элементами (FR-04)

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    /// Удаление. Если удалили следующий элемент, указатель встаёт на следующий оставшийся.
    func remove(id: UUID) {
        guard let i = index(of: id) else { return }
        items.remove(at: i)
        if i < currentIndex { currentIndex -= 1 }
        currentIndex = min(currentIndex, items.count)
        if items.isEmpty { resetSession() }
        changed()
    }

    func remove(ids: Set<UUID>) {
        let wasNotifying = postsNotifications
        postsNotifications = false
        for id in ids { remove(id: id) }
        postsNotifications = wasNotifying
        changed()
    }

    /// Перестановка на одну позицию. Текст элементов не меняется; позиция очереди — это номер
    /// места в списке, поэтому следующим станет тот, кто теперь стоит на этом месте.
    @discardableResult
    func move(id: UUID, by delta: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        let j = i + delta
        guard j >= 0, j < items.count, j != i else { return false }
        let item = items.remove(at: i)
        items.insert(item, at: j)
        changed()
        return true
    }

    /// Правка текста перед вставкой. Состояние элемента сбрасывается в «ожидает».
    @discardableResult
    func updateText(id: UUID, to text: String) -> PasteQueueAddError? {
        guard let i = index(of: id) else { return nil }
        if let e = Self.validate(text) { return e }
        items[i].text = text
        items[i].state = .pending
        changed()
        return nil
    }

    func setSensitive(id: UUID, _ on: Bool) {
        guard let i = index(of: id) else { return }
        items[i].isSensitive = on
        changed()
    }

    /// Вернуться на предыдущую позицию.
    func stepBack() {
        guard !items.isEmpty else { return }
        currentIndex = max(0, min(currentIndex, items.count) - 1)
        isPausedAfterPartial = false
        lastStatus = .idle
        changed()
    }

    /// Сделать выбранный элемент следующим.
    func setNext(id: UUID) {
        guard let i = index(of: id) else { return }
        currentIndex = i
        isPausedAfterPartial = false
        lastStatus = .idle
        changed()
    }

    /// Снять паузу после частичной вставки. Позиция остаётся на том же элементе: повторит ли его
    /// человек или пропустит — решает он сам, автоматически ничего не повторяется.
    func resume() {
        isPausedAfterPartial = false
        lastStatus = .idle
        changed()
    }

    /// Перезапуск с первого элемента.
    func restart() {
        currentIndex = 0
        for i in items.indices { items[i].state = .pending }
        isPausedAfterPartial = false
        lastStatus = .idle
        changed()
    }

    func clear() {
        items.removeAll()
        resetSession()
        changed()
    }

    private func resetSession() {
        currentIndex = 0
        sessionCreatedAt = nil
        isPausedAfterPartial = false
        lastStatus = .idle
    }

    // MARK: транзакции вставки (FR-06, FR-07, FR-08)

    /// Выдать операцию или причину отказа. Ничего не меняет, кроме флага «идёт вставка».
    func beginInsertion(_ kind: PasteQueueOperationKind) -> Result<PasteQueueOperation, PasteQueueRefusal> {
        guard inFlight == nil else { return .failure(.busy) }
        guard !items.isEmpty else { return .failure(.empty) }
        let op: PasteQueueOperation
        switch kind {
        case .next:
            guard !isPausedAfterPartial else { return .failure(.paused) }
            guard currentIndex < items.count else { return .failure(.completed) }
            let item = items[currentIndex]
            op = PasteQueueOperation(id: UUID(), kind: kind, itemIDs: [item.id], text: item.text)
        case .pick(let id):
            guard let i = index(of: id) else { return .failure(.notFound) }
            op = PasteQueueOperation(id: UUID(), kind: kind, itemIDs: [id], text: items[i].text)
        case .all(let delimiter):
            op = PasteQueueOperation(id: UUID(), kind: kind, itemIDs: items.map(\.id),
                                     text: items.map(\.text).joined(separator: delimiter))
        }
        inFlight = op
        changed()
        return .success(op)
    }

    /// Закрыть операцию. Чужой (устаревший) идентификатор игнорируется.
    @discardableResult
    func finishInsertion(_ opID: UUID, result: PasteQueueSendResult) -> PasteQueueOperationStatus? {
        guard let op = inFlight, op.id == opID else { return nil }
        inFlight = nil
        switch result {
        case .refused(let reason):
            lastStatus = .refused(reason)          // позиция не меняется
        case .partial:
            for id in op.itemIDs { if let i = index(of: id) { items[i].state = .partial } }
            let pos = op.itemIDs.first.flatMap(index(of:)) ?? currentIndex
            isPausedAfterPartial = true            // без автоматического повтора
            lastStatus = .partial(index: pos)
        case .sent(let confirmed):
            let state: PasteQueueItemState = confirmed ? .confirmed : .sentUnconfirmed
            for id in op.itemIDs { if let i = index(of: id) { items[i].state = state } }
            let pos = op.itemIDs.first.flatMap(index(of:)) ?? currentIndex
            lastStatus = confirmed ? .confirmed(index: pos) : .sentUnconfirmed(index: pos)
            switch op.kind {
            case .next:
                // Элемент мог переехать или исчезнуть, пока шла вставка — двигаемся от него самого.
                if let i = op.itemIDs.first.flatMap(index(of:)) { currentIndex = i + 1 }
                currentIndex = min(currentIndex, items.count)
                applyCompletionIfNeeded()
            case .pick:
                if manualPickAdvances, let i = op.itemIDs.first.flatMap(index(of:)) {
                    currentIndex = min(i + 1, items.count)
                    applyCompletionIfNeeded()
                }
            case .all:
                break
            }
        }
        changed()
        return lastStatus
    }

    private func applyCompletionIfNeeded() {
        guard !items.isEmpty, currentIndex >= items.count else { return }
        let total = items.count
        switch completionMode {
        case .keepPosition:
            break
        case .restart:
            currentIndex = 0
            for i in items.indices { items[i].state = .pending }
        case .clear:
            items.removeAll()
            resetSession()
        }
        lastStatus = .completed(total: total)
    }

    /// Обновить строку статуса, не трогая элементы и позицию.
    func setStatus(_ status: PasteQueueOperationStatus) {
        lastStatus = status
        changed()
    }

    private func changed() {
        guard postsNotifications else { return }
        NotificationCenter.default.post(name: .keyboopPasteQueueChanged, object: self)
    }
}
