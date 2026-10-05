import Darwin
import ImageIO
import UIKit

struct CommentBubbleSVG {
    let viewBox: CGRect
    let width: CGFloat
    let height: CGFloat
    
    enum Element {
        case path(d: String, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat, ry: CGFloat, strokeColor: UIColor?, strokeWidth: CGFloat?, fillColor: UIColor?, transform: CGAffineTransform)
        case image(data: Data, rect: CGRect, transform: CGAffineTransform)
        case text(text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, fontFamily: String?, fontWeight: String?, anchor: String?, color: UIColor?, transform: CGAffineTransform)
    }
    
    let elements: [Element]
    /// `preserveAspectRatio`: how the viewBox sits in the `width`×`height` the SVG declares.
    var viewBoxFit = ViewBoxFit()

    /// SVG's default is `xMidYMid meet`: the whole viewBox, scaled uniformly, centred.
    struct ViewBoxFit {
        /// `none`: stretched over the declared size on each axis.
        var stretches = false
        /// `slice`: scaled to cover the declared size instead of fitting inside it.
        var slices = false
        /// Where the leftover space goes, 0 (min) … 1 (max) on each axis.
        var align = CGPoint(x: 0.5, y: 0.5)
    }

    var displayText: String? {
        for element in elements {
            if case .text(let text, _, _, _, _, _, _, _, _) = element {
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
                guard case let .text(_, x, y, fontSize, fontFamily, fontWeight, anchor, color, transform) = element else {
                    return element
                }
                return .text(
                    text: text,
                    x: x,
                    y: y,
                    fontSize: fontSize,
                    fontFamily: fontFamily,
                    fontWeight: fontWeight,
                    anchor: anchor,
                    color: color,
                    transform: transform
                )
            },
            viewBoxFit: viewBoxFit
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
        case .text(_, _, _, _, _, _, _, _, let t): return t
        }
    }
}

struct CommentBubbleSVGRecognizer {
    /// Bound for the *sniffing* path — deciding whether an unknown image from a book
    /// source is a comment bubble. Kept tight: source SVGs arrive by the hundred per
    /// chapter and a bubble authored for this purpose is small.
    static let maximumRecognizableSVGByteCount = 32 * 1024

    /// Bound for a template the user explicitly chose as their bubble. String length is a
    /// poor proxy for cost when the artwork is an embedded raster: 侠客.svg is 88KB of text
    /// for a *single* `<image>` holding one 270×360 PNG, so the 32KB cap above rejected it
    /// while there was exactly one element to parse. What actually costs us is the element
    /// count and the pixels behind an embedded raster, so those are bounded directly.
    static let maximumUserTemplateSVGByteCount = 1_024 * 1_024

    /// Parsed elements in one template. Well past any real bubble (the most detailed one
    /// seen is a handful of paths), while still bounding a pathological input.
    static let maximumUserTemplateElementCount = 64

    /// Pixels behind an embedded `data:` raster. Bounds decode memory so a small
    /// highly-compressed PNG cannot expand into hundreds of megabytes.
    static let maximumEmbeddedRasterPixelCount = 16_000_000

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

    // MARK: - Bubble render caches
    //
    // 段評-heavy chapters carry hundreds of paragraph bubbles, and the counts repeat
    // heavily ("0", "1", "99+"…). Producing a bubble is a pure function of (svg, size,
    // theme, settings), yet nothing memoized it: every paragraph re-ran ~15 regex to
    // parse the SVG and a full @3× draw + per-pixel transparent-trim. ReviewBadgeRenderer
    // (the <comment>-tag bubble) has always cached by count; these give the SVG-bubble
    // path the same treatment, collapsing hundreds of redraws into one per distinct
    // (count, style, theme, size). Keys carry the full determinant so a hit is never the
    // wrong image, and an all-unique chapter is simply no worse than before this cache.
    private final class RecognizedBox { let svg: CommentBubbleSVG?; init(_ svg: CommentBubbleSVG?) { self.svg = svg } }
    private static let recognizeCache: NSCache<NSString, RecognizedBox> = {
        let cache = NSCache<NSString, RecognizedBox>(); cache.countLimit = 256; return cache
    }()
    private static let bubbleImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 512; return cache
    }()

    // Cache-hit telemetry so the win is visible on device: filter Console for
    // "⟐ bubble cache" — a 段評 chapter should show draws ≪ hits once counts repeat.
    private static let bubbleStatLock = NSLock()
    nonisolated(unsafe) private static var bubbleHitCount = 0
    nonisolated(unsafe) private static var bubbleDrawCount = 0
    private static func noteBubbleCache(hit: Bool) {
        bubbleStatLock.lock()
        if hit { bubbleHitCount += 1 } else { bubbleDrawCount += 1 }
        let hits = bubbleHitCount, draws = bubbleDrawCount
        let shouldLog = (hits + draws) % 256 == 0
        bubbleStatLock.unlock()
        if shouldLog {
            AppLogger.render("⟐ bubble cache", context: ["hits": hits, "draws": draws])
        }
    }

    /// Returns a stable template identity and the count currently embedded in the SVG.
    ///
    /// 起點把同一個氣泡外形重複內嵌在每一段文字中，唯一變化通常只有 `<text>` 裡的數字。
    /// 直接用完整 data URI 當 key 會讓每個數字都重新跑整份 SVG parser。把數字換成
    /// `$displayText` 後，解析結果可以跨段落共享；實際數字仍在回傳前換回去，所以外觀和
    /// 點擊資料完全不變。
    private static func normalizedTemplateInput(_ svg: String) -> (template: String, displayText: String?) {
        let textPattern = #"<text\b[^>]*>(.*?)</text>"#
        guard let regex = try? NSRegularExpression(
            pattern: textPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return (svg, nil)
        }

        let ns = svg as NSString
        guard let match = regex.firstMatch(
            in: svg,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges > 1 else {
            return (svg, nil)
        }

        let rawText = ns.substring(with: match.range(at: 1))
        let displayText = rawText
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isCount = (try? NSRegularExpression(pattern: #"^[0-9]+[+]?$"#))
            .map {
                $0.firstMatch(
                    in: displayText,
                    range: NSRange(location: 0, length: (displayText as NSString).length)
                ) != nil
            } ?? false
        guard isCount else {
            return (svg, displayText.isEmpty ? nil : displayText)
        }

        let normalized = ns.replacingCharacters(
            in: match.range(at: 1),
            with: "$displayText"
        )
        return (normalized, displayText)
    }

    /// Which face draws a bubble's count. legado draws a source's SVG with the faces it
    /// names (AndroidSVG); Sigma draws a bubble package — the reader's own templates — with
    /// the reading font.
    enum BubbleTextFace: String, Sendable {
        case declared
        case reader
    }

    /// Why an SVG is being parsed. The two callers need different strictness, and
    /// collapsing them into one gate is what kept raster bubbles out:
    ///
    /// - `.sourceSniff` asks "is this unknown image from a book source a comment bubble?".
    ///   There, *exactly one count-formatted `<text>`* is the only thing separating a real
    ///   bubble from an arbitrary source illustration, so it must stay strict — relaxing it
    ///   would make every `<image>`-only source picture render as a bubble.
    /// - `.userTemplate` parses an SVG the user picked as their bubble in 段評氣泡 settings.
    ///   Nothing needs sniffing there, so artwork-only templates (no `<text>` at all — the
    ///   shape QiReader exports with `showLabel:false`) are accepted and drawn without a
    ///   count, which is what their author intended.
    enum RecognitionMode: String, Sendable {
        case sourceSniff
        case userTemplate
    }

    /// Length-prefixed so a hash clash also needs equal length, and mode-prefixed so a
    /// strict rejection is never served to the permissive caller (or the reverse). The
    /// identity is the normalized SVG template, not the count-baked source string.
    private static func recognizeCacheKey(normalizedSVG: String, mode: RecognitionMode) -> NSString {
        "\(mode.rawValue)#\(normalizedSVG.utf8.count)#\(normalizedSVG.hashValue)" as NSString
    }

    /// Checks if the given image source or SVG string represents a recognizable simple comment bubble.
    /// If so, decodes and parses it into a CommentBubbleSVG representation. Memoized: a 段評
    /// chapter calls this 2–3× per bubble (gate + resolve + template) over hundreds of paragraphs,
    /// and the parse is pure, so the first occurrence of each distinct SVG pays it and the rest hit.
    static func recognize(src: String, svgContent: String?) -> CommentBubbleSVG? {
        recognize(src: src, svgContent: svgContent, mode: .sourceSniff)
    }

    /// Whether a chapter's HTML carries a picture this recognizer takes for a comment
    /// bubble: the `data:` SVGs that `OnlineImageLoader` and the renderer send here, and
    /// that 段評氣泡's settings then restyle. A bubble whose tap handler this app cannot
    /// run — or that has none — gets no review link, yet is drawn and restyled like any
    /// other, so the reader asks this before hiding those settings.
    static func containsRecognizedBubble(inChapterHTML html: String) -> Bool {
        guard html.range(of: "data:image/svg+xml", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                  pattern: #"data:image/svg\+xml[^"'\s>)]*"#,
                  options: [.caseInsensitive]
              ) else { return false }
        let ns = html as NSString
        var found = false
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            if recognize(src: ns.substring(with: match.range), svgContent: nil) != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Parses an SVG the user chose as their own bubble template. Permissive by design —
    /// see `RecognitionMode.userTemplate`.
    static func recognizeUserTemplate(_ svg: String) -> CommentBubbleSVG? {
        recognize(src: "", svgContent: svg, mode: .userTemplate)
    }

    static func recognize(
        src: String,
        svgContent: String?,
        mode: RecognitionMode
    ) -> CommentBubbleSVG? {
        ReaderDocumentTrace.measuringSync("bubbleRecognize") {
            recognizeImpl(src: src, svgContent: svgContent, mode: mode)
        }
    }

    private static func recognizeImpl(
        src: String,
        svgContent: String?,
        mode: RecognitionMode
    ) -> CommentBubbleSVG? {
        guard let rawSVG = getSVGString(src: src, svgContent: svgContent) else {
            diag("reject:no-svg", context: ["srcPrefix": String(src.prefix(48))])
            return nil
        }

        let cleaned = rawSVG.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = normalizedTemplateInput(cleaned)
        let cacheKey = recognizeCacheKey(normalizedSVG: input.template, mode: mode)
        if let box = recognizeCache.object(forKey: cacheKey) {
            return box.svg?.replacingDisplayText(with: input.displayText ?? box.svg?.displayText ?? "")
        }

        let result = recognizeUncached(svg: input.template, mode: mode)
        recognizeCache.setObject(RecognizedBox(result), forKey: cacheKey)
        return result?.replacingDisplayText(with: input.displayText ?? result?.displayText ?? "")
    }

    private static func recognizeUncached(
        svg cleaned: String,
        mode: RecognitionMode
    ) -> CommentBubbleSVG? {
        // Bound the parse, but generously: iconfont 段評 bubbles (企点/光遇) embed a full
        // outline <path> (~1.4–1.9k chars). The structural checks below — a count-formatted
        // <text> plus a shape — are what actually gate non-bubble SVGs, so a tight length
        // cap only mis-rejected real bubbles (光遇's is ~1916 chars).
        let byteLimit = mode == .userTemplate
            ? maximumUserTemplateSVGByteCount
            : maximumRecognizableSVGByteCount
        let byteCount = cleaned.utf8.count
        guard byteCount <= byteLimit else {
            diag("reject:too-long", context: ["bytes": byteCount, "limit": byteLimit, "mode": mode.rawValue])
            return nil
        }

        // Exactly one text element when sniffing an unknown source image — that is the
        // discriminator. A user-chosen template may legitimately carry none (artwork-only
        // bubble, count not drawn), but never more than one replaceable count.
        let textOpen = countOccurrences(of: "<text", in: cleaned)
        let textClose = countOccurrences(of: "</text>", in: cleaned)
        let textCountIsAcceptable = mode == .userTemplate
            ? (textOpen == textClose && textOpen <= 1)
            : (textOpen == 1 && textClose == 1)
        guard textCountIsAcceptable else {
            diag("reject:text-count",
                 context: ["open": textOpen, "close": textClose, "len": cleaned.count, "mode": mode.rawValue])
            return nil
        }

        guard let parsed = parseSVG(cleaned) else {
            diag("reject:parse-fail", context: ["len": cleaned.count])
            return nil
        }
        // A template with nothing to draw is not a bubble.
        guard !parsed.elements.isEmpty else {
            diag("reject:no-elements", context: ["len": cleaned.count, "mode": mode.rawValue])
            return nil
        }
        // Sniffing additionally demands the classic bubble shape — a count text *and* a
        // shape to sit in. That pairing is what tells a bubble apart from an arbitrary
        // source illustration, so it stays exactly as strict as it has always been. A
        // user-chosen template needs no such proof: they already said what it is.
        if mode == .sourceSniff {
            let hasText = parsed.elements.contains { if case .text = $0 { return true }; return false }
            let hasShape = parsed.elements.contains { if case .text = $0 { return false }; return true }
            guard hasText, hasShape else {
                diag("reject:not-bubble-shaped",
                     context: ["hasText": hasText, "hasShape": hasShape, "len": cleaned.count])
                return nil
            }
        } else if parsed.elements.count > maximumUserTemplateElementCount {
            diag("reject:too-many-elements",
                 context: ["elements": parsed.elements.count, "limit": maximumUserTemplateElementCount])
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
        themeTextColor: UIColor,
        recognizedBubble: CommentBubbleSVG? = nil,
        sourceTextFace: BubbleTextFace = .declared
    ) -> UIImage? {
        let cacheKey = ReaderDocumentTrace.measuringSync("bubbleKey") {
            bubbleImageCacheKey(
                src: src,
                svgContent: svgContent,
                pointSize: pointSize,
                themeTextColor: themeTextColor,
                displayText: recognizedBubble?.displayText,
                sourceTextFace: sourceTextFace
            )
        }
        if let cached = bubbleImageCache.object(forKey: cacheKey) {
            noteBubbleCache(hit: true)
            return cached
        }
        guard let image = computeResolvedBubbleImage(
            src: src,
            svgContent: svgContent,
            pointSize: pointSize,
            themeTextColor: themeTextColor,
            sourceBubble: recognizedBubble,
            sourceTextFace: sourceTextFace
        ) else { return nil }
        bubbleImageCache.setObject(image, forKey: cacheKey)
        noteBubbleCache(hit: false)
        return image
    }

    /// Renders a `<comment count="…">` marker through the same native SVG pipeline as
    /// source-provided bubble images. A comment tag has no source SVG of its own, so the built-in
    /// template is the neutral source shape when the reader is set to follow source styling; the
    /// selected reader SVG is applied by `computeResolvedBubbleImage` when custom styling is on.
    static func commentBadgeImage(
        count: String,
        pointSize: CGFloat,
        themeTextColor: UIColor
    ) -> UIImage? {
        guard let template = recognize(src: "", svgContent: builtinBubbleSVG) else {
            return nil
        }
        return resolvedBubbleImage(
            src: "",
            svgContent: builtinBubbleSVG,
            pointSize: pointSize,
            themeTextColor: themeTextColor,
            recognizedBubble: template.replacingDisplayText(with: count),
            // The app's own template, not a source's SVG: its count reads in the reading
            // font, as a bubble package's does.
            sourceTextFace: .reader
        )
    }

    /// The full determinant of a drawn bubble: which SVG (the count is baked into it), the
    /// point size, the resolved theme text colour, and every GlobalSettings knob that alters
    /// the draw. Changing any of these mints a new key, so stale settings never surface a
    /// wrong bubble; `L…` folds the selected style's length in to catch in-place SVG edits.
    private static func bubbleImageCacheKey(
        src: String,
        svgContent: String?,
        pointSize: CGFloat,
        themeTextColor: UIColor,
        displayText: String?,
        sourceTextFace: BubbleTextFace
    ) -> NSString {
        let identity = (svgContent?.isEmpty == false) ? svgContent! : src
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        themeTextColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let rgba = String(format: "%.2f-%.2f-%.2f-%.2f", r, g, b, a)
        let s = GlobalSettings.shared
        let sig = [
            s.commentBubbleFollowsSourceSVG ? "F1" : "F0",
            s.commentBubblePresetMode.rawValue,
            s.commentBubbleSelectedCustomStyleID?.uuidString ?? "-",
            s.commentBubbleSelectedCustomStyle.map { "L\($0.svg.utf8.count)" } ?? "-",
            String(format: "%.2f", s.commentBubbleScale),
            sourceTextFace.rawValue,
            s.selectedReaderFontPostScript ?? "sys"
        ].joined(separator: "|")
        let textIdentity = displayText.map { "|T\($0)" } ?? ""
        return "\(identity.utf8.count)#\(identity.hashValue)\(textIdentity)|\(Int(pointSize.rounded()))|\(rgba)|\(sig)" as NSString
    }

    private static func computeResolvedBubbleImage(
        src: String,
        svgContent: String?,
        pointSize: CGFloat,
        themeTextColor: UIColor,
        sourceBubble: CommentBubbleSVG? = nil,
        sourceTextFace: BubbleTextFace
    ) -> UIImage? {
        guard let sourceBubble = sourceBubble ?? recognize(src: src, svgContent: svgContent) else {
            return nil
        }
        let settings = GlobalSettings.shared
        if settings.commentBubbleFollowsSourceSVG {
            return draw(svg: sourceBubble, pointSize: pointSize, themeTextColor: themeTextColor, textFace: sourceTextFace)
        }

        let bubbleText = sourceBubble.displayText ?? "0"
        var templateSource = ReaderDocumentTrace.measuringSync("bubbleTemplateSource") {
            templateSVG(
                for: settings.commentBubblePresetMode,
                customSVG: settings.commentBubbleSelectedCustomStyle?.svg ?? ""
            )
        }
        // bubble.json-imported styles keep a literal `${color}` placeholder in
        // their text fill (`fill="${color}"`). The parser can only resolve real
        // hex/rgb colours, so we substitute the JSON's day/night + normal/emphasis
        // hex into the raw SVG string *before* recognition. Styles authored in
        // the legacy SVG editor (no `${color}` token) are untouched.
        // Only the active template and the two supported replacement tokens affect this
        // operation. A retained custom artwork cannot change a builtin SVG, and lowercasing
        // that artwork on every raster miss repeats work unrelated to the active template.
        if let style = settings.commentBubbleSelectedCustomStyle,
           ReaderDocumentTrace.measuringSync("bubbleColorTemplateCheck", {
               // These replacement tokens are ASCII bytes. Bounded UTF-8 search avoids
               // Unicode normalization/UTF-16 conversion of large base64 image payloads.
               templateSource.withUTF8 { bytes in
                   guard let base = bytes.baseAddress else { return false }
                   return "${color}".withCString { token in
                       memmem(base, bytes.count, token, 8) != nil
                   } || "${Color}".withCString { token in
                       memmem(base, bytes.count, token, 8) != nil
                   }
               }
           }) {
            let hex = style.resolvedColorHex(
                forCount: bubbleText,
                isNight: isNightTheme(themeTextColor: themeTextColor)
            )
            templateSource = materializeColorTemplate(
                templateSource,
                colorHex: hex
            )
        }
        // The user picked this template explicitly, so it is parsed permissively — an
        // artwork-only bubble (no <text>) draws its picture and simply shows no count.
        let template = recognizeUserTemplate(templateSource)
            ?? recognizeUserTemplate(builtinBubbleSVG)

        guard let template else {
            return draw(svg: sourceBubble, pointSize: pointSize, themeTextColor: themeTextColor, textFace: sourceTextFace)
        }
        return draw(
            svg: template.replacingDisplayText(with: bubbleText),
            pointSize: pointSize,
            themeTextColor: themeTextColor,
            overallScale: CGFloat(settings.commentBubbleScale),
            textFace: .reader
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
        let viewBoxFit = parseViewBoxFit(extractAttribute("preserveAspectRatio", in: svgTag))

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
                    let fontFamily = extractAttribute("font-family", in: tag)
                        ?? styleProperty("font-family", in: tag)
                    let fontWeight = extractAttribute("font-weight", in: tag)
                        ?? styleProperty("font-weight", in: tag)
                    let anchor = extractAttribute("text-anchor", in: tag)
                    let elementColor = resolveElementColor(in: tag, inheritedColor: rootColor)
                    let color = resolvePaint("fill", in: tag, inheritedColor: elementColor)
                    let transform = composedTransform(at: tagRange.location, groups: groupSpans)

                    elements.append(.text(text: text, x: x, y: y + dy, fontSize: resolvedFontSize, fontFamily: fontFamily, fontWeight: fontWeight, anchor: anchor, color: color, transform: transform))
                }
            }
        }
        
        return CommentBubbleSVG(
            viewBox: viewBox,
            width: finalWidth,
            height: finalHeight,
            elements: elements,
            viewBoxFit: viewBoxFit
        )
    }
    
    private static func extractAttribute(_ name: String, in tag: String) -> String? {
        // Not `\b`: a hyphen is a word boundary, so `\bopacity` also matched inside
        // `fill-opacity` and `\bwidth` inside `stroke-width`.
        let pattern = #"(?<![\w:-])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#
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
        guard let data, !data.isEmpty, embeddedRasterIsWithinBounds(data) else { return nil }
        return data
    }

    /// Validates an embedded raster from its header only. `UIImage(data:)` used to serve as
    /// the validity check, but it fully decodes: a small, highly-compressed PNG could expand
    /// into hundreds of megabytes before anything looked at its size. CGImageSource reads the
    /// dimensions without materializing pixels.
    private static func embeddedRasterIsWithinBounds(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return false
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumEmbeddedRasterPixelCount else {
            diag("reject:raster-too-large", context: ["w": width, "h": height])
            return false
        }
        return true
    }
    
    /// `preserveAspectRatio="<align> [meet|slice]"`; nil or unreadable is SVG's default.
    private static func parseViewBoxFit(_ value: String?) -> CommentBubbleSVG.ViewBoxFit {
        var fit = CommentBubbleSVG.ViewBoxFit()
        let tokens = (value ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let align = tokens.first else { return fit }
        if align == "none" {
            fit.stretches = true
            return fit
        }
        fit.slices = tokens.dropFirst().first == "slice"
        func fraction(_ token: Substring) -> CGFloat {
            token == "min" ? 0 : (token == "max" ? 1 : 0.5)
        }
        // `xMinYMax` → x "min", y "max".
        if align.count == 8, align.hasPrefix("x"), align.dropFirst(4).hasPrefix("y") {
            fit.align = CGPoint(
                x: fraction(align.dropFirst(1).prefix(3)),
                y: fraction(align.dropFirst(5).prefix(3))
            )
        }
        return fit
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
        if let rgb = cssNamedColors[clean] {
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        return parseHexColor(clean)
    }

    /// The CSS colour keywords, which AndroidSVG takes in any paint as legado draws a
    /// bubble. Bubble packs outline their shapes with `fill="black"` and `fill="white"`;
    /// without the names those shapes drew nothing (猫咪气泡 lost its outline and its box).
    private static let cssNamedColors: [String: UInt32] = {
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff
        beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2
        brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e
        coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff
        darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400
        darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00
        darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b
        darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3
        deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff
        firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc
        ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f
        grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0
        khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd
        lightblue add8e6 lightcoral f08080 lightcyan e0ffff lightgoldenrodyellow fafad2
        lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a
        lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899
        lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6
        magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3
        mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a
        mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa
        mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000
        olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa
        palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5
        peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080
        rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513
        salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0
        skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa
        springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347
        turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00
        yellowgreen 9acd32
        """
        let tokens = table.split(whereSeparator: \.isWhitespace)
        var colors: [String: UInt32] = [:]
        for index in stride(from: 0, to: tokens.count - 1, by: 2) {
            colors[String(tokens[index])] = UInt32(tokens[index + 1], radix: 16)
        }
        return colors
    }()

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
        // The paint's own opacity and the element's `opacity` both fade it, as AndroidSVG
        // composes them; a lone shape's group opacity is its paints' alpha.
        let alpha = opacityValue("\(property)-opacity", in: tag) * opacityValue("opacity", in: tag)
        return alpha < 1 ? base.withAlphaComponent(alpha) : base
    }

    /// An opacity property as a 0…1 factor; 1 when absent or unreadable.
    private static func opacityValue(_ name: String, in tag: String) -> CGFloat {
        guard let raw = styleProperty(name, in: tag) ?? extractAttribute(name, in: tag),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return 1 }
        return CGFloat(min(max(value, 0), 1))
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
        textFace: BubbleTextFace = .declared
    ) -> UIImage {
        let defaultHeight = max(12, pointSize * 0.96)
        let targetHeight = max(8, defaultHeight * min(max(overallScale, 0.5), 2.0))
        
        let vW = svg.viewBox.size.width > 0 ? svg.viewBox.size.width : svg.width
        let vH = svg.viewBox.size.height > 0 ? svg.viewBox.size.height : svg.height

        // The canvas is the size the SVG declares, as AndroidSVG and WebKit draw it, with the
        // viewBox fitted inside it. 起点's bubble declares 200×150 around a 1300×1280 viewBox:
        // drawn at the viewBox's own shape it came out a third larger than in legado.
        let ratio = svg.width > 0 && svg.height > 0 ? svg.width / svg.height : (vW > 0 ? vW / vH : 1.25)
        let targetWidth = targetHeight * ratio
        
        let leadingGap: CGFloat = 0
        let canvasSize = CGSize(width: leadingGap + targetWidth, height: targetHeight)
        
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        
        let rendered = ReaderDocumentTrace.measuringSync("bubbleDraw") {
            renderer.image { rendererContext in
            let context = rendererContext.cgContext

            context.saveGState()

            var scaleX = targetWidth / vW
            var scaleY = targetHeight / vH
            var offsetX: CGFloat = 0
            var offsetY: CGFloat = 0
            if !svg.viewBoxFit.stretches {
                let uniform = svg.viewBoxFit.slices ? max(scaleX, scaleY) : min(scaleX, scaleY)
                scaleX = uniform
                scaleY = uniform
                offsetX = (targetWidth - vW * uniform) * svg.viewBoxFit.align.x
                offsetY = (targetHeight - vH * uniform) * svg.viewBoxFit.align.y
            }
            context.translateBy(x: leadingGap + offsetX, y: offsetY)
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
                guard case let .text(text, x, y, fontSize, fontFamily, fontWeight, anchor, color, transform) = element else { continue }
                // The <g> transform maps the anchor point; glyphs themselves stay upright.
                let vbPos = CGPoint(x: x, y: y).applying(transform)
                let vbOrg = svg.viewBox.origin
                let canvasX = (vbPos.x - vbOrg.x) * scaleX + leadingGap + offsetX
                let canvasY = (vbPos.y - vbOrg.y) * scaleY + offsetY

                // legado (AndroidSVG) draws the count at the size the SVG gives it, scaled with
                // the viewBox like every other element. The 50% clamp and the reader's
                // 數字字號比例 that replaced it set the number against the bubble's height
                // instead, which is how 光遇's and the bubble packs' 99+ outgrew their frames.
                let canvasFontSize = max(1, fontSize * scaleY)
                let textColor = color ?? themeTextColor
                // Weight is the SVG's own; the reader's bold setting widened every count.
                let isBold = isBoldSVGWeight(fontWeight)
                var textAttrs: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]
                let font: UIFont
                switch textFace {
                case .declared:
                    font = declaredFont(family: fontFamily, isBold: isBold, size: canvasFontSize)
                case .reader:
                    font = UserReaderFontResolver.bodyFont(size: canvasFontSize, isBold: isBold)
                    textAttrs.merge(
                        UserReaderFontResolver.syntheticBoldAttributes(for: font, isBoldRequested: isBold)
                    ) { _, new in new }
                }
                textAttrs[.font] = font
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

        }

        // The whole viewBox, margins included, as legado draws it: the SVG's own space
        // around its shape is what keeps the bubble off the paragraph's last character.
        // Cropping it (b1efe83b) pressed every bubble against the text.
        diag("draw:vb=\(Int(svg.viewBox.width))x\(Int(svg.viewBox.height))", context: [
            "canvasPt": "\(Int(canvasSize.width))x\(Int(canvasSize.height))",
            "hasTransform": svg.elements.contains { !$0.transform.isIdentity },
            "elements": svg.elements.count
        ])
        return rendered
    }

    /// `bold`/`bolder`, or a numeric weight of 600 and up.
    private static func isBoldSVGWeight(_ weight: String?) -> Bool {
        guard let weight = weight?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return weight.hasPrefix("bold") || (Int(weight) ?? 0) >= 600
    }

    /// The face an SVG `font-family` list names, as AndroidSVG resolves it for legado: the
    /// first family that exists wins; `sans-serif` and the system aliases are the system
    /// face; with nothing usable named it falls back to serif, AndroidSVG's default.
    private static func declaredFont(family: String?, isBold: Bool, size: CGFloat) -> UIFont {
        let names = (family ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n'\"")) }
            .filter { !$0.isEmpty }
        for name in names {
            switch name.lowercased() {
            case "sans-serif", "-apple-system", "system-ui", "blinkmacsystemfont", "cursive", "fantasy":
                return UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
            case "monospace":
                return UIFont.monospacedSystemFont(ofSize: size, weight: isBold ? .bold : .regular)
            case "serif":
                return installedFont(family: "Times New Roman", isBold: isBold, size: size)
                    ?? UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
            default:
                if let font = installedFont(family: name, isBold: isBold, size: size) {
                    return font
                }
            }
        }
        return installedFont(family: "Times New Roman", isBold: isBold, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
    }

    private static func installedFont(family: String, isBold: Bool, size: CGFloat) -> UIFont? {
        guard let installed = UIFont.familyNames.first(where: {
            $0.caseInsensitiveCompare(family) == .orderedSame
        }) else { return nil }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: installed])
        if isBold, let bold = descriptor.withSymbolicTraits(.traitBold) {
            descriptor = bold
        }
        return UIFont(descriptor: descriptor, size: size)
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
