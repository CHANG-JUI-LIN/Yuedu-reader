import UIKit

struct CommentBubbleSVG {
    let viewBox: CGRect
    let width: CGFloat
    let height: CGFloat
    
    enum Element {
        case path(d: String, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case image(data: Data, rect: CGRect, transform: CGAffineTransform)
        case text(text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, fontWeight: String?, anchor: String?, color: UIColor?, transform: CGAffineTransform)
    }
    
    let elements: [Element]

    var displayText: String? {
        for element in elements {
            if case .text(let text, _, _, _, _, _, _, _) = element {
                return text
            }
        }
        return nil
    }

    func replacingDisplayText(with text: String) -> CommentBubbleSVG {
        CommentBubbleSVG(
            viewBox: viewBox,
            width: width,
            height: height,
            elements: elements.map { element in
                guard case let .text(_, x, y, fontSize, fontWeight, anchor, color, transform) = element else {
                    return element
                }
                return .text(
                    text: text,
                    x: x,
                    y: y,
                    fontSize: fontSize,
                    fontWeight: fontWeight,
                    anchor: anchor,
                    color: color,
                    transform: transform
                )
            }
        )
    }
}

extension CommentBubbleSVG.Element {
    /// The composed `<g>` transform attached to this element (identity when ungrouped).
    var transform: CGAffineTransform {
        switch self {
        case .path(_, _, _, _, let t): return t
        case .rect(_, _, _, _, _, _, _, _, _, let t): return t
        case .image(_, _, let t): return t
        case .text(_, _, _, _, _, _, _, let t): return t
        }
    }
}

struct CommentBubbleSVGRecognizer {
    /// Custom SVG templates are intentionally bounded to keep parsing and native rasterization
    /// predictable, while still accepting detailed user-authored artwork such as 猫咪气泡.svg.
    static let maximumRecognizableSVGByteCount = 32 * 1024

    static let builtinBubbleSVG = """
    <svg width="96" height="72" viewBox="0 0 96 72" style="color:#8E8E93" xmlns="http://www.w3.org/2000/svg">
      <rect x="8" y="8" width="80" height="56" rx="18" ry="18" fill="none" stroke="currentColor" stroke-width="6"/>
      <text x="48" y="46" font-size="30" font-weight="600" text-anchor="middle" fill="currentColor">0</text>
    </svg>
    """

    static let squareBubbleSVG = """
    <svg width="96" height="72" viewBox="0 0 96 72" style="color:#8E8E93" xmlns="http://www.w3.org/2000/svg">
      <path d="M10 10 H86 V52 H58 L48 62 L38 52 H10 Z" fill="none" stroke="currentColor" stroke-width="6"/>
      <text x="48" y="44" font-size="28" font-weight="600" text-anchor="middle" fill="currentColor">0</text>
    </svg>
    """

    static func templateSVG(
        for mode: ReaderCommentBubblePresetMode,
        customSVG: String
    ) -> String {
        switch mode {
        case .builtin:
            return builtinBubbleSVG
        case .square:
            return squareBubbleSVG
        case .custom:
            return customSVG.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func inlineAttachmentHeight(
        pointSize: CGFloat,
        lineHeight: CGFloat,
        overallScale: CGFloat
    ) -> CGFloat {
        let boundedOverallScale = min(max(overallScale, 0.5), 2.0)
        return max(pointSize, lineHeight) * boundedOverallScale
    }

    // MARK: - Diagnostics (⟐ bubble) — deduped so a chapter's hundreds of bubbles
    // don't flood Console; each distinct signature logs once per process.
    private static let diagLock = NSLock()
    nonisolated(unsafe) private static var diagSeen = Set<String>()
    static func diag(_ signature: String, context: [String: Any] = [:]) {
        diagLock.lock()
        let isNew = diagSeen.insert(signature).inserted
        diagLock.unlock()
        guard isNew else { return }
        AppLogger.parse("⟐ bubble \(signature)", context: context)
    }

    /// Checks if the given image source or SVG string represents a recognizable simple comment bubble.
    /// If so, decodes and parses it into a CommentBubbleSVG representation.
    static func recognize(src: String, svgContent: String?) -> CommentBubbleSVG? {
        guard let svg = getSVGString(src: src, svgContent: svgContent) else {
            diag("reject:no-svg", context: ["srcPrefix": String(src.prefix(48))])
            return nil
        }

        let cleaned = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bound the parse, but generously: iconfont 段評 bubbles (企点/光遇) embed a full
        // outline <path> (~1.4–1.9k chars). The structural checks below — exactly one
        // count-formatted <text> plus a shape — are what actually gate non-bubble SVGs, so
        // a tight length cap only mis-rejected real bubbles (光遇's is ~1916 chars).
        let byteCount = cleaned.utf8.count
        guard byteCount <= maximumRecognizableSVGByteCount else {
            diag("reject:too-long", context: ["bytes": byteCount, "limit": maximumRecognizableSVGByteCount])
            return nil
        }

        // Must contain exactly one text element
        let textOpen = countOccurrences(of: "<text", in: cleaned)
        let textClose = countOccurrences(of: "</text>", in: cleaned)
        guard textOpen == 1, textClose == 1 else {
            diag("reject:text-count", context: ["open": textOpen, "close": textClose, "len": cleaned.count])
            return nil
        }

        guard let parsed = parseSVG(cleaned) else {
            diag("reject:parse-fail", context: ["len": cleaned.count])
            return nil
        }
        let hasTransform = parsed.elements.contains { !$0.transform.isIdentity }
        diag("ok:vb=\(Int(parsed.viewBox.width))x\(Int(parsed.viewBox.height))",
             context: ["wh": "\(Int(parsed.width))x\(Int(parsed.height))",
                       "origin": "\(Int(parsed.viewBox.minX)),\(Int(parsed.viewBox.minY))",
                       "elements": parsed.elements.count,
                       "hasTransform": hasTransform,
                       "len": cleaned.count])
        return parsed
    }

    static func resolvedBubbleImage(
        src: String,
        svgContent: String?,
        pointSize: CGFloat,
        themeTextColor: UIColor
    ) -> UIImage? {
        guard let sourceBubble = recognize(src: src, svgContent: svgContent) else { return nil }
        let settings = GlobalSettings.shared
        if settings.commentBubbleFollowsSourceSVG {
            return draw(svg: sourceBubble, pointSize: pointSize, themeTextColor: themeTextColor)
        }

        let bubbleText = sourceBubble.displayText ?? "0"
        var templateSource = templateSVG(
            for: settings.commentBubblePresetMode,
            customSVG: settings.commentBubbleSelectedCustomStyle?.svg ?? ""
        )
        // bubble.json-imported styles keep a literal `${color}` placeholder in
        // their text fill (`fill="${color}"`). The parser can only resolve real
        // hex/rgb colours, so we substitute the JSON's day/night + normal/emphasis
        // hex into the raw SVG string *before* recognition. Styles authored in
        // the legacy SVG editor (no `${color}` token) are untouched.
        if let style = settings.commentBubbleSelectedCustomStyle, style.usesColorTemplate {
            let hex = style.resolvedColorHex(
                forCount: bubbleText,
                isNight: isNightTheme(themeTextColor: themeTextColor)
            )
            templateSource = materializeColorTemplate(
                templateSource,
                colorHex: hex
            )
        }
        let template = recognize(src: "", svgContent: templateSource)
            ?? recognize(src: "", svgContent: builtinBubbleSVG)

        guard let template else {
            return draw(svg: sourceBubble, pointSize: pointSize, themeTextColor: themeTextColor)
        }
        return draw(
            svg: template.replacingDisplayText(with: bubbleText),
            pointSize: pointSize,
            themeTextColor: themeTextColor,
            overallScale: CGFloat(settings.commentBubbleScale),
            textScaleRatio: CGFloat(settings.commentBubbleTextScale)
        )
    }

    /// Substitutes the `${color}` placeholder (case-insensitive) inside an SVG
    /// template with a concrete hex string, leaving every other token intact.
    /// Used by both render-time materialization and the settings preview.
    static func materializeColorTemplate(_ svg: String, colorHex: String) -> String {
        svg.replacingOccurrences(of: "${color}", with: colorHex)
            .replacingOccurrences(of: "${Color}", with: colorHex)
    }

    /// Infers whether the reader is in night mode from the body text colour the
    /// paginator already resolved. The night theme renders text on a dark
    /// background, so the body text luminance is high; day themes sit well below
    /// 0.5. This avoids plumbing a separate isNight flag through every render
    /// call site.
    static func isNightTheme(themeTextColor: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        themeTextColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.5
    }
    
    private static func getSVGString(src: String, svgContent: String?) -> String? {
        if let svgContent, !svgContent.isEmpty {
            return svgContent
        }
        guard src.hasPrefix("data:"), src.lowercased().contains("svg") else { return nil }
        let cleaned = OnlineImageLoader.cleanImageSource(src)
        guard let commaIdx = cleaned.firstIndex(of: ",") else { return nil }
        let meta = cleaned[cleaned.startIndex..<commaIdx].lowercased()
        let payload = String(cleaned[cleaned.index(after: commaIdx)...])
        let isBase64 = meta.contains(";base64")
        
        let decodedData: Data?
        if isBase64 {
            decodedData = Data(
                base64Encoded: payload.trimmingCharacters(in: .whitespacesAndNewlines),
                options: .ignoreUnknownCharacters
            )
        } else {
            decodedData = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let data = decodedData, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    private static func countOccurrences(of substring: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let foundRange = text.range(of: substring, options: .caseInsensitive, range: range) {
            count += 1
            range = foundRange.upperBound..<text.endIndex
        }
        return count
    }
    
    private static func parseSVG(_ svg: String) -> CommentBubbleSVG? {
        // 1. Parse <svg> tag attributes
        guard let svgRange = svg.range(of: "<svg[^>]*>", options: .regularExpression) else { return nil }
        let svgTag = String(svg[svgRange])
        
        let width = parseDouble(extractAttribute("width", in: svgTag))
        let height = parseDouble(extractAttribute("height", in: svgTag))
        
        var viewBox = CGRect.zero
        if let vbStr = extractAttribute("viewBox", in: svgTag) {
            let parts = vbStr.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: CharacterSet.whitespaces.union(.init(charactersIn: ",")))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
        }
        
        if viewBox.width <= 0 || viewBox.height <= 0 {
            if width > 0 && height > 0 {
                viewBox = CGRect(x: 0, y: 0, width: width, height: height)
            } else {
                // Default fallback
                viewBox = CGRect(x: 0, y: 0, width: 180, height: 144)
            }
        }
        
        let finalWidth = width > 0 ? width : viewBox.width
        let finalHeight = height > 0 ? height : viewBox.height

        // The SVG-level `color` (attribute or `style="color: …"`) is what `currentColor`
        // resolves to on descendants. 光遇 段評 bubbles paint their shapes with
        // `stroke="currentColor"` + a root `style="color: #xxx"`, so without this the outline
        // would be drawn with no colour at all (invisible bubble).
        let rootColor = resolveColor(styleProperty("color", in: svgTag) ?? extractAttribute("color", in: svgTag),
                                     inheritedColor: nil)

        var elements: [CommentBubbleSVG.Element] = []

        // Map every element to the composed transform of the <g> groups wrapping it.
        // 起点/企点/光遇 段評 bubbles draw an iconfont <path> inside
        // `<g transform="rotate(…) scale(…) translate(…)">`; without honoring it the
        // shape lands rotated/offset in an oversized viewBox.
        let groupSpans = parseGroupSpans(svg)

        // 2. Parse <path> tags
        let pathPattern = #"<path\b[^>]*>"#
        if let pathRegex = try? NSRegularExpression(pattern: pathPattern, options: .caseInsensitive) {
            let ns = svg as NSString
            let matches = pathRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let tag = ns.substring(with: match.range)
                let d = extractAttribute("d", in: tag) ?? ""
                let elementColor = resolveElementColor(in: tag, inheritedColor: rootColor)
                let stroke = resolvePaint("stroke", in: tag, inheritedColor: elementColor)
                let strokeWidth = parseStrokeWidth(in: tag)
                let fill = resolvePaint("fill", in: tag, inheritedColor: elementColor)
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                // Accept a <path> as a shape even without d, as long as it has fill or stroke.
                if !d.isEmpty || fill != nil || stroke != nil {
                    elements.append(.path(d: d, strokeColor: stroke, strokeWidth: strokeWidth > 0 ? strokeWidth : nil, fillColor: fill, transform: transform))
                }
            }
        }

        // 3. Parse <rect> tags
        let rectPattern = #"<rect\b[^>]*>"#
        if let rectRegex = try? NSRegularExpression(pattern: rectPattern, options: .caseInsensitive) {
            let ns = svg as NSString
            let matches = rectRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let tag = ns.substring(with: match.range)
                let rx = parseDouble(extractAttribute("rx", in: tag))
                let ry = parseDouble(extractAttribute("ry", in: tag))
                let rxVal = rx > 0 ? rx : ry
                let ryVal = ry > 0 ? ry : rx
                let x = parseCoordinate(extractAttribute("x", in: tag), viewBoxSize: viewBox.width)
                let y = parseCoordinate(extractAttribute("y", in: tag), viewBoxSize: viewBox.height)
                let w = parseCoordinate(extractAttribute("width", in: tag), viewBoxSize: viewBox.width)
                let h = parseCoordinate(extractAttribute("height", in: tag), viewBoxSize: viewBox.height)
                let elementColor = resolveElementColor(in: tag, inheritedColor: rootColor)
                let stroke = resolvePaint("stroke", in: tag, inheritedColor: elementColor)
                let strokeWidth = parseStrokeWidth(in: tag)
                let fill = resolvePaint("fill", in: tag, inheritedColor: elementColor)
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                elements.append(.rect(x: x, y: y, width: w, height: h, rx: rxVal, ry: ryVal, strokeColor: stroke, strokeWidth: strokeWidth > 0 ? strokeWidth : nil, fillColor: fill, transform: transform))
            }
        }
        
        // 3b. Parse <circle> / <ellipse> tags. 光遇 has a round 段評 bubble style; without this the
        // SVG has no shape element, recognition fails, and it drops to the slow WebView rasterizer.
        // A circle/ellipse is drawn as a fully-rounded rect (corner radii == radii).
        let circlePattern = #"<(?:circle|ellipse)\b[^>]*>"#
        if let circleRegex = try? NSRegularExpression(pattern: circlePattern, options: .caseInsensitive) {
            let ns = svg as NSString
            let matches = circleRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let tag = ns.substring(with: match.range)
                let cx = parseCoordinate(extractAttribute("cx", in: tag), viewBoxSize: viewBox.width)
                let cy = parseCoordinate(extractAttribute("cy", in: tag), viewBoxSize: viewBox.height)
                let r = parseCoordinate(extractAttribute("r", in: tag), viewBoxSize: viewBox.width)
                let rx = r > 0 ? r : parseCoordinate(extractAttribute("rx", in: tag), viewBoxSize: viewBox.width)
                let ry = r > 0 ? r : parseCoordinate(extractAttribute("ry", in: tag), viewBoxSize: viewBox.height)
                guard rx > 0, ry > 0 else { continue }
                let elementColor = resolveElementColor(in: tag, inheritedColor: rootColor)
                let stroke = resolvePaint("stroke", in: tag, inheritedColor: elementColor)
                let strokeWidth = parseStrokeWidth(in: tag)
                let fill = resolvePaint("fill", in: tag, inheritedColor: elementColor)
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                elements.append(.rect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2, rx: rx, ry: ry, strokeColor: stroke, strokeWidth: strokeWidth > 0 ? strokeWidth : nil, fillColor: fill, transform: transform))
            }
        }

        // Raster-backed SVG templates commonly embed detailed artwork as a data URI and
        // place the replaceable count in a normal <text> node. Keep this path bounded by
        // maximumRecognizableSVGByteCount and accept only decodable PNG/JPEG image data.
        let imagePattern = #"<image\b[^>]*>"#
        if let imageRegex = try? NSRegularExpression(pattern: imagePattern, options: .caseInsensitive) {
            let ns = svg as NSString
            let matches = imageRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let tag = ns.substring(with: match.range)
                guard let href = extractAttribute("href", in: tag)
                        ?? extractAttribute("xlink:href", in: tag),
                      let data = decodeEmbeddedRasterImage(href) else {
                    continue
                }
                let x = parseCoordinate(extractAttribute("x", in: tag), viewBoxSize: viewBox.width)
                let y = parseCoordinate(extractAttribute("y", in: tag), viewBoxSize: viewBox.height)
                let width = parseCoordinate(extractAttribute("width", in: tag), viewBoxSize: viewBox.width)
                let height = parseCoordinate(extractAttribute("height", in: tag), viewBoxSize: viewBox.height)
                guard width > 0, height > 0 else { continue }
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                elements.append(.image(
                    data: data,
                    rect: CGRect(x: x, y: y, width: width, height: height),
                    transform: transform
                ))
            }
        }

        // 4. Parse <text> tag and content
        let textPattern = #"<text\b[^>]*>(.*?)</text>"#
        if let textRegex = try? NSRegularExpression(pattern: textPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = svg as NSString
            if let match = textRegex.firstMatch(in: svg, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 {
                let tagRange = match.range(at: 0)
                let tagOnlyRange = svg.range(of: "<text[^>]*>", options: .regularExpression, range: Range(tagRange, in: svg))
                let tag = tagOnlyRange.map { String(svg[$0]) } ?? ""
                
                let rawText = ns.substring(with: match.range(at: 1))
                let text = rawText
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Accept count format (e.g., 99+), or the template placeholders
                // $displayText (legacy SVG) / ${num} (bubble.json convention).
                let isCount = (try? NSRegularExpression(pattern: #"^[0-9]+[+]?$"#))
                    .map { $0.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil } ?? false
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isPlaceholder = trimmedText == "$displayText" || trimmedText == "${num}"
                if isCount || isPlaceholder {
                    let x = parseCoordinate(extractAttribute("x", in: tag), viewBoxSize: viewBox.width)
                    let y = parseCoordinate(extractAttribute("y", in: tag), viewBoxSize: viewBox.height)
                    let fontSize = parseDouble(extractAttribute("font-size", in: tag))
                    let resolvedFontSize = fontSize > 0 ? fontSize : 12.0
                    // `dy` (e.g. "0.35em") shifts the baseline — count bubbles use it to vertically
                    // center the digit on its anchor point. Folded into y here (same user units).
                    let dy = parseDy(extractAttribute("dy", in: tag), fontSize: resolvedFontSize)
                    let fontWeight = extractAttribute("font-weight", in: tag)
                    let anchor = extractAttribute("text-anchor", in: tag)
                    let elementColor = resolveElementColor(in: tag, inheritedColor: rootColor)
                    let color = resolvePaint("fill", in: tag, inheritedColor: elementColor)
                    let transform = composedTransform(at: tagRange.location, groups: groupSpans)

                    elements.append(.text(text: text, x: x, y: y + dy, fontSize: resolvedFontSize, fontWeight: fontWeight, anchor: anchor, color: color, transform: transform))
                }
            }
        }
        
        // Must contain at least one text element and one shape element to be a valid bubble
        guard elements.contains(where: { if case .text = $0 { return true }; return false }),
              elements.contains(where: { if case .text = $0 { return false }; return true }) else {
            return nil
        }
        
        return CommentBubbleSVG(viewBox: viewBox, width: finalWidth, height: finalHeight, elements: elements)
    }
    
    private static func extractAttribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + name + #"\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func decodeEmbeddedRasterImage(_ href: String) -> Data? {
        guard let commaIndex = href.firstIndex(of: ",") else { return nil }
        let metadata = href[..<commaIndex].lowercased()
        guard metadata.hasPrefix("data:image/png") || metadata.hasPrefix("data:image/jpeg") else {
            return nil
        }

        let payload = String(href[href.index(after: commaIndex)...])
        let data: Data?
        if metadata.contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        guard let data, !data.isEmpty, UIImage(data: data) != nil else { return nil }
        return data
    }
    
    private static func parseDouble(_ val: String?) -> CGFloat {
        guard let val else { return 0 }
        let clean = val.trimmingCharacters(in: .whitespacesAndNewlines)
        return CGFloat(Double(clean) ?? 0)
    }

    /// Parses an SVG coordinate value that may be a percentage (e.g. "50%") or an
    /// absolute number.  Percentages are resolved against `viewBoxDimension`.
    private static func parseCoordinate(_ val: String?, viewBoxSize: CGFloat) -> CGFloat {
        guard let val else { return 0 }
        let clean = val.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasSuffix("%") {
            let pct = Double(clean.dropLast().trimmingCharacters(in: .whitespaces)) ?? 0
            return viewBoxSize * CGFloat(pct) / 100.0
        }
        return CGFloat(Double(clean) ?? 0)
    }

    /// Resolves a `<text dy>` baseline shift into user units. `em` is relative to the
    /// element's font-size; `px`/unitless are taken as-is. (e.g. "0.35em" → 0.35·fontSize.)
    private static func parseDy(_ val: String?, fontSize: CGFloat) -> CGFloat {
        guard let clean = val?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !clean.isEmpty else { return 0 }
        if clean.hasSuffix("em") { return CGFloat(Double(clean.dropLast(2)) ?? 0) * fontSize }
        if clean.hasSuffix("px") { return CGFloat(Double(clean.dropLast(2)) ?? 0) }
        return CGFloat(Double(clean) ?? 0)
    }

    // MARK: - <g transform> support

    /// One `<g …>` block's character span plus its own `transform` (identity when absent).
    private struct GroupSpan {
        let start: Int   // location of the opening `<g …>` tag
        let end: Int     // location of the matching `</g>`
        let transform: CGAffineTransform
    }

    /// Walks `<g …>` / `</g>` pairs (with a stack so nesting is handled) and records each
    /// group's span and own transform. Self-closing groups don't appear in these SVGs.
    private static func parseGroupSpans(_ svg: String) -> [GroupSpan] {
        let pattern = #"<g\b([^>]*)>|</g\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = svg as NSString
        var spans: [GroupSpan] = []
        var stack: [(start: Int, transform: CGAffineTransform)] = []
        for match in regex.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            if tag.lowercased().hasPrefix("</g") {
                if let open = stack.popLast() {
                    spans.append(GroupSpan(start: open.start, end: match.range.location, transform: open.transform))
                }
            } else {
                let attrs = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
                let transform = extractAttribute("transform", in: "<g \(attrs)>").map { parseTransform($0) } ?? .identity
                stack.append((start: match.range.location, transform: transform))
            }
        }
        return spans
    }

    /// Composes the transforms of every `<g>` enclosing `location`, innermost applied first
    /// (matching SVG nesting: a point flows through the inner group, then each ancestor).
    private static func composedTransform(at location: Int, groups: [GroupSpan]) -> CGAffineTransform {
        let containing = groups
            .filter { $0.start <= location && location < $0.end }
            .sorted { $0.start > $1.start } // innermost (latest-opening) first
        var t = CGAffineTransform.identity
        for group in containing {
            t = t.concatenating(group.transform)
        }
        return t
    }

    /// Parses an SVG `transform` attribute (translate/scale/rotate/matrix) into a single
    /// affine transform. SVG applies the listed functions left-to-right with the rightmost
    /// applied first to the point, so the ops are folded in reverse.
    private static func parseTransform(_ str: String) -> CGAffineTransform {
        let pattern = #"(\w+)\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .identity }
        let ns = str as NSString
        var ops: [CGAffineTransform] = []
        for match in regex.matches(in: str, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let nums = ns.substring(with: match.range(at: 2))
                .components(separatedBy: CharacterSet(charactersIn: ", \n\t"))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { CGFloat($0) }
            switch name {
            case "translate":
                ops.append(CGAffineTransform(translationX: nums.count > 0 ? nums[0] : 0,
                                             y: nums.count > 1 ? nums[1] : 0))
            case "scale":
                let sx = nums.count > 0 ? nums[0] : 1
                ops.append(CGAffineTransform(scaleX: sx, y: nums.count > 1 ? nums[1] : sx))
            case "rotate":
                let angle = (nums.count > 0 ? nums[0] : 0) * .pi / 180
                if nums.count >= 3 {
                    let cx = nums[1], cy = nums[2]
                    ops.append(CGAffineTransform(translationX: cx, y: cy)
                        .rotated(by: angle)
                        .translatedBy(x: -cx, y: -cy))
                } else {
                    ops.append(CGAffineTransform(rotationAngle: angle))
                }
            case "matrix":
                if nums.count >= 6 {
                    ops.append(CGAffineTransform(a: nums[0], b: nums[1], c: nums[2], d: nums[3], tx: nums[4], ty: nums[5]))
                }
            default:
                break
            }
        }
        return ops.reversed().reduce(.identity) { $0.concatenating($1) }
    }
    
    private static func parseColor(_ val: String?) -> UIColor? {
        guard let val else { return nil }
        let clean = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean == "none" || clean == "transparent" { return nil }
        if clean.hasPrefix("rgb(") && clean.hasSuffix(")") {
            return parseRGBColor(clean)
        }
        return parseHexColor(clean)
    }

    /// Parses a CSS `rgb(r, g, b)` colour (0–255 integer channels). bubble.json
    /// SVG templates emit outline fills as e.g. `fill="rgb(254,254,254)"`;
    /// without this, every such shape painted transparent and the bubble body
    /// vanished entirely (the recognizer kept returning a valid bubble, but the
    /// drawing pass skipped the nil-fill paths).
    private static func parseRGBColor(_ val: String) -> UIColor? {
        let inner = val.dropFirst("rgb(".count).dropLast()
        let parts = inner.split(separator: ",").compactMap { component -> Double? in
            Double(component.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard parts.count >= 3 else { return nil }
        return UIColor(
            red: CGFloat(parts[0]) / 255.0,
            green: CGFloat(parts[1]) / 255.0,
            blue: CGFloat(parts[2]) / 255.0,
            alpha: 1.0
        )
    }

    /// Reads one CSS declaration (e.g. `stroke`, `fill`, `stroke-width`, `color`) from a tag's
    /// `style="a: x; b: y"` attribute. The `\s*:` after the name keeps `stroke` from matching
    /// `stroke-width`/`stroke-opacity`. Returns nil when the attribute or property is absent.
    private static func styleProperty(_ name: String, in tag: String) -> String? {
        guard let style = extractAttribute("style", in: tag) else { return nil }
        let pattern = #"(?:^|;)\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*:\s*([^;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = style as NSString
        guard let match = regex.firstMatch(in: style, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a colour token, resolving `currentColor` to `inheritedColor`. Used both for an
    /// element's own colour and for resolving `currentColor` paints down the tree.
    private static func resolveColor(_ raw: String?, inheritedColor: UIColor?) -> UIColor? {
        guard let raw else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased() == "currentcolor" { return inheritedColor }
        return parseColor(clean)
    }

    /// Resolves an element's CSS `color`, inheriting the root value when the element does not
    /// specify one. This must stay separate from `resolvePaint`: an omitted `fill`/`stroke`
    /// is not the same as `fill="currentColor"`/`stroke="currentColor"`.
    private static func resolveElementColor(in tag: String, inheritedColor: UIColor?) -> UIColor? {
        let raw = styleProperty("color", in: tag) ?? extractAttribute("color", in: tag)
        guard let raw else { return inheritedColor }
        return resolveColor(raw, inheritedColor: inheritedColor)
    }

    /// Resolves an SVG paint (`fill`/`stroke`) honoring, in priority order, the element's inline
    /// `style="fill: …"`, then its presentation attribute; resolves `currentColor` against
    /// `inheritedColor`; and folds the matching `*-opacity` in as alpha. 光遇 段評 bubbles carry
    /// their colour exclusively via `style=` + `currentColor`, which the bare attribute read missed.
    private static func resolvePaint(_ property: String, in tag: String, inheritedColor: UIColor?) -> UIColor? {
        let raw = styleProperty(property, in: tag) ?? extractAttribute(property, in: tag)
        guard let base = resolveColor(raw, inheritedColor: inheritedColor) else { return nil }
        if let opacityStr = styleProperty("\(property)-opacity", in: tag) ?? extractAttribute("\(property)-opacity", in: tag),
           let opacity = Double(opacityStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           opacity >= 0, opacity < 1 {
            return base.withAlphaComponent(CGFloat(opacity))
        }
        return base
    }

    /// Reads `stroke-width` from the inline `style=` first (sources write `stroke-width: 2.5px`),
    /// then the presentation attribute. The trailing `px`/unit is stripped.
    private static func parseStrokeWidth(in tag: String) -> CGFloat {
        guard let raw = styleProperty("stroke-width", in: tag) ?? extractAttribute("stroke-width", in: tag) else { return 0 }
        let cleaned = raw.lowercased()
            .replacingOccurrences(of: "px", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CGFloat(Double(cleaned) ?? 0)
    }
    
    private static func parseHexColor(_ hex: String) -> UIColor? {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        if cleanHex.count == 3 {
            cleanHex = cleanHex.map { "\($0)\($0)" }.joined()
        }
        guard cleanHex.count == 6 else { return nil }
        var rgbValue: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&rgbValue)
        return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Native SVG Rendering

extension CommentBubbleSVGRecognizer {
    
    static func draw(
        svg: CommentBubbleSVG,
        pointSize: CGFloat,
        themeTextColor: UIColor,
        overallScale: CGFloat = 1,
        textScaleRatio: CGFloat? = nil
    ) -> UIImage {
        let defaultHeight = max(12, pointSize * 0.96)
        let targetHeight = max(8, defaultHeight * min(max(overallScale, 0.5), 2.0))
        
        let vW = svg.viewBox.size.width > 0 ? svg.viewBox.size.width : svg.width
        let vH = svg.viewBox.size.height > 0 ? svg.viewBox.size.height : svg.height
        
        let ratio = vW > 0 ? vW / vH : 1.25
        let targetWidth = targetHeight * ratio
        
        let leadingGap: CGFloat = 0
        let canvasSize = CGSize(width: leadingGap + targetWidth, height: targetHeight)
        
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        
        let rendered = renderer.image { rendererContext in
            let context = rendererContext.cgContext

            context.saveGState()
            context.translateBy(x: leadingGap, y: 0)

            let scaleX = targetWidth / vW
            let scaleY = targetHeight / vH
            context.scaleBy(x: scaleX, y: scaleY)
            context.translateBy(x: -svg.viewBox.origin.x, y: -svg.viewBox.origin.y)

            for element in svg.elements {
                // Apply the element's <g> transform within the viewBox→canvas CTM so the
                // shape lands where the SVG author intended (rotate/scale/translate).
                context.saveGState()
                switch element {
                case .rect(let x, let y, let w, let h, let rx, let ry, let stroke, let strokeWidth, let fill, let transform):
                    context.concatenate(transform)
                    let rect = CGRect(x: x, y: y, width: w, height: h)
                    let path = UIBezierPath(roundedRect: rect, byRoundingCorners: .allCorners, cornerRadii: CGSize(width: rx, height: ry))

                    if let fill {
                        fill.setFill()
                        path.fill()
                    }
                    if let stroke {
                        stroke.setStroke()
                        path.lineWidth = strokeWidth ?? 1.0
                        path.lineJoinStyle = .round
                        path.stroke()
                    }

                case .path(let d, let stroke, let strokeWidth, let fill, let transform):
                    context.concatenate(transform)
                    if d.isEmpty {
                        let rect = CGRect(x: svg.viewBox.minX, y: svg.viewBox.minY, width: svg.viewBox.width, height: svg.viewBox.height)
                        let radius = min(svg.viewBox.width, svg.viewBox.height) / 2
                        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
                        if let fill {
                            fill.setFill()
                            path.fill()
                        }
                        if let stroke {
                            stroke.setStroke()
                            path.lineWidth = strokeWidth ?? 1.0
                            path.lineJoinStyle = .round
                            path.stroke()
                        }
                    } else {
                        let path = SVGPathParser.parse(d: d)
                        if let fill {
                            fill.setFill()
                            path.fill()
                        }
                        if let stroke {
                            stroke.setStroke()
                            path.lineWidth = strokeWidth ?? 1.0
                            path.lineJoinStyle = .round
                            path.stroke()
                        }
                    }

                case .image(let data, let rect, let transform):
                    context.concatenate(transform)
                    UIImage(data: data)?.draw(in: rect)

                case .text:
                    // Text is drawn in a second pass below, in canvas space — see note there.
                    break
                }
                context.restoreGState()
            }
            context.restoreGState()

            // Text pass — MUST run after the viewBox→canvas CTM above is popped.
            // The count digit is positioned and sized in canvas points (canvasX/Y,
            // canvasFontSize). If it were drawn inside the viewBox CTM it would be
            // scaled a SECOND time by scaleX/scaleY, shrinking it to near-zero for
            // large-viewBox bubbles (墨圈 216×200, 光遇 style0 1224×1224, style3 88×76)
            // → the number vanished. Drawing here, in identity/canvas space, fixes that.
            for element in svg.elements {
                guard case let .text(text, x, y, fontSize, fontWeight, anchor, color, transform) = element else { continue }
                // The <g> transform maps the anchor point; glyphs themselves stay upright.
                let vbPos = CGPoint(x: x, y: y).applying(transform)
                let vbOrg = svg.viewBox.origin
                let canvasX = (vbPos.x - vbOrg.x) * scaleX + leadingGap
                let canvasY = (vbPos.y - vbOrg.y) * scaleY

                let sourceFontSize = max(6, min(fontSize * scaleY, targetHeight * 0.5))
                let canvasFontSize: CGFloat
                if let textScaleRatio {
                    let boundedTextScale = min(max(textScaleRatio, 0.2), 0.8)
                    canvasFontSize = max(6, min(targetHeight * boundedTextScale, targetHeight * 0.8))
                } else {
                    canvasFontSize = sourceFontSize
                }
                let textColor = color ?? themeTextColor
                let isSVGBold = (fontWeight?.lowercased().contains("bold") ?? false)
                    || (Int((fontWeight ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 600
                let isBold = isSVGBold || GlobalSettings.shared.readerFontBold
                let font = UserReaderFontResolver.bodyFont(size: canvasFontSize, isBold: isBold)
                let textAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor
                ]
                let textSize = (text as NSString).size(withAttributes: textAttrs)

                var drawX = canvasX
                if anchor?.lowercased() == "middle" {
                    drawX = canvasX - textSize.width / 2
                } else if anchor?.lowercased() == "end" {
                    drawX = canvasX - textSize.width
                }
                let drawY = canvasY - font.ascender

                (text as NSString).draw(at: CGPoint(x: drawX, y: drawY), withAttributes: textAttrs)
            }
        }

        // Crop the baked-in viewBox / canvas padding (起点 fills it, but 企点·光遇·番茄
        // leave large transparent margins) so the bubble sits flush against the paragraph
        // text and starts at the left margin when it wraps to a new line.
        let trimmed = rendered.trimmingTransparentPixels() ?? rendered
        diag("draw:vb=\(Int(svg.viewBox.width))x\(Int(svg.viewBox.height))", context: [
            "canvasPt": "\(Int(canvasSize.width))x\(Int(canvasSize.height))",
            "trimmedPt": String(format: "%.0fx%.0f", trimmed.size.width, trimmed.size.height),
            "hasTransform": svg.elements.contains { !$0.transform.isIdentity },
            "elements": svg.elements.count
        ])
        return trimmed
    }
}

// MARK: - Path Parsing

struct SVGPathParser {
    
    enum Token {
        case command(Character)
        case number(CGFloat)
    }
    
    static func parse(d: String) -> UIBezierPath {
        let path = UIBezierPath()
        let tokens = tokenize(d)
        var index = 0
        
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero
        var controlPoint = CGPoint.zero
        
        while index < tokens.count {
            guard case .command(let cmd) = tokens[index] else {
                index += 1
                continue
            }
            index += 1
            
            var args: [CGFloat] = []
            while index < tokens.count, case .number(let val) = tokens[index] {
                args.append(val)
                index += 1
            }
            
            execute(command: cmd, args: args, path: path, currentPoint: &currentPoint, subpathStart: &subpathStart, controlPoint: &controlPoint)
        }
        return path
    }
    
    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let pattern = #"([MmLlHhVvCcSsQqTtAazZ])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = d as NSString
        let matches = regex.matches(in: d, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            if let cmdRange = Range(match.range(at: 1), in: d), !cmdRange.isEmpty {
                if let char = d[cmdRange].first {
                    tokens.append(.command(char))
                }
            } else if let numRange = Range(match.range(at: 2), in: d), !numRange.isEmpty {
                if let val = Double(d[numRange]) {
                    tokens.append(.number(CGFloat(val)))
                }
            }
        }
        return tokens
    }
    
    private static func execute(
        command: Character,
        args: [CGFloat],
        path: UIBezierPath,
        currentPoint: inout CGPoint,
        subpathStart: inout CGPoint,
        controlPoint: inout CGPoint
    ) {
        var argIdx = 0
        var cmd = command
        
        let getNextArgs: (Int) -> [CGFloat]? = { count in
            guard argIdx + count <= args.count else { return nil }
            let slice = args[argIdx..<(argIdx + count)]
            argIdx += count
            return Array(slice)
        }
        
        while true {
            switch cmd {
            case "M", "m":
                guard let xy = getNextArgs(2) else { return }
                let target = cmd == "M" ? CGPoint(x: xy[0], y: xy[1]) : CGPoint(x: currentPoint.x + xy[0], y: currentPoint.y + xy[1])
                path.move(to: target)
                currentPoint = target
                subpathStart = target
                controlPoint = target
                cmd = cmd == "M" ? "L" : "l"
                
            case "L", "l":
                guard let xy = getNextArgs(2) else { return }
                let target = cmd == "L" ? CGPoint(x: xy[0], y: xy[1]) : CGPoint(x: currentPoint.x + xy[0], y: currentPoint.y + xy[1])
                path.addLine(to: target)
                currentPoint = target
                controlPoint = target
                
            case "H", "h":
                guard let xVal = getNextArgs(1) else { return }
                let target = cmd == "H" ? CGPoint(x: xVal[0], y: currentPoint.y) : CGPoint(x: currentPoint.x + xVal[0], y: currentPoint.y)
                path.addLine(to: target)
                currentPoint = target
                controlPoint = target
                
            case "V", "v":
                guard let yVal = getNextArgs(1) else { return }
                let target = cmd == "V" ? CGPoint(x: currentPoint.x, y: yVal[0]) : CGPoint(x: currentPoint.x, y: currentPoint.y + yVal[0])
                path.addLine(to: target)
                currentPoint = target
                controlPoint = target
                
            case "Q", "q":
                guard let qArgs = getNextArgs(4) else { return }
                let cp = cmd == "Q" ? CGPoint(x: qArgs[0], y: qArgs[1]) : CGPoint(x: currentPoint.x + qArgs[0], y: currentPoint.y + qArgs[1])
                let target = cmd == "Q" ? CGPoint(x: qArgs[2], y: qArgs[3]) : CGPoint(x: currentPoint.x + qArgs[2], y: currentPoint.y + qArgs[3])
                path.addQuadCurve(to: target, controlPoint: cp)
                controlPoint = cp
                currentPoint = target
                
            case "T", "t":
                guard let xy = getNextArgs(2) else { return }
                let cp = CGPoint(x: 2 * currentPoint.x - controlPoint.x, y: 2 * currentPoint.y - controlPoint.y)
                let target = cmd == "T" ? CGPoint(x: xy[0], y: xy[1]) : CGPoint(x: currentPoint.x + xy[0], y: currentPoint.y + xy[1])
                path.addQuadCurve(to: target, controlPoint: cp)
                controlPoint = cp
                currentPoint = target
                
            case "C", "c":
                guard let cArgs = getNextArgs(6) else { return }
                let cp1 = cmd == "C" ? CGPoint(x: cArgs[0], y: cArgs[1]) : CGPoint(x: currentPoint.x + cArgs[0], y: currentPoint.y + cArgs[1])
                let cp2 = cmd == "C" ? CGPoint(x: cArgs[2], y: cArgs[3]) : CGPoint(x: currentPoint.x + cArgs[2], y: currentPoint.y + cArgs[3])
                let target = cmd == "C" ? CGPoint(x: cArgs[4], y: cArgs[5]) : CGPoint(x: currentPoint.x + cArgs[4], y: currentPoint.y + cArgs[5])
                path.addCurve(to: target, controlPoint1: cp1, controlPoint2: cp2)
                controlPoint = cp2
                currentPoint = target
                
            case "S", "s":
                guard let sArgs = getNextArgs(4) else { return }
                let cp1 = CGPoint(x: 2 * currentPoint.x - controlPoint.x, y: 2 * currentPoint.y - controlPoint.y)
                let cp2 = cmd == "S" ? CGPoint(x: sArgs[0], y: sArgs[1]) : CGPoint(x: currentPoint.x + sArgs[0], y: currentPoint.y + sArgs[1])
                let target = cmd == "S" ? CGPoint(x: sArgs[2], y: sArgs[3]) : CGPoint(x: currentPoint.x + sArgs[2], y: currentPoint.y + sArgs[3])
                path.addCurve(to: target, controlPoint1: cp1, controlPoint2: cp2)
                controlPoint = cp2
                currentPoint = target
                
            case "A", "a":
                guard let aArgs = getNextArgs(7) else { return }
                let rx = abs(aArgs[0])
                let ry = abs(aArgs[1])
                let xAxisRotation = aArgs[2] * .pi / 180.0
                let largeArcFlag = aArgs[3] != 0
                let sweepFlag = aArgs[4] != 0
                let target = cmd == "A"
                    ? CGPoint(x: aArgs[5], y: aArgs[6])
                    : CGPoint(x: currentPoint.x + aArgs[5], y: currentPoint.y + aArgs[6])

                if rx <= 0 || ry <= 0 || currentPoint == target {
                    path.addLine(to: target)
                } else {
                    addArc(to: path, from: currentPoint, to: target,
                           rx: rx, ry: ry,
                           xAxisRotation: xAxisRotation,
                           largeArc: largeArcFlag, sweep: sweepFlag)
                }
                currentPoint = target
                controlPoint = target
                
            case "Z", "z":
                path.close()
                currentPoint = subpathStart
                controlPoint = subpathStart
                return
                
            default:
                return
            }
            
            if argIdx >= args.count {
                return
            }
        }
    }

    /// SVG arc (elliptical) → cubic bezier approximation.
    /// Uses the endpoint → center parameterization from SVG spec and splits
    /// arcs into ≤90° segments, each approximated by a cubic bezier.
    private static func addArc(
        to path: UIBezierPath,
        from p1: CGPoint, to p2: CGPoint,
        rx: CGFloat, ry: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        let cosA = cos(xAxisRotation), sinA = sin(xAxisRotation)
        let dx = (p1.x - p2.x) / 2.0, dy = (p1.y - p2.y) / 2.0
        let x1p = cosA * dx + sinA * dy
        let y1p = -sinA * dx + cosA * dy

        var rxSq = rx * rx, rySq = ry * ry
        let x1pSq = x1p * x1p, y1pSq = y1p * y1p

        var arx = rx, ary = ry
        let radiiCheck = x1pSq / rxSq + y1pSq / rySq
        if radiiCheck > 1.0 {
            let s = sqrt(radiiCheck)
            arx *= s; ary *= s
            rxSq = arx * arx; rySq = ary * ary
        }

        let sign: CGFloat = (largeArc != sweep) ? 1.0 : -1.0
        let denom = rxSq * y1pSq + rySq * x1pSq
        let cNumerator = rxSq * rySq - denom
        let factor = sign * sqrt(max(0, cNumerator / denom))
        let cxp = factor * arx * y1p / ary
        let cyp = factor * -ary * x1p / arx

        let cx = cosA * cxp - sinA * cyp + (p1.x + p2.x) / 2.0
        let cy = sinA * cxp + cosA * cyp + (p1.y + p2.y) / 2.0

        let ux = (x1p - cxp) / arx, uy = (y1p - cyp) / ary
        let vx = (-x1p - cxp) / arx, vy = (-y1p - cyp) / ary

        let startAngle = atan2(uy, ux)
        // Sweep direction follows the W3C spec sign: sign(ux·vy − uy·vx). The cross-product
        // term was previously negated, which flipped every sweep=1 corner into a wrong-way
        // 270° arc → mangled rounded-rect bubbles (光遇 style1/style2 use A/a corners).
        var deltaAngle = atan2(ux * vy - uy * vx, ux * vx + uy * vy)

        if !sweep && deltaAngle >  0 { deltaAngle -= 2 * .pi }
        if  sweep && deltaAngle <  0 { deltaAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaAngle) / (.pi / 2))))
        let segAngle = deltaAngle / CGFloat(segments)

        var theta1 = startAngle
        for _ in 0..<segments {
            let theta2 = theta1 + segAngle
            // Cubic-bezier control-handle length for a circular arc segment (≤90° here):
            // k = 4/3·tan(Δ/4). The previous sqrt-form used tan(Δ/4) where it needed
            // tan(Δ/2), undershooting the handle (~0.37 vs 0.55 at 90°) → flattened corners.
            let alpha = (4.0 / 3.0) * tan((theta2 - theta1) / 4.0)

            let c1x = arx * (cos(theta1) - alpha * sin(theta1))
            let c1y = ary * (sin(theta1) + alpha * cos(theta1))
            let c2x = arx * (cos(theta2) + alpha * sin(theta2))
            let c2y = ary * (sin(theta2) - alpha * cos(theta2))
            let ex  = arx * cos(theta2)
            let ey  = ary * sin(theta2)

            let rot = CGAffineTransform(a: cosA, b: sinA, c: -sinA, d: cosA, tx: cx, ty: cy)
            let p1t = CGPoint(x: c1x, y: c1y).applying(rot)
            let p2t = CGPoint(x: c2x, y: c2y).applying(rot)
            let pe  = CGPoint(x: ex, y: ey).applying(rot)

            path.addCurve(to: pe, controlPoint1: p1t, controlPoint2: p2t)
            theta1 = theta2
        }
    }
}

extension UIImage {
    func trimmingTransparentPixels() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        
        let width = cgImage.width
        let height = cgImage.height
        
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return nil }
        
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let alpha = ptr[(y * width + x) * 4 + 3]
                if alpha > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        
        guard maxX >= minX && maxY >= minY else {
            return self
        }
        
        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        
        guard let croppedCgImage = cgImage.cropping(to: cropRect) else {
            return self
        }
        
        return UIImage(cgImage: croppedCgImage, scale: self.scale, orientation: self.imageOrientation)
    }
}
