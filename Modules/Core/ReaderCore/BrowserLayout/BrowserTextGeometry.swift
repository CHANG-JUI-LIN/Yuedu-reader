import CoreText
import UIKit

/// Selection, annotations and narration all consume the shaped display text.
/// No second layout is performed for hit testing.
enum BrowserTextGeometry {
    static func rects(in list: DisplayList, range: NSRange) -> [CGRect] {
        list.items.compactMap { item in
            guard case .text(let text) = item else { return nil }
            let part = NSIntersectionRange(text.sourceRange, range)
            guard part.length > 0 else { return nil }
            guard case .linear(let shapedRange) = text.sourceMapping,
                  let line = text.ctLine else { return text.rect.rawValue }
            let start = shapedRange.location + part.location - text.sourceRange.location
            let end = start + part.length
            let lineRange = CTLineGetStringRange(line)
            guard start >= lineRange.location, end <= lineRange.location + lineRange.length else { return nil }
            let origin = physicalOrigin(line, shapedRange: shapedRange)
            let a = CTLineGetOffsetForStringIndex(line, start, nil) - origin
            let b = CTLineGetOffsetForStringIndex(line, end, nil) - origin
            return CGRect(x: text.rect.minX + min(a, b), y: text.rect.minY,
                          width: max(1, abs(b - a)), height: text.rect.height)
        }
    }

    static func range(at point: CGPoint, in list: DisplayList, source: NSString, nearest: Bool = false) -> NSRange? {
        let texts = list.items.compactMap { item -> DisplayTextItem? in
            guard case .text(let text) = item, text.sourceRange.length > 0 else { return nil }
            return text
        }
        let target = texts.reversed().first { $0.rect.contains(point) } ?? (nearest ? texts.min {
            distance(point, to: $0.rect.rawValue) < distance(point, to: $1.rect.rawValue)
        } : nil)
        guard let text = target else { return nil }
        guard case .linear(let shapedRange) = text.sourceMapping,
              let line = text.ctLine else { return text.sourceRange }
        let origin = physicalOrigin(line, shapedRange: shapedRange)
        let shaped = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x - text.rect.minX + origin, y: 0))
        guard shaped != kCFNotFound else { return nil }
        let offset = min(NSMaxRange(text.sourceRange) - 1,
                         max(text.sourceRange.location, text.sourceRange.location + shaped - shapedRange.location))
        guard offset >= 0, offset < source.length else { return nil }
        // CTLine returns an insertion position (often the next character in
        // the right half of a glyph). Selection needs the glyph under the
        // finger, including the complete UTF-16 cluster for emoji.
        let candidate = source.rangeOfComposedCharacterSequence(at: offset)
        let previous = source.rangeOfComposedCharacterSequence(at: max(0, offset - 1))
        for range in [candidate, previous] {
            if rects(in: list, range: range).contains(where: { $0.contains(point) }) { return range }
        }
        return candidate
    }

    static func caret(at offset: Int, isEnd: Bool, in list: DisplayList) -> CGPoint? {
        let character = max(0, offset - (isEnd ? 1 : 0))
        for item in list.items {
            guard case .text(let text) = item,
                  NSLocationInRange(character, text.sourceRange),
                  case .linear(let shapedRange) = text.sourceMapping,
                  let line = text.ctLine else { continue }
            let index = shapedRange.location + offset - text.sourceRange.location
            return CGPoint(x: text.rect.minX + CTLineGetOffsetForStringIndex(line, index, nil) - physicalOrigin(line, shapedRange: shapedRange),
                           y: isEnd ? text.rect.maxY : text.rect.minY)
        }
        return nil
    }

    private static func physicalOrigin(_ line: CTLine, shapedRange: NSRange) -> CGFloat {
        // Logical start is the RIGHT edge of an RTL run. Display fragments
        // store their physical left edge, independent of text direction.
        min(CTLineGetOffsetForStringIndex(line, shapedRange.location, nil),
            CTLineGetOffsetForStringIndex(line, NSMaxRange(shapedRange), nil))
    }

    private static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
