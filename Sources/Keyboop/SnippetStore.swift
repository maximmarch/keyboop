import Foundation

/// Тип сниппета автозамены (KB-004).
enum SnippetKind: String, Codable, Equatable {
    case plain
    case template
}

/// Тип пользовательского поля в динамическом шаблоне.
enum SnippetFieldType: String, Codable, CaseIterable, Equatable {
    case text
    case multiline
    case date
    case choice
}

/// Описание пользовательской переменной в форме заполнения шаблона.
struct SnippetField: Codable, Identifiable, Equatable {
    var id: UUID
    var key: String
    var label: String
    var type: SnippetFieldType
    var defaultValue: String
    var required: Bool
    var options: [String]
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        key: String,
        label: String = "",
        type: SnippetFieldType = .text,
        defaultValue: String = "",
        required: Bool = false,
        options: [String] = [],
        sortOrder: Int = 0
    ) {
        self.id = id
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.required = required
        self.options = options
        self.sortOrder = sortOrder
    }

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key : trimmed
    }
}

/// Сниппет автозамены версии V2: поддерживает как обычный статический текст (`plain`),
/// так и динамический шаблон с переменными и формой (`template`).
struct SnippetV2: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 2

    var id: UUID
    var trigger: String
    var kind: SnippetKind
    var body: String
    var fields: [SnippetField]
    var sortOrder: Int
    var enabled: Bool
    var allowClipboard: Bool
    var isPrivate: Bool
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        trigger: String,
        kind: SnippetKind = .plain,
        body: String,
        fields: [SnippetField] = [],
        sortOrder: Int = 0,
        enabled: Bool = true,
        allowClipboard: Bool = false,
        isPrivate: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = SnippetV2.currentSchemaVersion
    ) {
        self.id = id
        self.trigger = trigger
        self.kind = kind
        self.body = body
        self.fields = fields
        self.sortOrder = sortOrder
        self.enabled = enabled
        self.allowClipboard = allowClipboard
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    /// Итоговый список полей формы для шаблона: настроенные поля в `fields` (с учётом `sortOrder`)
    /// плюс переменные, упомянутые в `body`, но ещё не оформленные явно в `fields`.
    func resolvedFormFields(using parsed: ParsedSnippetTemplate? = nil) -> [SnippetField] {
        guard kind == .template else { return [] }
        let tree = parsed ?? SnippetTemplateParser.parse(body)
        let usedKeys = Set(tree.fieldKeysInOrder)

        var byKey: [String: SnippetField] = [:]
        for field in fields where usedKeys.contains(field.key) {
            if byKey[field.key] == nil {
                byKey[field.key] = field
            }
        }

        // Сохраняем порядок явных полей по sortOrder, затем добавляем не настроенные в порядке появления в тексте.
        var ordered: [SnippetField] = fields
            .filter { usedKeys.contains($0.key) }
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                let lhsIdx = tree.fieldKeysInOrder.firstIndex(of: $0.key) ?? Int.max
                let rhsIdx = tree.fieldKeysInOrder.firstIndex(of: $1.key) ?? Int.max
                return lhsIdx < rhsIdx
            }

        var nextOrder = (ordered.map(\.sortOrder).max() ?? -1) + 1
        for key in tree.fieldKeysInOrder where byKey[key] == nil {
            let synthetic = SnippetField(
                key: key,
                label: key,
                type: .text,
                defaultValue: "",
                required: false,
                options: [],
                sortOrder: nextOrder
            )
            byKey[key] = synthetic
            ordered.append(synthetic)
            nextOrder += 1
        }
        return ordered
    }

    /// Нужно ли показывать интерактивную форму при срабатывании триггера (FR-1:
    /// если нет пользовательских полей, окно не показывается).
    func requiresInteractiveForm(using parsed: ParsedSnippetTemplate? = nil) -> Bool {
        guard kind == .template else { return false }
        let tree = parsed ?? SnippetTemplateParser.parse(body)
        return tree.hasUserFields
    }
}

enum SnippetStoreError: Error, Equatable {
    case emptyTrigger
    case triggerContainsWhitespace
    case duplicateCanonicalTrigger(existingID: UUID, existingTrigger: String)
    case invalidTemplateSyntax([SnippetTemplateDiagnostic])
}

extension Notification.Name {
    static let keyboopSnippetsChanged = Notification.Name("KeyboopSnippetsChanged")
}

/// Хранилище сниппетов автозамены: триггер -> текст или динамический шаблон KB-004.
/// Сохраняет обратную совместимость со старыми ключами `snippetsOrdered` / `snippets`
/// и протоколом `PairListStore`.
final class SnippetStore {
    static let shared = SnippetStore()

    private let d: UserDefaults
    private let v2Key = "snippetsV2"
    private let legacyOrderedKey = "snippetsOrdered"
    private let legacyDictKey = "snippets"
    private let lock = NSLock()

    private var orderedSnippets: [SnippetV2] = []
    private var byCanonical: [String: SnippetV2] = [:]

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        loadAndMigrateIfNeeded()
    }

    /// Канонический вид триггера: всегда латиница и нижний регистр,
    /// поэтому `!ee`, `!уу` и `!EE` считаются одним триггером.
    static func canonical(_ s: String) -> String {
        Keymap.convert(s, toCyrillic: false).lowercased()
    }

    private func loadAndMigrateIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        if let raw = d.data(forKey: v2Key),
           let decoded = try? JSONDecoder().decode([SnippetV2].self, from: raw) {
            orderedSnippets = normalizeOrder(decoded)
            rebuildIndex()
            return
        }

        // Одноразовая миграция V1 → V2 с сохранением порядка и содержимого старых сниппетов.
        let now = Date()
        let rawPairs = loadLegacyPairsLocked()
        var migrated: [SnippetV2] = []
        var seenCanonical = Set<String>()

        for (index, pair) in rawPairs.enumerated() {
            let trig = pair.0.trimmingCharacters(in: .whitespaces)
            guard !trig.isEmpty else { continue }
            let canon = Self.canonical(trig)
            // Старый стор при дублях держал активным первый, второй оставался в списке — помечаем дубль выключенным.
            let isFirst = seenCanonical.insert(canon).inserted
            migrated.append(SnippetV2(
                id: UUID(),
                trigger: trig,
                kind: .plain,
                body: pair.1,
                fields: [],
                sortOrder: index,
                enabled: isFirst,
                allowClipboard: false,
                isPrivate: false,
                createdAt: now,
                updatedAt: now,
                schemaVersion: SnippetV2.currentSchemaVersion
            ))
        }

        orderedSnippets = normalizeOrder(migrated)
        rebuildIndex()
        persistV2Locked()
    }

    private func loadLegacyPairsLocked() -> [(String, String)] {
        if let raw = d.array(forKey: legacyOrderedKey) as? [[String]] {
            return raw.compactMap { row in
                guard row.count >= 2 else { return nil }
                return (row[0], row[1])
            }
        }
        if let legacy = d.dictionary(forKey: legacyDictKey) as? [String: String] {
            return legacy.keys.sorted().map { ($0, legacy[$0] ?? "") }
        }
        return []
    }

    private func normalizeOrder(_ list: [SnippetV2]) -> [SnippetV2] {
        list.enumerated().map { idx, item in
            var copy = item
            copy.sortOrder = idx
            return copy
        }
    }

    private func rebuildIndex() {
        var map: [String: SnippetV2] = [:]
        for item in orderedSnippets where item.enabled {
            let trig = item.trigger.trimmingCharacters(in: .whitespaces)
            guard !trig.isEmpty else { continue }
            let c = Self.canonical(trig)
            if map[c] == nil {
                map[c] = item
            }
        }
        byCanonical = map
    }

    private func persistV2Locked() {
        if let encoded = try? JSONEncoder().encode(orderedSnippets) {
            d.set(encoded, forKey: v2Key)
        }
        // Поддерживаем также `snippetsOrdered` для обратной читаемости (без затирания при экспорте V2).
        d.set(orderedSnippets.map { [$0.trigger, $0.body] }, forKey: legacyOrderedKey)
    }

    // MARK: - Runtime Lookup

    /// Поиск активного сниппета по набранному слову без учёта раскладки и регистра.
    func snippet(forTyped word: String) -> SnippetV2? {
        guard !word.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return byCanonical[Self.canonical(word)]
    }

    /// Обратно-совместимый поиск для статических `.plain`-сниппетов.
    func expansion(forTyped word: String) -> String? {
        guard let item = snippet(forTyped: word), item.kind == .plain else { return nil }
        return item.body
    }

    // MARK: - Rich V2 CRUD

    func syncInlineRows(_ rows: [(id: UUID?, trigger: String, body: String)]) -> [UUID?] {
        lock.lock()
        let existingByID = Dictionary(uniqueKeysWithValues: orderedSnippets.map { ($0.id, $0) })
        let now = Date()
        var next: [SnippetV2] = []
        var assignedIDs: [UUID?] = []
        var seenCanon = Set<String>()

        for row in rows {
            let trig = row.trigger.trimmingCharacters(in: .whitespaces)
            guard !trig.isEmpty else {
                assignedIDs.append(nil)
                continue
            }
            let c = Self.canonical(trig)
            let isFirst = seenCanon.insert(c).inserted

            if let id = row.id, var existing = existingByID[id] {
                existing.trigger = trig
                if existing.kind == .plain {
                    existing.body = row.body
                }
                existing.sortOrder = next.count
                existing.enabled = isFirst ? existing.enabled : false
                existing.updatedAt = now
                next.append(existing)
                assignedIDs.append(existing.id)
            } else {
                let item = SnippetV2(
                    id: row.id ?? UUID(),
                    trigger: trig,
                    kind: .plain,
                    body: row.body,
                    fields: [],
                    sortOrder: next.count,
                    enabled: isFirst,
                    allowClipboard: false,
                    isPrivate: false,
                    createdAt: now,
                    updatedAt: now,
                    schemaVersion: SnippetV2.currentSchemaVersion
                )
                next.append(item)
                assignedIDs.append(item.id)
            }
        }

        orderedSnippets = normalizeOrder(next)
        rebuildIndex()
        persistV2Locked()
        lock.unlock()

        NotificationCenter.default.post(name: .keyboopSnippetsChanged, object: self)
        return assignedIDs
    }

    func allSnippets() -> [SnippetV2] {
        lock.lock()
        defer { lock.unlock() }
        return orderedSnippets
    }

    func snippet(id: UUID) -> SnippetV2? {
        lock.lock()
        defer { lock.unlock() }
        return orderedSnippets.first { $0.id == id }
    }

    func conflictingActiveSnippet(forTrigger trigger: String, excludingID: UUID? = nil) -> SnippetV2? {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let targetCanon = Self.canonical(trimmed)
        lock.lock()
        defer { lock.unlock() }
        return orderedSnippets.first {
            $0.enabled && $0.id != excludingID && Self.canonical($0.trigger.trimmingCharacters(in: .whitespacesAndNewlines)) == targetCanon
        }
    }

    func upsert(_ snippet: SnippetV2) throws {
        var cleaned = snippet
        cleaned.trigger = snippet.trigger.trimmingCharacters(in: .whitespaces)
        cleaned.updatedAt = Date()
        cleaned.schemaVersion = SnippetV2.currentSchemaVersion

        guard !cleaned.trigger.isEmpty else {
            throw SnippetStoreError.emptyTrigger
        }
        guard cleaned.trigger.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw SnippetStoreError.triggerContainsWhitespace
        }

        if cleaned.kind == .template {
            let parsed = SnippetTemplateParser.parse(cleaned.body)
            if !parsed.isValid {
                throw SnippetStoreError.invalidTemplateSyntax(parsed.diagnostics)
            }
        }

        lock.lock()
        if cleaned.enabled {
            let targetCanon = Self.canonical(cleaned.trigger)
            if let conflict = orderedSnippets.first(where: {
                $0.enabled && $0.id != cleaned.id && Self.canonical($0.trigger.trimmingCharacters(in: .whitespaces)) == targetCanon
            }) {
                lock.unlock()
                throw SnippetStoreError.duplicateCanonicalTrigger(existingID: conflict.id, existingTrigger: conflict.trigger)
            }
        }

        if let idx = orderedSnippets.firstIndex(where: { $0.id == cleaned.id }) {
            cleaned.sortOrder = orderedSnippets[idx].sortOrder
            orderedSnippets[idx] = cleaned
        } else {
            cleaned.sortOrder = orderedSnippets.count
            orderedSnippets.append(cleaned)
        }
        orderedSnippets = normalizeOrder(orderedSnippets)
        rebuildIndex()
        persistV2Locked()
        lock.unlock()

        NotificationCenter.default.post(name: .keyboopSnippetsChanged, object: self)
    }

    func remove(id: UUID) {
        lock.lock()
        let before = orderedSnippets.count
        orderedSnippets.removeAll { $0.id == id }
        guard orderedSnippets.count != before else {
            lock.unlock()
            return
        }
        orderedSnippets = normalizeOrder(orderedSnippets)
        rebuildIndex()
        persistV2Locked()
        lock.unlock()

        NotificationCenter.default.post(name: .keyboopSnippetsChanged, object: self)
    }

    func setEnabled(id: UUID, enabled: Bool) throws {
        lock.lock()
        guard let idx = orderedSnippets.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        var target = orderedSnippets[idx]
        if enabled {
            let targetCanon = Self.canonical(target.trigger.trimmingCharacters(in: .whitespaces))
            if let conflict = orderedSnippets.first(where: {
                $0.enabled && $0.id != id && Self.canonical($0.trigger.trimmingCharacters(in: .whitespaces)) == targetCanon
            }) {
                lock.unlock()
                throw SnippetStoreError.duplicateCanonicalTrigger(existingID: conflict.id, existingTrigger: conflict.trigger)
            }
        }
        target.enabled = enabled
        target.updatedAt = Date()
        orderedSnippets[idx] = target
        rebuildIndex()
        persistV2Locked()
        lock.unlock()

        NotificationCenter.default.post(name: .keyboopSnippetsChanged, object: self)
    }

    // MARK: - PairListStore compatibility (legacy inline editor / copyFromAutoreplace)

    func pairs() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return orderedSnippets.map { ($0.trigger, $0.body) }
    }

    func setAll(_ pairs: [(String, String)]) {
        lock.lock()
        let existing = orderedSnippets
        var remainingByCanon: [String: [SnippetV2]] = [:]
        for item in existing {
            let c = Self.canonical(item.trigger.trimmingCharacters(in: .whitespaces))
            remainingByCanon[c, default: []].append(item)
        }

        let now = Date()
        var next: [SnippetV2] = []
        var seenCanon = Set<String>()

        for (index, raw) in pairs.enumerated() {
            let trig = raw.0.trimmingCharacters(in: .whitespaces)
            guard !trig.isEmpty else { continue }
            let c = Self.canonical(trig)
            let isFirst = seenCanon.insert(c).inserted

            if var queue = remainingByCanon[c], !queue.isEmpty {
                var matched = queue.removeFirst()
                remainingByCanon[c] = queue
                matched.trigger = trig
                // Не перетираем многострочное тело шаблона однострочным представлением, если
                // вызвано старым редактором и тело совпадает по первой строке или режиму.
                if matched.kind == .plain {
                    matched.body = raw.1
                }
                matched.sortOrder = index
                matched.enabled = isFirst ? matched.enabled : false
                matched.updatedAt = now
                next.append(matched)
            } else {
                next.append(SnippetV2(
                    id: UUID(),
                    trigger: trig,
                    kind: .plain,
                    body: raw.1,
                    fields: [],
                    sortOrder: index,
                    enabled: isFirst,
                    allowClipboard: false,
                    isPrivate: false,
                    createdAt: now,
                    updatedAt: now,
                    schemaVersion: SnippetV2.currentSchemaVersion
                ))
            }
        }

        orderedSnippets = normalizeOrder(next)
        rebuildIndex()
        persistV2Locked()
        lock.unlock()

        NotificationCenter.default.post(name: .keyboopSnippetsChanged, object: self)
    }
}
