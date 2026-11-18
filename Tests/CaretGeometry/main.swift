import AppKit

let viewport = CGRect(x: -1280, y: -30, width: 160, height: 60)
let glyph = CGRect(x: -1260, y: -14, width: 7, height: 15)
let leading = CGRect(x: glyph.minX, y: glyph.minY, width: 1, height: glyph.height)
let trailing = CGRect(x: glyph.maxX, y: glyph.minY, width: 1, height: glyph.height)
precondition(CaretLocator.anchoredRect(glyph, source: .nextCharacter, viewport: viewport) == leading)
precondition(CaretLocator.anchoredRect(glyph, source: .previousCharacter, viewport: viewport) == trailing)
precondition(CaretLocator.anchoredRect(leading, source: .selectedMarker, viewport: viewport) == leading)
precondition(CaretLocator.anchoredRect(viewport, source: .selectedRange, viewport: viewport) == nil)
precondition(CaretLocator.anchoredRect(viewport, source: .previousCharacter, viewport: viewport) == nil)
precondition(CaretLocator.anchoredRect(glyph.offsetBy(dx: 400, dy: 0), source: .nextCharacter, viewport: viewport) == nil)
let chromeRun = CGRect(x: glyph.minX, y: glyph.minY, width: 71, height: 15)
precondition(CaretLocator.anchoredRect(chromeRun, source: .visibleRun, viewport: viewport)?.minX == chromeRun.maxX)
precondition(CaretLocator.matchesLineEnd(run: "до сих\u{00a0}", before: "уже до сих "))
precondition(!CaretLocator.matchesLineEnd(run: "до сих", before: "до сих "))
precondition(CaretLocator.matchesLineEnd(run: "отправлю PR", before: "раньше\nотправлю PR"))
precondition(!CaretLocator.matchesLineEnd(run: "первая\nстрока", before: "строка"))
precondition(!CaretLocator.matchesLineEnd(run: "привет שלום", before: "привет שלום"))
precondition(!CaretLocator.matchesLineEnd(run: "привет", before: "привет\n"))
print("CaretGeometry: 13 geometry and context checks passed")

// Model the host's UTF-16 AX ranges. The full caret lookup runs against a synthetic editor;
// the two rectangles belong to consecutive visual lines in Quartz coordinates.
let editor = AXUIElementCreateApplication(41001)
let staticNode = AXUIElementCreateApplication(41002)
var fieldBox = CGRect(x: 30, y: 40, width: 220, height: 100)
let upperCaret = CGRect(x: 65, y: 45, width: 1, height: 16)
let finalGlyph = CGRect(x: 60, y: 65, width: 8, height: 16)
let lowerCaret = CGRect(x: 68, y: 65, width: 1, height: 16)
var context = "первая строка\nдо сих "
var rootCaret: CGRect? = upperCaret
var rootGlyph: CGRect? = finalGlyph
var nodeGlyph = finalGlyph
var markerGlyph: CGRect?
var nodeHasGlyph = true
var nodeText: String?
var visualLineRange: CFRange?
var endLineBounds: CGRect?

func boxValue<T>(_ initial: T, _ type: AXValueType) -> AXValue {
    var value = initial
    return withUnsafePointer(to: &value) { AXValueCreate(type, $0)! }
}

func AXUIElementCopyAttributeValue(_ el: AXUIElement, _ name: CFString, _ output: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    if CFEqual(el, editor), name as String == kAXInsertionPointLineNumberAttribute, visualLineRange != nil {
        output.pointee = NSNumber(value: 1)
        return .success
    }
    guard CFEqual(el, staticNode), let nodeText else { return .noValue }
    switch name as String {
    case kAXRoleAttribute: output.pointee = kAXStaticTextRole as CFString
    case kAXValueAttribute: output.pointee = nodeText as CFString
    case kAXPositionAttribute: output.pointee = boxValue(fieldBox.origin, .cgPoint)
    case kAXSizeAttribute: output.pointee = boxValue(fieldBox.size, .cgSize)
    default: return .attributeUnsupported
    }
    return .success
}

func AXUIElementCopyAttributeValues(_ el: AXUIElement, _ name: CFString, _ index: CFIndex, _ limit: CFIndex,
                                   _ output: UnsafeMutablePointer<CFArray?>) -> AXError {
    guard CFEqual(el, editor), nodeText != nil else { return .noValue }
    output.pointee = [staticNode] as CFArray
    return .success
}

func AXUIElementCopyParameterizedAttributeValue(_ el: AXUIElement, _ name: CFString, _ arg: CFTypeRef,
                                               _ output: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    let root = CFEqual(el, editor)
    let count = (root ? context : nodeText ?? "").utf16.count
    switch name as String {
    case "AXStartTextMarkerForTextMarkerRange", "AXPreviousTextMarkerForTextMarker", "AXTextMarkerRangeForUnorderedTextMarkers":
        guard markerGlyph != nil else { return .noValue }
        output.pointee = (name as String) as CFString
    case "AXBoundsForTextMarkerRange":
        guard let markerGlyph, let request = arg as? String else { return .noValue }
        output.pointee = boxValue(request == "selected" ? upperCaret : markerGlyph, .cgRect)
    case kAXBoundsForRangeParameterizedAttribute:
        var range = CFRange()
        guard CFGetTypeID(arg) == AXValueGetTypeID(),
              AXValueGetValue(arg as! AXValue, .cfRange, &range) else { return .illegalArgument }
        let rect: CGRect?
        if range.location == count && range.length == 0 { rect = root ? rootCaret : nil }
        else if range.location == count - 1 && range.length == 1 { rect = root ? rootGlyph : (nodeHasGlyph ? nodeGlyph : nil) }
        else if let line = visualLineRange, range.location == line.location && range.length == line.length { rect = endLineBounds }
        else { rect = nil }
        guard let rect else { return .noValue }
        output.pointee = boxValue(rect, .cgRect)
    case kAXLineForIndexParameterizedAttribute:
        guard let line = visualLineRange, let index = arg as? NSNumber else { return .noValue }
        output.pointee = NSNumber(value: index.intValue >= line.location ? 1 : 0)
    case kAXRangeForLineParameterizedAttribute:
        guard let line = visualLineRange, (arg as? NSNumber)?.intValue == 1 else { return .noValue }
        output.pointee = boxValue(line, .cfRange)
    default: return .attributeUnsupported
    }
    return .success
}

var failures = 0
var multilineCases = 0
func expectCaret(_ title: String, _ expected: CGRect?, marker: CFTypeRef? = nil) {
    multilineCases += 1
    let found = CaretLocator.inlineGeometry(in: editor, at: context.utf16.count, before: String(context.suffix(128)),
                                           after: "", viewport: fieldBox, selectedMarker: marker)?.rect
    if found != expected {
        print("FAIL \(title): expected \(String(describing: expected)), got \(String(describing: found))")
        failures += 1
    }
}
expectCaret("second paragraph with a stale empty range", lowerCaret)
context = "a long line with a soft wrap near the end до сих "
expectCaret("soft wrap with a stale empty range", lowerCaret)
rootCaret = lowerCaret
expectCaret("reliable range on the current line", lowerCaret)
rootCaret = CGRect(x: 65, y: 45, width: 1, height: 55)
expectCaret("empty range spanning several lines", lowerCaret)
visualLineRange = CFRange(location: context.utf16.count - 3, length: 3)
rootCaret = CGRect(x: 152, y: 65, width: 1, height: 16)
expectCaret("stale column on a confirmed visual line", lowerCaret)
visualLineRange = nil
rootCaret = nil
rootGlyph = nil
nodeText = context
expectCaret("static text spanning multiple visual lines", lowerCaret)
context = "первая строка\nдо сих "
nodeText = context
expectCaret("static text spanning two paragraphs", lowerCaret)
nodeHasGlyph = false
visualLineRange = CFRange(location: context.utf16.count - "до сих ".utf16.count, length: "до сих ".utf16.count)
endLineBounds = CGRect(x: 31, y: 65, width: 37, height: 16)
expectCaret("last visual line bounds when glyph bounds are unavailable", lowerCaret)
endLineBounds = fieldBox
expectCaret("whole multiline box masquerading as last line", nil)
visualLineRange = nil
endLineBounds = nil
nodeText = nil
rootCaret = CGRect(x: 32, y: 85, width: 1, height: 16)
rootGlyph = finalGlyph
expectCaret("downstream affinity at a soft wrap", rootCaret)
visualLineRange = CFRange(location: context.utf16.count - 3, length: 3)
expectCaret("selected line disproves a stale lower caret", lowerCaret)
visualLineRange = nil

// Marker positions in a rich web editor can differ from plain UTF-16 range offsets.
markerGlyph = finalGlyph
rootGlyph = CGRect(x: 54, y: 45, width: 11, height: 16)
expectCaret("marker snapshot uses the adjacent marker in its own coordinate space", lowerCaret, marker: "selected" as CFString)
markerGlyph = nil

// Use actual AppKit line breaking as an independent source of glyph positions. A long
// paragraph has no newline at a soft wrap and can be longer than the AX context window.
let sample = String(repeating: "проверка строки ", count: 12) + "прив"
let storage = NSTextStorage(string: sample, attributes: [.font: NSFont.systemFont(ofSize: 14)])
let layout = NSLayoutManager()
let container = NSTextContainer(size: CGSize(width: 185, height: 2000))
container.lineFragmentPadding = 0
layout.addTextContainer(container)
storage.addLayoutManager(layout)
layout.ensureLayout(for: container)
let lastGlyph = layout.glyphIndexForCharacter(at: sample.utf16.count - 1)
let measured = layout.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
let firstLine = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
let lastLine = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
precondition(lastLine.minY > firstLine.maxY && sample.utf16.count > 128)
context = sample
// Translate the real last row into the viewport to also exercise scrolling.
rootGlyph = measured.offsetBy(dx: fieldBox.minX, dy: fieldBox.minY + 30 - lastLine.minY)
rootCaret = upperCaret
let measuredCaret = CGRect(x: rootGlyph!.maxX, y: rootGlyph!.minY, width: 1, height: rootGlyph!.height)
expectCaret("scrolled wrapped AppKit text with a truncated context", measuredCaret)
// A narrow paragraph's whole bounding box can satisfy the width/height check for a glyph.
context = "narrow wrapping paragraph"
nodeText = context
nodeHasGlyph = true
rootCaret = nil
rootGlyph = nil
fieldBox = CGRect(x: 30, y: 40, width: 30, height: 58)
nodeGlyph = fieldBox
expectCaret("full wrapped block returned as a one-character range", nil)
if failures > 0 { exit(1) }
print("CaretGeometry: \(multilineCases) multiline editor checks passed")
