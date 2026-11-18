import Foundation

enum PredictionPhrase {
    /// The first displayed word can include a separator if the user typed the preceding word.
    static func firstChunk(_ text: String) -> String {
        let start = text.prefix(while: { $0 == " " })
        return String(start + text.dropFirst(start.count).prefix(while: { !$0.isWhitespace }))
    }

    static func acceptFirstWord(_ suggestion: String) -> (insertion: String, remainder: String)? {
        let first = firstChunk(suggestion)
        guard first.last?.isWhitespace == false else { return nil }
        // The inserted space also serves as the separator before an unaccepted word.
        let remainder = suggestion.dropFirst(first.count).drop(while: \.isWhitespace)
        return (first + " ", String(remainder))
    }

    // Editors may represent a typed trailing space as NBSP. Character offsets in AX are UTF-16.
    static func matchesEdit(before: String, after: String, inserted: String, position: Int,
                            newBefore: String, newAfter: String, newPosition: Int) -> Bool {
        guard newPosition == position + inserted.utf16.count, newAfter.utf16.elementsEqual(after.utf16) else { return false }
        let original = (before + inserted).replacingOccurrences(of: "\u{00a0}", with: " ").utf16
        let updated = newBefore.replacingOccurrences(of: "\u{00a0}", with: " ").utf16
        return original.suffix(updated.count).elementsEqual(updated)
    }
}
