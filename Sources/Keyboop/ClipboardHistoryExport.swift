import Foundation

extension ClipboardTransfer {
    static func exportEntries(from clear: Data) throws -> [ClipboardTransfer.Entry] {
        guard let history = try? JSONDecoder().decode([HistoryEntry].self, from: clear) else { throw ClipboardTransfer.Failure.format }
        var occurrences: [UUID: Int] = [:]
        return try history.filter { $0.kind == .clipboard }.enumerated().map { ordinal, row in
            let identity = try ClipboardTransfer.stableID(text: row.text, date: row.date, app: row.app)
            let occurrence = occurrences[identity, default: 0]
            occurrences[identity] = occurrence + 1
            return ClipboardTransfer.Entry(id: ClipboardTransfer.occurrenceID(identity, occurrence: occurrence),
                text: row.text, createdAt: row.date, app: row.app, ordinal: ordinal)
        }
    }
}
