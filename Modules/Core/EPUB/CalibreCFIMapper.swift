import Foundation
import YueduCoreTextTypography

/// Calibre 9.x uses a spine prefix followed by the DOM path, rather than the
/// EPUB package CFI (/6/...!). Work from its actual prepared JSON DOM: Calibre
/// may insert a cover or repair XHTML, so an original EPUB path is not enough.
/// https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/pyj/read_book/iframe.pyj
enum CalibreCFIMapper {
    struct Match: Equatable {
        let cfi: String
        let text: String
        let textOffset: Int
    }

    private struct Location { let path: String; let offset: Int; let text: String }
    private struct Normalized { var text = ""; var offsets: [Int] = [] }

    /// Whitespace collapsed by CSS and renderer-inserted separators have no
    /// durable DOM offset. Map to the next actual character, preserving the
    /// source's UTF-16 offset (including entities, emoji and combining marks).
    private static func normalize(_ value: String, isVertical: Bool) throws -> Normalized {
        // Use the renderer's existing deterministic 1:1 substitutions on both
        // sides. Font-specific vertical glyph fallbacks otherwise turn matching
        // brackets into different Unicode values. Offsets still address raw DOM.
        let comparable = isVertical ? value.normalizedForVerticalLayout() : value
        guard comparable.utf16.count == value.utf16.count else { throw CalibreProgressError.invalidData }
        var result = Normalized(), offset = 0
        for scalar in comparable.unicodeScalars {
            let length = scalar.utf16.count
            if !CharacterSet.whitespacesAndNewlines.contains(scalar), scalar.value != 0xFFFC {
                result.text.unicodeScalars.append(scalar)
                result.offsets.append(contentsOf: (0..<length).map { offset + $0 })
            }
            offset += length
        }
        return result
    }

    static func match(document: Data, spineIndex: Int, renderedText: String, charOffset: Int,
                      isVertical: Bool = false) throws -> Match {
        guard spineIndex >= 0,
              let json = try JSONSerialization.jsonObject(with: document) as? [String: Any],
              (json["version"] as? Int) == 1,
              let root = json["tree"] as? [String: Any], root["n"] as? String == "html" else {
            throw CalibreProgressError.invalidData
        }
        let rendered = renderedText as NSString
        guard charOffset >= 0, charOffset < rendered.length,
              rendered.character(at: charOffset) != 0xFFFC else { throw CalibreProgressError.unmappedPosition }
        let needle = try normalize(renderedText, isVertical: isVertical)
        guard let target = needle.offsets.firstIndex(where: { $0 >= charOffset }) else {
            throw CalibreProgressError.unmappedPosition
        }

        var source = "", locations: [Location] = []
        func add(_ text: String, path: String) throws {
            let normalized = try normalize(text, isVertical: isVertical)
            source += normalized.text
            locations.append(contentsOf: normalized.offsets.map { Location(path: path, offset: $0, text: text) })
        }
        func walk(_ node: [String: Any], path: String, inBody: Bool, depth: Int) throws {
            guard depth < 256 else { throw CalibreProgressError.invalidData }
            let tag = node["n"] as? String ?? ""
            let visible = (inBody || tag == "body") && !["script", "style"].contains(tag)
            var elementIndex = 0
            var text = node["x"] as? String ?? ""
            for child in node["c"] as? [[String: Any]] ?? [] {
                if child["n"] is String {
                    if visible { try add(text, path: path + "/\(elementIndex * 2 + 1)") }
                    text = ""
                    elementIndex += 1
                    try walk(child, path: path + "/\(elementIndex * 2)", inBody: visible, depth: depth + 1)
                }
                // Comments do not consume an element step; adjacent text/tails
                // share one odd step and their UTF-16 offsets are accumulated.
                text += child["l"] as? String ?? ""
            }
            if visible { try add(text, path: path + "/\(elementIndex * 2 + 1)") }
        }
        try walk(root, path: "/2", inBody: false, depth: 0)
        let haystack = source as NSString
        let context = needle.text as NSString
        // Use a unique literal context, never fuzzy matching or a guessed chapter
        // fraction. Narrowing permits a real text anchor beside generated lists,
        // ruby annotations or attachments; ambiguity stays an explicit error.
        // A one-sided context also covers text next to a rasterized table: the
        // reader has one attachment where the server DOM has many cell texts.
        // Keep range arithmetic explicit so Swift 6.3 can type-check Release builds.
        let radii: [Int] = [512, 256, 128, 64, 32, 16, 8]
        var windows: [NSRange] = []
        for radius in radii {
            let start = max(0, target - radius)
            let end = min(context.length, target + radius)
            let forwardLength = min(radius, context.length - target)
            let backwardEnd = min(context.length, target + 1)
            windows.append(NSRange(location: start, length: end - start))
            windows.append(NSRange(location: target, length: forwardLength))
            windows.append(NSRange(location: start, length: backwardEnd - start))
        }
        for requested in windows {
            let window = context.rangeOfComposedCharacterSequences(for:
                requested)
            let start = window.location, end = NSMaxRange(window)
            guard end - start >= min(16, context.length), end > start else { continue }
            let text = context.substring(with: NSRange(location: start, length: end - start))
            let found = haystack.range(of: text, options: .literal)
            guard found.location != NSNotFound else { continue }
            let restStart = found.location + 1
            let second = haystack.range(of: text, options: .literal,
                range: NSRange(location: restStart, length: haystack.length - restStart))
            guard second.location == NSNotFound else { continue }
            let location = locations[found.location + target - start]
            return Match(cfi: "epubcfi(/\((spineIndex + 1) * 2)\(location.path):\(location.offset))",
                         text: location.text, textOffset: location.offset)
        }
        throw CalibreProgressError.unmappedPosition
    }
}
