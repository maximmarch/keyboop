import Foundation

let date = Date(timeIntervalSince1970: 1_700_000_000)
let rows: [HistoryEntry] = [
    .init(date: date, text: "voice", audio: "clip", wave: [1], kind: .dictation),
    .init(date: date, text: "copy 👩‍💻", kind: .clipboard, app: "Editor"),
    .init(date: date, text: "imported", kind: .imported),
    .init(date: date, text: "call", kind: .call),
    .init(date: date, text: "copy 👩‍💻", kind: .clipboard, app: "Editor")
]
let source = try JSONEncoder().encode(rows)
let entries = try ClipboardTransfer.exportEntries(from: source)
precondition(entries.count == 2 && entries.map(\.ordinal) == [0, 1])
precondition(entries[0].id != entries[1].id)
precondition(entries.allSatisfy { $0.text == "copy 👩‍💻" })
let reordered = try ClipboardTransfer.exportEntries(from: JSONEncoder().encode(Array(rows.dropFirst())))
precondition(entries == reordered)
let payload = ClipboardTransfer.Payload(schemaVersion: 1, exportedAt: date, sourceApplication: "Keyboop",
                                       sourceVersion: "0.5.4", entries: entries)
let archive = try ClipboardTransfer.seal(payload, password: "fixture password")
let opened = try ClipboardTransfer.open(archive, password: "fixture password")
precondition(opened == payload)
if CommandLine.arguments.count == 2 {
    try archive.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
}
print("Clipboard-only export and encrypted round trip passed")
