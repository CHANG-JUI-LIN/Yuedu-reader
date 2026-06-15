import UIKit

struct CommentBubbleSVG {
    let viewBox: CGRect
    let width: CGFloat
    let height: CGFloat
    
    enum Element {
        case path(d: String, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case text(text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, fontWeight: String?, anchor: String?, color: UIColor?, transform: CGAffineTransform)
    }
    
    let elements: [Element]
}

extension CommentBubbleSVG.Element {
    /// The composed `<g>` transform attached to this element (identity when ungrouped).
    var transform: CGAffineTransform {
        switch self {
        case .path(_, _, _, _, let t): return t
        case .rect(_, _, _, _, _, _, _, _, _, let t): return t
        case .text(_, _, _, _, _, _, _, let t): return t
        }
    }
}

struct CommentBubbleSVGRecognizer {

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
        guard cleaned.count < 8000 else {
            diag("reject:too-long", context: ["len": cleaned.count])
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
                guard let d = extractAttribute("d", in: tag) else { continue }
                let stroke = parseColor(extractAttribute("stroke", in: tag))
                let strokeWidth = parseDouble(extractAttribute("stroke-width", in: tag))
                let fill = parseColor(extractAttribute("fill", in: tag))
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                elements.append(.path(d: d, strokeColor: stroke, strokeWidth: strokeWidth > 0 ? strokeWidth : nil, fillColor: fill, transform: transform))
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
                let x = parseDouble(extractAttribute("x", in: tag))
                let y = parseDouble(extractAttribute("y", in: tag))
                let w = parseDouble(extractAttribute("width", in: tag))
                let h = parseDouble(extractAttribute("height", in: tag))
                let stroke = parseColor(extractAttribute("stroke", in: tag))
                let strokeWidth = parseDouble(extractAttribute("stroke-width", in: tag))
                let fill = parseColor(extractAttribute("fill", in: tag))
                let transform = composedTransform(at: match.range.location, groups: groupSpans)
                elements.append(.rect(x: x, y: y, width: w, height: h, rx: rxVal, ry: ryVal, strokeColor: stroke, strokeWidth: strokeWidth > 0 ? strokeWidth : nil, fillColor: fill, transform: transform))
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
                
                let text = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Validate count format: numbers optionally followed by + (e.g., 99+)
                let countRegex = try? NSRegularExpression(pattern: #"^[0-9]+[+]?$"#)
                let countNs = text as NSString
                if let countRegex, countRegex.firstMatch(in: text, range: NSRange(location: 0, length: countNs.length)) != nil {
                    let x = parseDouble(extractAttribute("x", in: tag))
                    let y = parseDouble(extractAttribute("y", in: tag))
                    let fontSize = parseDouble(extractAttribute("font-size", in: tag))
                    let fontWeight = extractAttribute("font-weight", in: tag)
                    let anchor = extractAttribute("text-anchor", in: tag)
                    let color = parseColor(extractAttribute("fill", in: tag))
                    let transform = composedTransform(at: tagRange.location, groups: groupSpans)

                    elements.append(.text(text: text, x: x, y: y, fontSize: fontSize > 0 ? fontSize : 12.0, fontWeight: fontWeight, anchor: anchor, color: color, transform: transform))
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
    
    private static func parseDouble(_ val: String?) -> CGFloat {
        guard let val else { return 0 }
        let clean = val.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return parseHexColor(clean)
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
    
    static func draw(svg: CommentBubbleSVG, pointSize: CGFloat, themeTextColor: UIColor) -> UIImage {
        let targetHeight = max(12, pointSize * 0.96)
        
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

                case .text(let text, let x, let y, let fontSize, let fontWeight, let anchor, let color, let transform):
                    context.concatenate(transform)
                    let textColor = color ?? themeTextColor
                    let isSVGBold = fontWeight?.lowercased().contains("bold") ?? false || fontWeight == "600"
                    let isBold = isSVGBold || GlobalSettings.shared.readerFontBold
                    let font = UserReaderFontResolver.bodyFont(size: fontSize, isBold: isBold)
                    let textAttrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: textColor
                    ]

                    let textSize = (text as NSString).size(withAttributes: textAttrs)

                    var textX = x
                    if anchor?.lowercased() == "middle" {
                        textX = x - textSize.width / 2
                    } else if anchor?.lowercased() == "end" {
                        textX = x - textSize.width
                    }

                    // 使用 SVG 给定的 y 坐标作为文本基线绘制（向上减去 font.ascender）
                    let textY = y - font.ascender

                    (text as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: textAttrs)
                }
                context.restoreGState()
            }
            context.restoreGState()
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
                let target = cmd == "A" ? CGPoint(x: aArgs[5], y: aArgs[6]) : CGPoint(x: currentPoint.x + aArgs[5], y: currentPoint.y + aArgs[6])
                path.addLine(to: target)
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
