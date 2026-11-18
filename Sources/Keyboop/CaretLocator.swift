import ApplicationServices
import AppKit

enum CaretLocator {
    enum Source: String {
        case selectedRange, selectedMarker, nextCharacter, previousCharacter, visibleRun

        var isExact: Bool { self == .selectedRange || self == .selectedMarker }
    }

    struct Geometry {
        let rect: CGRect
        let source: Source
        let font: NSFont?
    }

    static func caretScreenRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        guard let selected = value(attribute(element, kAXSelectedTextRangeAttribute), type: .cfRange, initial: CFRange()),
              let rect = caretQuartzRect(in: element, at: max(selected.location, 0)) else { return nil }
        return flipToCocoa(rect)
    }

    // Dictation also calls this on the main thread. Keep the inexpensive range-only lookup here.
    static func caretQuartzRect(in element: AXUIElement, at position: Int) -> CGRect? {
        rangeGeometry(element, at: position, viewport: nil)?.rect
    }

    /// Called on the AX worker, after the caller has verified a nonsecure editable field.
    static func inlineGeometry(in element: AXUIElement, at position: Int, before: String, after: String,
                               viewport: CGRect?, selectedMarker: CFTypeRef? = nil) -> Geometry? {
        guard position >= 0 else { return nil }
        lazy var marker = selectedMarker ?? attribute(element, "AXSelectedTextMarkerRange")
        func selectedCaret() -> (CGRect, Source)? {
            if let raw = rangeValue(position, 0), selectedMarker == nil,
               let rect = bounds(element, raw, kAXBoundsForRangeParameterizedAttribute),
               let caret = anchoredRect(rect, source: .selectedRange, viewport: viewport) {
                return (caret, .selectedRange)
            }
            if let marker, let rect = bounds(element, marker, "AXBoundsForTextMarkerRange"),
               let caret = anchoredRect(rect, source: .selectedMarker, viewport: viewport) {
                return (caret, .selectedMarker)
            }
            return nil
        }

        var anchor = selectedCaret()
        func previousGlyph(_ last: Character) -> CGRect? {
            if selectedMarker != nil || anchor?.1 == .selectedMarker {
                // Marker snapshots count text relative to the editor. Numeric ranges may
                // include embedded objects or separators absent from that string.
                return previousMarkerEnd(in: element, marker: marker, viewport: viewport)
            }
            return trailingCharacter(in: element, at: position, last: last, viewport: viewport)
                ?? previousMarkerEnd(in: element, marker: marker, viewport: viewport)
        }
        let atLineEnd = after.isEmpty || after.first?.isNewline == true
        if atLineEnd, let last = before.last, !last.isNewline, isLTRLineEnd(before),
           let trailing = previousGlyph(last) {
            if let (caret, _) = anchor {
                if prefersTrailingGlyph(over: caret, trailing: trailing, element: element,
                                        at: position, previousLength: last.utf16.count) {
                    anchor = (trailing, .previousCharacter)
                }
            } else {
                anchor = (trailing, .previousCharacter)
            }
        }
        if let (rect, source) = anchor {
            return Geometry(rect: rect, source: source, font: hostFont(element, position: position, marker: marker))
        }
        if !atLineEnd, let geometry = rangeGeometry(element, at: position, viewport: viewport, includeSelection: false,
                                                   allowPrevious: before.last?.isNewline != true) {
            return Geometry(rect: geometry.rect, source: geometry.source, font: hostFont(element, position: position))
        }
        guard atLineEnd, let viewport else { return nil }
        return visibleRunGeometry(element, before: before, viewport: viewport)
    }

    private static func prefersTrailingGlyph(over caret: CGRect, trailing: CGRect, element: AXUIElement,
                                             at position: Int, previousLength: Int) -> Bool {
        if caret.height > 1.6 * trailing.height { return true }
        let sameRow = abs(caret.midY - trailing.midY) < min(caret.height, trailing.height) / 2
        if sameRow {
            // A little space for side bearings, kerning and pixel rounding is normal.
            guard abs(caret.minX - trailing.minX) > trailing.height / 2 else { return false }
        } else if caret.midY <= trailing.midY || caret.minX >= trailing.minX {
            return true
        }
        // The caret may genuinely be at the start of the next line even though the
        // previous glyph is on the old line (downstream affinity at a soft wrap).
        return insertionSharesPreviousRow(element, at: position, previousLength: previousLength)
    }

    private static func insertionSharesPreviousRow(_ element: AXUIElement, at pos: Int, previousLength: Int) -> Bool {
        guard let row = attribute(element, kAXInsertionPointLineNumberAttribute) as? Int,
              let raw = parameter(element, kAXRangeForLineParameterizedAttribute, NSNumber(value: row)),
              let range = value(raw, type: .cfRange, initial: CFRange()),
              range.location >= 0, range.location <= pos - previousLength else { return false }
        return pos - range.location <= range.length
    }

    private static func isLTRLineEnd(_ before: String) -> Bool {
        let start = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let tail = before[start...]
        return !tail.isEmpty && tail.range(of: #"[\p{Arabic}\p{Hebrew}\u202A-\u202E\u2066-\u2069]"#, options: .regularExpression) == nil
    }

    private static func trailingCharacter(in element: AXUIElement, at position: Int, last: Character,
                                          viewport: CGRect?, excluding fullBox: CGRect? = nil) -> CGRect? {
        let length = last.utf16.count
        guard let raw = rangeValue(position - length, length),
              let rect = bounds(element, raw, kAXBoundsForRangeParameterizedAttribute),
              rect != fullBox, rect != viewport else { return nil }
        return anchoredRect(rect, source: .previousCharacter, viewport: viewport)
    }

    private static func previousMarkerEnd(in element: AXUIElement, marker: CFTypeRef?, viewport: CGRect?) -> CGRect? {
        guard let marker, let cursor = parameter(element, "AXStartTextMarkerForTextMarkerRange", marker),
              let previous = parameter(element, "AXPreviousTextMarkerForTextMarker", cursor),
              let span = parameter(element, "AXTextMarkerRangeForUnorderedTextMarkers", [previous, cursor] as CFArray),
              let rect = bounds(element, span, "AXBoundsForTextMarkerRange"), rect != viewport else { return nil }
        return anchoredRect(rect, source: .previousCharacter, viewport: viewport)
    }

    private static func rangeGeometry(_ element: AXUIElement, at position: Int, viewport: CGRect?,
                                      includeSelection: Bool = true, allowPrevious: Bool = true) -> Geometry? {
        let probes: [(Int, Int, Source)] = [(position, 0, .selectedRange), (position, 1, .nextCharacter),
                                            (position - 1, 1, .previousCharacter)]
        for (start, length, source) in probes {
            if source == .selectedRange && !includeSelection || source == .previousCharacter && !allowPrevious { continue }
            guard let range = rangeValue(start, length),
                  let rect = bounds(element, range, kAXBoundsForRangeParameterizedAttribute),
                  let caret = anchoredRect(rect, source: source, viewport: viewport) else { continue }
            return Geometry(rect: caret, source: source, font: nil)
        }
        return nil
    }

    /// Some hosts return the entire text-field frame even for an empty range. Accept only
    /// caret-shaped exact bounds or a plausible single glyph for a neighbouring character.
    static func anchoredRect(_ rect: CGRect, source: Source, viewport: CGRect?) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.size.width >= 0, (3...256).contains(rect.size.height) else { return nil }
        if source.isExact && rect.width > max(4, rect.height * 0.25) { return nil }
        if source == .previousCharacter || source == .nextCharacter, rect.width > rect.height * 2 { return nil }
        let rightEdge = source == .previousCharacter || source == .visibleRun
        let caret = CGRect(x: rightEdge ? rect.maxX : rect.minX, y: rect.minY, width: 1, height: rect.height)
        if let viewport, !viewport.insetBy(dx: -2, dy: -2).contains(caret) { return nil }
        return caret
    }

    /// Match a visible text run ending at the caret, then locate its final glyph or line. Ambiguous or
    /// incompletely explored trees yield no geometry. No search outside the focused editor.
    private static func visibleRunGeometry(_ element: AXUIElement, before: String, viewport: CGRect) -> Geometry? {
        let deadline = DispatchTime.now() + .milliseconds(85)
        var queue = [element]
        var index = 0
        var match: Geometry?
        while index < queue.count {
            guard DispatchTime.now() < deadline else { return nil }
            let node = queue[index]
            let isRoot = index == 0
            index += 1
            if !isRoot {
                AXUIElementSetMessagingTimeout(node, 0.035)
                let role = attribute(node, kAXRoleAttribute) as? String
                if role == kAXStaticTextRole {
                    guard let geometry = staticTextEnd(node, before: before, viewport: viewport) else { continue }
                    guard match == nil else { return nil }
                    match = geometry
                    continue
                }
                // Do not traverse nested inputs, password fields, links, or neighbouring web areas.
                guard let role, [kAXGroupRole, kAXScrollAreaRole, "AXLayoutArea", "AXParagraph"].contains(role) else { continue }
            }
            var children: CFArray?
            var error = AXUIElementCopyAttributeValues(node, kAXVisibleChildrenAttribute as CFString, 0, 25, &children)
            if error == .attributeUnsupported || error == .noValue {
                error = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, 25, &children)
            }
            if error == .attributeUnsupported || error == .noValue { continue }
            guard error == .success, let nodes = children as? [AXUIElement], nodes.count + queue.count <= 24 else { return nil }
            queue.append(contentsOf: nodes)
        }
        return match
    }

    private static func staticTextEnd(_ node: AXUIElement, before: String, viewport: CGRect) -> Geometry? {
        guard let text = attribute(node, kAXValueAttribute) as? String, let last = text.last, !last.isNewline,
              let box = frame(node) else { return nil }
        let multiline = text.contains(where: \.isNewline)
        if multiline {
            // Compare the overlapping context too: distinct paragraphs may end in the same word.
            let run = text.replacingOccurrences(of: "\u{00a0}", with: " ")
            let context = before.replacingOccurrences(of: "\u{00a0}", with: " ")
            guard run.hasSuffix(context) || context.hasSuffix(run) else { return nil }
        }
        let start = text.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        guard matchesLineEnd(run: String(text[start...]), before: before) else { return nil }
        let offset = text.utf16.count
        let font = hostFont(node, position: offset)
        let inside = box.insetBy(dx: -2, dy: -2)

        if let end = trailingCharacter(in: node, at: offset, last: last, viewport: viewport, excluding: box), inside.contains(end),
           !multiline || end.height < box.height - 1 {
            return Geometry(rect: end, source: .visibleRun, font: font)
        }

        let lastLine = parameter(node, kAXLineForIndexParameterizedAttribute, NSNumber(value: offset - 1)) as? Int
        if let lastLine, let raw = parameter(node, kAXRangeForLineParameterizedAttribute, NSNumber(value: lastLine)),
           let line = value(raw, type: .cfRange, initial: CFRange()), line.location > 0,
           line.location < offset, line.length == offset - line.location,
           let rect = bounds(node, raw, kAXBoundsForRangeParameterizedAttribute), rect.height < box.height - 1,
           let end = anchoredRect(rect, source: .visibleRun, viewport: viewport), inside.contains(end) {
            return Geometry(rect: end, source: .visibleRun, font: font)
        }

        // The right edge of the full node is valid only for a single visual line.
        guard !multiline else { return nil }
        if let font {
            guard box.height <= 1.5 * (font.ascender - font.descender + max(0, font.leading)) else { return nil }
        } else {
            guard let lastLine, let first = parameter(node, kAXLineForIndexParameterizedAttribute, NSNumber(value: 0)) as? Int,
                  first == lastLine else { return nil }
        }
        guard let end = anchoredRect(box, source: .visibleRun, viewport: viewport) else { return nil }
        return Geometry(rect: end, source: .visibleRun, font: font)
    }

    static func matchesLineEnd(run: String, before: String) -> Bool {
        // Chromium can encode a typed trailing space as a nonbreaking space in the AX tree.
        let text = run.replacingOccurrences(of: "\u{00a0}", with: " ")
        let start = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let tail = before[start...].replacingOccurrences(of: "\u{00a0}", with: " ")
        guard text.utf16.count >= 2, tail.utf16.count >= 2, !text.contains(where: \.isNewline),
              text.range(of: #"[\p{Latin}\p{Cyrillic}]"#, options: .regularExpression) != nil,
              text.range(of: #"[\p{Arabic}\p{Hebrew}\u202A-\u202E\u2066-\u2069]"#, options: .regularExpression) == nil else { return false }
        return tail.hasSuffix(text) || text.hasSuffix(tail)
    }

    private static func hostFont(_ element: AXUIElement, position: Int, marker: @autoclosure () -> CFTypeRef? = nil) -> NSFont? {
        guard position > 0 else { return nil }
        var styled: NSAttributedString?
        if let range = rangeValue(position - 1, 1) {
            styled = parameter(element, kAXAttributedStringForRangeParameterizedAttribute, range) as? NSAttributedString
        }
        if styled?.length ?? 0 == 0, let marker = marker(),
           let cursor = parameter(element, "AXStartTextMarkerForTextMarkerRange", marker),
           let previous = parameter(element, "AXPreviousTextMarkerForTextMarker", cursor),
           let span = parameter(element, "AXTextMarkerRangeForUnorderedTextMarkers", [previous, cursor] as CFArray) {
            styled = parameter(element, "AXAttributedStringForTextMarkerRange", span) as? NSAttributedString
        }
        guard let styled, styled.length > 0 else { return nil }
        let attrs = styled.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[.font] as? NSFont { return font }
        guard let info = attrs[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
              let size = info[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber, (5...200).contains(size.doubleValue) else { return nil }
        let name = (info[kAXFontNameKey.takeUnretainedValue() as String] ?? info[kAXFontFamilyKey.takeUnretainedValue() as String]) as? String
        let points = CGFloat(size.doubleValue)
        return name.flatMap { NSFont(name: $0, size: points) } ?? NSFont.systemFont(ofSize: points)
    }

    static func inlineFrame(caret: CGRect, label: NSTextField) -> CGRect {
        guard let font = label.font else { return CGRect(origin: caret.origin, size: label.frame.size) }
        let baseline = caret.midY - (font.ascender + font.descender) / 2
        return CGRect(x: caret.minX, y: baseline - label.lastBaselineOffsetFromBottom,
                      width: label.frame.width, height: label.frame.height)
    }

    static func flipToCocoa(_ r: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return r }
        return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = value(attribute(element, kAXPositionAttribute), type: .cgPoint, initial: CGPoint.zero),
              let size = value(attribute(element, kAXSizeAttribute), type: .cgSize, initial: CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func rangeValue(_ location: Int, _ length: Int) -> AXValue? {
        guard location >= 0 else { return nil }
        var range = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &range)
    }

    private static func value<T>(_ raw: CFTypeRef?, type: AXValueType, initial: T) -> T? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = initial
        return withUnsafeMutablePointer(to: &result) { pointer in
            AXValueGetValue(raw as! AXValue, type, pointer) ? pointer.pointee : nil
        }
    }

    private static func bounds(_ element: AXUIElement, _ argument: CFTypeRef, _ key: String) -> CGRect? {
        value(parameter(element, key, argument), type: .cgRect, initial: CGRect.zero)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    private static func parameter(_ element: AXUIElement, _ key: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, key as CFString, argument, &result) == .success else { return nil }
        return result
    }
}
