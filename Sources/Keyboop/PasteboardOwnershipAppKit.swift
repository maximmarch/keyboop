import AppKit

extension NSPasteboard {
    func kbNoteOurs() {
        PasteboardOwnership.note(changeCount)
    }
}
