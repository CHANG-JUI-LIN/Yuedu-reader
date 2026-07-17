import CoreText
import UIKit

final class CoreTextPaginator {
    static func debugVerticalLog(_ message: @autoclosure () -> String, verbose: Bool = false) {
    }

    struct RenderedAttachment {
        struct LinkTarget {
            let href: String
            let rect: CGRect
        }

        let rect: CGRect
        let image: UIImage
        let opacity: CGFloat
        let sourceHref: String?
        let alt: String?
        let linkHref: String?
        let mediaAttachment: EPUBMediaAttachment?
        let originalSize: CGSize
        let linkRegions: [ImageLinkRegion]
        let allowsPreview: Bool

        init(
            rect: CGRect,
            image: UIImage,
            opacity: CGFloat,
            sourceHref: String? = nil,
            alt: String? = nil,
            linkHref: String? = nil,
            mediaAttachment: EPUBMediaAttachment? = nil,
            originalSize: CGSize? = nil,
            linkRegions: [ImageLinkRegion] = [],
            allowsPreview: Bool = true
        ) {
            self.rect = rect
            self.image = image
            self.opacity = opacity
            self.sourceHref = sourceHref
            self.alt = alt
            self.linkHref = linkHref
            self.mediaAttachment = mediaAttachment
            self.originalSize = originalSize ?? image.size
            self.linkRegions = linkRegions
            self.allowsPreview = allowsPreview
        }

        /// Resolves either a whole-image link or a precise embedded link region at a render-space point.
        func linkTarget(at point: CGPoint, hitSlop: CGFloat = 8) -> LinkTarget? {
            if let linkHref, !linkHref.isEmpty,
               rect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) {
                return LinkTarget(href: linkHref, rect: rect)
            }
            guard rect.width > 0, rect.height > 0 else { return nil }
            let targets = linkRegions.map { region in
                LinkTarget(href: region.href, rect: CGRect(
                    x: rect.minX + region.normalizedRect.minX * rect.width,
                    y: rect.minY + region.normalizedRect.minY * rect.height,
                    width: region.normalizedRect.width * rect.width,
                    height: region.normalizedRect.height * rect.height
                ))
            }
            if let exact = targets.first(where: { $0.rect.contains(point) }) {
                return exact
            }
            return targets
                .filter { $0.rect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) }
                .min { lhs, rhs in
                    let lhsX = lhs.rect.midX - point.x
                    let lhsY = lhs.rect.midY - point.y
                    let rhsX = rhs.rect.midX - point.x
                    let rhsY = rhs.rect.midY - point.y
                    return lhsX * lhsX + lhsY * lhsY < rhsX * rhsX + rhsY * rhsY
                }
        }

        func replacingLinkHref(_ href: String) -> RenderedAttachment {
            RenderedAttachment(
                rect: rect,
                image: image,
                opacity: opacity,
                sourceHref: sourceHref,
                alt: alt,
                linkHref: href,
                mediaAttachment: mediaAttachment,
                originalSize: originalSize,
                linkRegions: linkRegions,
                allowsPreview: allowsPreview
            )
        }
    }

    struct RenderedBlockRenderable {
        let rect: CGRect
        let style: HTMLAttributedStringBuilder.BlockRenderStyle
        let attributedText: NSAttributedString?
        /// String ranges whose text is drawn by drawBlockRenderableText (not by CTFrame drawLines).
        /// Non-empty only when attributedText != nil (usesExplicitGeometry = true).
        let sourceRanges: [NSRange]
        let imageAttachment: RenderedAttachment?
    }

    struct RenderedInlineAnnotation {
        /// Drawing rectangle in UIKit coordinates (origin top-left, Y downward).
        let uiRect: CGRect
        let attributedString: NSAttributedString
    }

    enum PageKind {
        case text
        case image
    }

    // MARK: - ChapterLayout

    struct ChapterLayout {
        let spineIndex: Int
        let attributedString: NSAttributedString
        /// Pre-built CTFramesetter; draw(_ rect:) uses it directly without rebuilding
        let framesetter: CTFramesetter
        /// UTF-16 character range per page (total length == attributedString.length)
        let pageRanges: [CFRange]
        /// pageIndex → inline attachments
        let inlineAttachments: [Int: [RenderedAttachment]]
        /// pageIndex → inline annotation placeholders
        let inlineAnnotations: [Int: [RenderedInlineAnnotation]]
        /// pageIndex → block-level attachments / decorative images
        let blockAttachments: [Int: [RenderedAttachment]]
        /// pageIndex → block-level renderables (background / border / decorative images)
        let blockRenderables: [Int: [RenderedBlockRenderable]]
        let pageKinds: [PageKind]
        let pageBackgroundImage: UIImage?
        /// Publication-authored body fill painted beneath its (possibly transparent) background
        /// image. Kept separate so reader theme changes do not erase the authored composition.
        let authoredBackgroundColor: UIColor?
        /// Reader-selected image background. Unlike an authored EPUB body
        /// background, this is a user preference and takes precedence at draw time.
        var readerBackgroundImage: UIImage? = nil
        let anchorOffsets: [String: Int]
        let renderSize: CGSize
        let fontSize: CGFloat
        let backgroundColor: UIColor
        /// Content edge insets used during layout (UIEdgeInsets; CoreText path is already offset accordingly)
        let contentInsets: UIEdgeInsets
        var writingMode: ReaderWritingMode = .horizontal
        /// pageIndex → the CSS-float exclusion rect (CoreText coords) carved out of that page so text wraps
        /// around the float. Empty for the common no-float case. Used to rebuild the notched frame path at
        /// both draw time and attachment extraction so layout matches pagination.
        var pageFloatNotches: [Int: CGRect] = [:]

        /// Updates only text colors without repaginating (color does not affect line wrapping).
        /// Ranges with explicitly CSS-specified foreground colors (marked with cssSpecifiedForegroundColorAttribute) retain their original color.
        /// No theme-wide `.backgroundColor` is applied to runs: CoreText's CTLineDraw / CTFrameDraw
        /// do not paint `.backgroundColor` at all (inline backgrounds here are custom-drawn), and
        /// the page fill alone carries the theme color.
        func withUpdatedColors(
            textColor: UIColor,
            backgroundColor: UIColor,
            dialogueColor: UIColor? = nil,
            dialogueBoxColor: UIColor? = nil
        ) -> ChapterLayout {
            withUpdatedAppearance(
                textColor: textColor,
                backgroundColor: backgroundColor,
                readerBackgroundImage: readerBackgroundImage,
                dialogueColor: dialogueColor,
                dialogueBoxColor: dialogueBoxColor
            )
        }

        /// Updates reader appearance without re-paginating. A user-selected
        /// background image is kept independently from authored CSS backgrounds so
        /// clearing the reader preference restores the publication's own artwork.
        func withUpdatedAppearance(
            textColor: UIColor,
            backgroundColor: UIColor,
            readerBackgroundImage: UIImage?,
            dialogueColor: UIColor? = nil,
            dialogueBoxColor: UIColor? = nil
        ) -> ChapterLayout {
            guard attributedString.length > 0 else { return self }
            let updated = NSMutableAttributedString(attributedString: attributedString)
            let fullRange = NSRange(location: 0, length: updated.length)
            let oldBackgroundColor = self.backgroundColor

            // ── Foreground color: apply theme color globally, then restore CSS-specified colors ──
            updated.addAttribute(.foregroundColor, value: textColor, range: fullRange)
            updated.enumerateAttribute(
                HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute,
                in: fullRange,
                options: []
            ) { value, effectiveRange, _ in
                if let cssColor = value as? UIColor {
                    updated.addAttribute(.foregroundColor, value: cssColor, range: effectiveRange)
                }
            }

            // Re-tint quoted dialogue after the global recolor. The theme-swap path recolors an
            // already-paginated layout without re-running the renderer, so the "對話文字高亮"
            // decoration (applied at build time) would otherwise be wiped by the reset above.
            if dialogueColor != nil || dialogueBoxColor != nil {
                DialogueHighlighter.apply(textColor: dialogueColor, boxColor: dialogueBoxColor, to: updated)
            }

            // ── Background color ──
            // A run's `.backgroundColor` is not painted by this pipeline — CoreText's CTLineDraw /
            // CTFrameDraw ignore it, and inline backgrounds here are all custom-drawn
            // (blockBackgroundColorAttribute / inlineBorderBoxAttribute / DialogueHighlighter's box).
            // The page fill alone carries the theme color, so no per-run theme background is applied.
            // This only clears stale theme-colored `.backgroundColor` left on runs by an earlier
            // approach; distinct (CSS-authored) inline backgrounds keep their colors.
            updated.enumerateAttribute(.backgroundColor, in: fullRange, options: []) { value, effectiveRange, _ in
                if let color = value as? UIColor,
                   CoreTextPaginator.colorsApproximatelyEqual(color, oldBackgroundColor) {
                    updated.removeAttribute(.backgroundColor, range: effectiveRange)
                }
            }
            updated.enumerateAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                in: fullRange,
                options: []
            ) { value, effectiveRange, _ in
                if value != nil {
                    if let color = value as? UIColor,
                       CoreTextPaginator.colorsApproximatelyEqual(color, oldBackgroundColor) {
                        updated.addAttribute(
                            HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                            value: backgroundColor,
                            range: effectiveRange
                        )
                    }
                    updated.removeAttribute(.backgroundColor, range: effectiveRange)
                }
            }

            let recoloredBlockRenderables = blockRenderables.mapValues { renderables in
                renderables.map { item in
                    guard item.imageAttachment != nil,
                          let fillColor = item.style.backgroundFillColor,
                          CoreTextPaginator.colorsApproximatelyEqual(fillColor, oldBackgroundColor)
                    else {
                        return item
                    }
                    return RenderedBlockRenderable(
                        rect: item.rect,
                        style: item.style.withBackgroundFillColor(backgroundColor),
                        attributedText: item.attributedText,
                        sourceRanges: item.sourceRanges,
                        imageAttachment: item.imageAttachment
                    )
                }
            }

            let newFramesetter = CoreTextFramesetterFactory.make(for: updated)
            let effectiveBackgroundColor = readerBackgroundImage == nil
                ? (authoredBackgroundColor ?? backgroundColor)
                : backgroundColor
            return ChapterLayout(
                spineIndex: spineIndex,
                attributedString: updated,
                framesetter: newFramesetter,
                pageRanges: pageRanges,
                inlineAttachments: inlineAttachments,
                inlineAnnotations: inlineAnnotations,
                blockAttachments: blockAttachments,
                blockRenderables: recoloredBlockRenderables,
                pageKinds: pageKinds,
                pageBackgroundImage: pageBackgroundImage,
                authoredBackgroundColor: authoredBackgroundColor,
                readerBackgroundImage: readerBackgroundImage,
                anchorOffsets: anchorOffsets,
                renderSize: renderSize,
                fontSize: fontSize,
                backgroundColor: effectiveBackgroundColor,
                contentInsets: contentInsets,
                writingMode: writingMode,
                pageFloatNotches: pageFloatNotches
            )
        }
    }

    enum InvalidationReason {
        case fontSizeChanged  // Clear all caches
        case viewSizeChanged  // Clear all caches
        case themeChanged     // Don't clear caches, only redraw
    }

    private var cache: [CacheKey: ChapterLayout] = [:]
    private let cacheLock = NSLock()
    private struct CacheKey: Hashable {
        let spineIndex: Int
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        let marginH: CGFloat
        let marginV: CGFloat
        let bottomInset: CGFloat
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let letterSpacing: CGFloat
        let writingMode: ReaderWritingMode
        let contentFingerprint: Int
        let pageBackgroundColorFingerprint: UInt32?
    }

    private static func colorFingerprint(_ color: UIColor?) -> UInt32? {
        guard let color else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return UInt32(truncatingIfNeeded: color.hash)
        }
        func byte(_ component: CGFloat) -> UInt32 {
            UInt32((max(0, min(1, component)) * 255).rounded())
        }
        return (byte(red) << 24) | (byte(green) << 16) | (byte(blue) << 8) | byte(alpha)
    }

    private static func layoutFingerprint(for attributedString: NSAttributedString) -> Int {
        var hasher = Hasher()
        hasher.combine(attributedString.length)
        hasher.combine(attributedString.string)

        let fullRange = NSRange(location: 0, length: attributedString.length)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let verticalFormsKey = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)

        attributedString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            hasher.combine(range.location)
            hasher.combine(range.length)

            if let font = attrs[.font] as? UIFont {
                hasher.combine(font.fontName)
                hasher.combine(Double(font.pointSize))
            } else if let rawFont = attrs[.font] {
                let rawObject = rawFont as AnyObject
                if CFGetTypeID(rawObject) == CTFontGetTypeID() {
                    let font = unsafeBitCast(rawObject, to: CTFont.self)
                    hasher.combine(CTFontCopyPostScriptName(font) as String)
                    hasher.combine(Double(CTFontGetSize(font)))
                } else {
                    hasher.combine(String(describing: type(of: rawFont)))
                }
            } else {
                hasher.combine(attrs[.font] != nil)
            }

            if let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle {
                hasher.combine(Double(paragraphStyle.firstLineHeadIndent))
                hasher.combine(Double(paragraphStyle.headIndent))
                hasher.combine(Double(paragraphStyle.tailIndent))
                hasher.combine(Double(paragraphStyle.lineSpacing))
                hasher.combine(Double(paragraphStyle.paragraphSpacing))
                hasher.combine(Double(paragraphStyle.paragraphSpacingBefore))
                hasher.combine(Double(paragraphStyle.minimumLineHeight))
                hasher.combine(Double(paragraphStyle.maximumLineHeight))
                hasher.combine(paragraphStyle.alignment.rawValue)
                // Hyphenation moves where lines break, so it changes pagination itself — it has to
                // be part of the key, or a stale un-hyphenated layout would outlive the change.
                hasher.combine(Double(paragraphStyle.hyphenationFactor))
            }

            hasher.combine(attrs[HTMLAttributedStringBuilder.spacerRunAttribute] != nil)
            hasher.combine(attrs[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] != nil)
            hasher.combine(attrs[HTMLAttributedStringBuilder.pageBreakAttribute] != nil)
            hasher.combine(attrs[verticalFormsKey] as? Bool ?? false)
            // The language tag drives hyphenation, hence line breaks, hence pagination.
            hasher.combine(attrs[ReaderHyphenation.languageAttributeKey] as? String ?? "")

            if let delegate = attrs[delegateKey] {
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                hasher.combine(Double(info.width))
                hasher.combine(Double(info.ascent))
                hasher.combine(Double(info.descent))
                hasher.combine(Double(info.drawWidth))
                hasher.combine(Double(info.drawHeight))
                hasher.combine(info.source)
                hasher.combine(info.alt)
                hasher.combine(info.opacity)
                hasher.combine(info is InlineAnnotationRunInfo)
                if let annotation = info as? InlineAnnotationRunInfo {
                    hasher.combine(annotation.attributedString.length)
                    hasher.combine(annotation.attributedString.string)
                }
            }
        }

        return hasher.finalize()
    }

    // MARK: - Public API

    func paginate(
        spineIndex: Int,
        attrStr: NSAttributedString,
        imagePage: HTMLAttributedStringBuilder.ImagePage? = nil,
        pageBackgroundImage: UIImage? = nil,
        pageBackgroundColor: UIColor? = nil,
        anchorOffsets: [String: Int] = [:],
        renderSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat = 0,
        paragraphSpacing: CGFloat = 0,
        letterSpacing: CGFloat = 0,
        contentInsets: UIEdgeInsets = .zero,
        writingMode: ReaderWritingMode = .horizontal
    ) async -> ChapterLayout {
        let key = CacheKey(spineIndex: spineIndex,
                           width: renderSize.width,
                           height: renderSize.height,
                           fontSize: fontSize,
                           marginH: contentInsets.left,
                           marginV: contentInsets.top,
                           bottomInset: contentInsets.bottom,
                           lineSpacing: lineSpacing,
                           paragraphSpacing: paragraphSpacing,
                           letterSpacing: letterSpacing,
                           writingMode: writingMode,
                           contentFingerprint: Self.layoutFingerprint(for: attrStr),
                           pageBackgroundColorFingerprint: Self.colorFingerprint(pageBackgroundColor))
        Self.debugVerticalLog("EPUBFLOW paginator.request spine=\(spineIndex) writingMode=\(writingMode) isVertical=\(writingMode.isVertical) size=\(renderSize) fontSize=\(fontSize) insets=\(contentInsets) attrLen=\(attrStr.length) fingerprint=\(key.contentFingerprint)")
        if let cached = cachedLayout(for: key) {
            Self.debugVerticalLog("EPUBFLOW paginator.cacheHit spine=\(spineIndex) fingerprint=\(key.contentFingerprint)")
            if writingMode.isVertical {
                Self.debugVerticalLog("paginate cacheHit spine=\(spineIndex) size=\(renderSize) fontSize=\(fontSize) insets=\(contentInsets) attrLen=\(attrStr.length)", verbose: true)
            }
            return cached
        }
        Self.debugVerticalLog("EPUBFLOW paginator.cacheMiss spine=\(spineIndex) fingerprint=\(key.contentFingerprint)")
        if writingMode.isVertical {
            Self.debugVerticalLog("paginate cacheMiss spine=\(spineIndex) size=\(renderSize) fontSize=\(fontSize) insets=\(contentInsets) attrLen=\(attrStr.length)", verbose: true)
        }

        let layout = await Task.detached(priority: .userInitiated) {
            Self.computeLayout(spineIndex: spineIndex,
                               attrStr: attrStr,
                               imagePage: imagePage,
                               pageBackgroundImage: pageBackgroundImage,
                               pageBackgroundColor: pageBackgroundColor,
                               anchorOffsets: anchorOffsets,
                               renderSize: renderSize,
                               fontSize: fontSize,
                               lineSpacing: lineSpacing,
                               contentInsets: contentInsets,
                               writingMode: writingMode)
        }.value

        storeLayout(layout, for: key)
        return layout
    }

    private func cachedLayout(for key: CacheKey) -> ChapterLayout? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func storeLayout(_ layout: ChapterLayout, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = layout
    }

    @MainActor
    func invalidate(reason: InvalidationReason) {
        switch reason {
        case .fontSizeChanged, .viewSizeChanged:
            removeAllCachedLayouts()
        case .themeChanged:
            break
        }
    }

    private func removeAllCachedLayouts() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
    }

    // MARK: - Core pagination algorithm (static, runs on any thread)

    private static func computeLayout(
        spineIndex: Int,
        attrStr: NSAttributedString,
        imagePage: HTMLAttributedStringBuilder.ImagePage?,
        pageBackgroundImage: UIImage?,
        pageBackgroundColor: UIColor?,
        anchorOffsets: [String: Int],
        renderSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        contentInsets: UIEdgeInsets,
        writingMode: ReaderWritingMode
    ) -> ChapterLayout {
        let contentInsets = gridAlignedContentInsets(
            contentInsets,
            renderSize: renderSize,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            writingMode: writingMode
        )
        let contentRect = uiContentRect(
            renderSize: renderSize,
            contentInsets: contentInsets,
            fontSize: fontSize,
            writingMode: writingMode
        )
        let contentPathRect = coreTextContentPathRect(
            renderSize: renderSize,
            contentInsets: contentInsets,
            fontSize: fontSize,
            writingMode: writingMode
        )
        let maxInlineAnnotationAdvance = writingMode.isVertical
            ? max(fontSize * 4, contentPathRect.height - fontSize * 2)
            : nil
        let attrStr = preparedAttributedString(
            attrStr,
            writingMode: writingMode,
            fontSize: fontSize,
            maxInlineAnnotationAdvance: maxInlineAnnotationAdvance
        )
        if writingMode.isVertical {
            debugVerticalLog("computeLayout spine=\(spineIndex) renderSize=\(renderSize) fontSize=\(fontSize) contentInsets=\(contentInsets) ctPathRect=\(contentPathRect) maxAnnotationAdvance=\(maxInlineAnnotationAdvance ?? 0) attrLen=\(attrStr.length)", verbose: true)
            debugAttributedPrefix(attrStr, label: "computeLayout.attrPrefix", limit: 24)
        }
        debugVerticalLog("EPUBFLOW paginator.compute spine=\(spineIndex) writingMode=\(writingMode) isVertical=\(writingMode.isVertical) contentRect=\(contentRect) ctPathRect=\(contentPathRect) maxAnnotationAdvance=\(maxInlineAnnotationAdvance ?? 0) preparedLen=\(attrStr.length)")
        let readerBackgroundColor = Self.pageBackgroundColor(from: attrStr)
        let effectiveBackgroundColor = pageBackgroundColor ?? readerBackgroundColor

        if let imagePage {
            let framesetter = CoreTextFramesetterFactory.make(for: attrStr)
            let pageRect = CGRect(origin: .zero, size: renderSize)
            let imageRect = aspectFitRect(
                for: imagePage.image?.size ?? pageRect.size,
                in: pageRect
            )
            return ChapterLayout(
                spineIndex: spineIndex,
                attributedString: attrStr,
                framesetter: framesetter,
                pageRanges: [CFRangeMake(0, max(attrStr.length, 1))],
                inlineAttachments: [:],
                inlineAnnotations: [:],
                blockAttachments: imagePage.image.map { [0: [RenderedAttachment(rect: imageRect, image: $0, opacity: 1)]] } ?? [:],
                blockRenderables: [:],
                pageKinds: [.image],
                pageBackgroundImage: nil,
                authoredBackgroundColor: pageBackgroundColor,
                anchorOffsets: anchorOffsets,
                renderSize: renderSize,
                fontSize: fontSize,
                backgroundColor: effectiveBackgroundColor,
                contentInsets: contentInsets,
                writingMode: writingMode
            )
        }

        let framesetter = CoreTextFramesetterFactory.make(for: attrStr)
        let pagePath = CGPath(rect: contentPathRect, transform: nil)

        var pageRanges: [CFRange] = []
        var currentLocation = 0
        let forcedPageBreakRanges = forcedPageBreakRanges(in: attrStr)
        let keepTogetherRanges = writingMode.isVertical ? [] : avoidPageBreakInsideRanges(in: attrStr)
        // CSS floats (horizontal layout only): each carves a notch out of the page it lands on so text
        // wraps beside it. Stored per page for reuse at draw time and attachment extraction.
        let floatMarkers = writingMode.isVertical ? [] : Self.floatMarkers(in: attrStr)
        var pageFloatNotches: [Int: CGRect] = [:]
        var pageFloatAttachments: [Int: [RenderedAttachment]] = [:]

        while currentLocation < attrStr.length {
            if let breakRange = forcedPageBreakRanges.first(where: { $0.location <= currentLocation && currentLocation < $0.location + $0.length }) {
                currentLocation = breakRange.location + breakRange.length
                continue
            }

            let nextForcedBreak = forcedPageBreakRanges.first { $0.location > currentLocation }?.location ?? attrStr.length
            let remainingLength = nextForcedBreak - currentLocation
            guard remainingLength > 0 else {
                currentLocation = min(attrStr.length, currentLocation + 1)
                continue
            }

            let searchRange = CFRangeMake(currentLocation, remainingLength)
            let pageIndex = pageRanges.count

            // ── CSS float on this page ─────────────────────────────────────
            var notch: CGRect?
            var floatAttachment: RenderedAttachment?
            var floatMarkerOffset: Int?
            if let marker = floatMarkers.first(where: { $0.offset >= currentLocation && $0.offset < nextForcedBreak }),
               let image = marker.placeholder.image {
                floatMarkerOffset = marker.offset
                let p = marker.placeholder
                let notchWidth = p.drawWidth + p.marginLeft + p.marginRight
                let notchHeight = min(contentPathRect.height, p.drawHeight + p.marginTop + p.marginBottom)
                // Probe with a rectangular frame to find the y of the float's anchor line.
                let probe = makeFrame(framesetter: framesetter, range: searchRange, path: pagePath, writingMode: writingMode)
                if let lineTop = Self.lineTopY(in: probe, offset: marker.offset, contentPathRect: contentPathRect) {
                    let notchBottom = lineTop - notchHeight
                    if notchBottom < contentPathRect.minY, marker.offset > currentLocation {
                        // The float won't fit below its anchor on this page: end the page just before the
                        // float so it starts the next page at full height (avoids clipping).
                        let advance = max(1, marker.offset - currentLocation)
                        pageRanges.append(CFRangeMake(currentLocation, advance))
                        currentLocation += advance
                        continue
                    }
                    let clampedBottom = max(contentPathRect.minY, notchBottom)
                    let uiTop = renderSize.height - lineTop + p.marginTop
                    switch p.side {
                    case .left:
                        notch = CGRect(x: contentPathRect.minX, y: clampedBottom, width: notchWidth, height: lineTop - clampedBottom)
                        floatAttachment = RenderedAttachment(
                            rect: CGRect(x: contentPathRect.minX + p.marginLeft, y: uiTop, width: p.drawWidth, height: p.drawHeight),
                            image: image, opacity: 1,
                            sourceHref: p.source.isEmpty ? nil : p.source, alt: p.alt,
                            originalSize: image.size
                        )
                    case .right:
                        notch = CGRect(x: contentPathRect.maxX - notchWidth, y: clampedBottom, width: notchWidth, height: lineTop - clampedBottom)
                        floatAttachment = RenderedAttachment(
                            rect: CGRect(x: contentPathRect.maxX - p.marginRight - p.drawWidth, y: uiTop, width: p.drawWidth, height: p.drawHeight),
                            image: image, opacity: 1,
                            sourceHref: p.source.isEmpty ? nil : p.source, alt: p.alt,
                            originalSize: image.size
                        )
                    }
                }
            }

            let path = Self.framePath(contentPathRect: contentPathRect, floatNotch: notch)
            let frame = makeFrame(framesetter: framesetter, range: searchRange, path: path, writingMode: writingMode)
            let visibleRange = CTFrameGetVisibleStringRange(frame)

            // Prevent infinite loop: if visibleRange.length == 0, force advance by one character
            let proposedAdvance = min(visibleRange.length > 0 ? visibleRange.length : 1, remainingLength)
            let proposedEnd = currentLocation + proposedAdvance
            let protectedEnd = CJKTypographyProcessor.protectedLineBreakOffset(
                proposedEnd,
                in: attrStr.string,
                lowerBound: currentLocation
            )
            var advance = min(remainingLength, max(1, protectedEnd - currentLocation))
            let naturalBoundary = currentLocation + advance
            if let protectedRange = keepTogetherRanges.first(where: { range in
                range.location < naturalBoundary && naturalBoundary < range.location + range.length
            }), protectedRange.location > currentLocation {
                advance = max(1, protectedRange.location - currentLocation)
            }
            pageRanges.append(CFRangeMake(currentLocation, advance))
            let pageEnd = currentLocation + advance
            if let notch,
               let floatMarkerOffset,
               floatMarkerOffset < pageEnd {
                pageFloatNotches[pageIndex] = notch
            }
            if let floatAttachment,
               let floatMarkerOffset,
               floatMarkerOffset < pageEnd {
                pageFloatAttachments[pageIndex, default: []].append(floatAttachment)
            }
            currentLocation += advance
        }
        if writingMode.isVertical {
            let rangePreview = pageRanges.prefix(6).map { "(\($0.location),\($0.length))" }.joined(separator: ",")
            debugVerticalLog("pageRanges count=\(pageRanges.count) first=\(rangePreview)", verbose: true)
        }
        let rangePreview = pageRanges.prefix(6).map { "(\($0.location),\($0.length))" }.joined(separator: ",")
        debugVerticalLog("EPUBFLOW paginator.pageRanges spine=\(spineIndex) count=\(pageRanges.count) first=\(rangePreview)")

        let (inlineAttachments, blockAttachmentsBase, pageKinds) = extractImages(
            framesetter: framesetter,
            pageRanges: pageRanges,
            renderSize: renderSize,
            contentPathRect: contentPathRect,
            attrStr: attrStr,
            writingMode: writingMode,
            floatNotches: pageFloatNotches
        )
        // Merge in the floated images (drawn via the block-attachment path) for pages that carry them.
        var blockAttachments = blockAttachmentsBase
        for (pageIdx, attachments) in pageFloatAttachments {
            blockAttachments[pageIdx, default: []].append(contentsOf: attachments)
        }
        let inlineAnnotations = extractInlineAnnotations(
            framesetter: framesetter,
            pageRanges: pageRanges,
            renderSize: renderSize,
            contentPathRect: contentPathRect,
            writingMode: writingMode,
            floatNotches: pageFloatNotches
        )
        let blockRenderables = extractBlockRenderables(
            framesetter: framesetter,
            pageRanges: pageRanges,
            contentPathRect: contentPathRect,
            renderSize: renderSize,
            attrStr: attrStr,
            writingMode: writingMode,
            floatNotches: pageFloatNotches
        )
        let inlineAttachmentCount = inlineAttachments.values.reduce(0) { $0 + $1.count }
        let inlineAnnotationCount = inlineAnnotations.values.reduce(0) { $0 + $1.count }
        let blockAttachmentCount = blockAttachments.values.reduce(0) { $0 + $1.count }
        let blockRenderableCount = blockRenderables.values.reduce(0) { $0 + $1.count }
        debugVerticalLog("EPUBFLOW paginator.extracted spine=\(spineIndex) inlineImages=\(inlineAttachmentCount) inlineAnnotations=\(inlineAnnotationCount) blockImages=\(blockAttachmentCount) blockRenderables=\(blockRenderableCount)")

        logLayoutFormatProbe(
            spineIndex: spineIndex,
            attrStr: attrStr,
            framesetter: framesetter,
            pageRanges: pageRanges,
            contentPathRect: contentPathRect,
            writingMode: writingMode
        )

        return ChapterLayout(
            spineIndex: spineIndex,
            attributedString: attrStr,
            framesetter: framesetter,
            pageRanges: pageRanges,
            inlineAttachments: inlineAttachments,
            inlineAnnotations: inlineAnnotations,
            blockAttachments: blockAttachments,
            blockRenderables: blockRenderables,
            pageKinds: pageKinds,
            pageBackgroundImage: pageBackgroundImage,
            authoredBackgroundColor: pageBackgroundColor,
            anchorOffsets: anchorOffsets,
            renderSize: renderSize,
            fontSize: fontSize,
            backgroundColor: effectiveBackgroundColor,
            contentInsets: contentInsets,
            writingMode: writingMode,
            pageFloatNotches: pageFloatNotches
        )
    }

    /// ⟐ layout-time format probe (Release-visible): for the first pages, logs each frame line's
    /// ABSOLUTE string location, origin.x, and the HEX of the character before the line start,
    /// plus each paragraph's terminator hex. Identifies which separator character CoreText saw
    /// (LF re-indents; U+2028/U+0085 only line-break → indent+spacing vanish). Horizontal only;
    /// throttled per process. Remove once the 段評 indent/spacing regression is fixed.
    private nonisolated(unsafe) static var layoutFormatProbeCount = 0
    private static func logLayoutFormatProbe(
        spineIndex: Int,
        attrStr: NSAttributedString,
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        contentPathRect: CGRect,
        writingMode: ReaderWritingMode
    ) {
        guard !writingMode.isVertical,
              layoutFormatProbeCount < 6,
              let pageRange = pageRanges.first
        else { return }
        layoutFormatProbeCount += 1

        let ns = attrStr.string as NSString
        // Paragraph walk: style + terminator hex for the first 4 paragraphs.
        var paragraphInfo: [String] = []
        var location = 0
        while location < ns.length, paragraphInfo.count < 4 {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = max(NSMaxRange(paraRange), location + 1)
            guard paraRange.length > 0 else { continue }
            let para = attrStr.attribute(
                .paragraphStyle, at: paraRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let terminator = ns.character(at: NSMaxRange(paraRange) - 1)
            let preview = ns.substring(with: paraRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(5)
            paragraphInfo.append(
                "@\(paraRange.location)+\(paraRange.length)"
                    + " indent=\(Int(para?.firstLineHeadIndent ?? -1))"
                    + " spacing=\(Int(para?.paragraphSpacing ?? -1))"
                    + " end=\(String(format: "U+%04X", terminator))«\(preview)»"
            )
        }

        // First page's frame, built exactly like the page view builds it at draw time.
        let path = framePath(contentPathRect: contentPathRect, floatNotch: nil)
        let frame = makeFrame(
            framesetter: framesetter,
            range: pageRange,
            path: path,
            writingMode: writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty {
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        }
        var lineInfo: [String] = []
        for (index, line) in lines.enumerated() where index < 6 {
            let lineRange = CTLineGetStringRange(line)
            let start = lineRange.location
            let previousHex: String
            if start > 0, start - 1 < ns.length {
                previousHex = String(format: "U+%04X", ns.character(at: start - 1))
            } else {
                previousHex = start == 0 ? "BOF" : "OOB"
            }
            let previewLength = min(3, max(0, ns.length - start))
            let preview = previewLength > 0
                ? ns.substring(with: NSRange(location: start, length: previewLength))
                    .replacingOccurrences(of: "\n", with: "\\n")
                : ""
            lineInfo.append("@\(start)+\(lineRange.length) x=\(Int(origins[index].x)) prev=\(previousHex)«\(preview)»")
        }

        AppLogger.render("⟐ layout format spine=\(spineIndex)", context: [
            "len": ns.length,
            "page0": "\(pageRange.location)+\(pageRange.length)",
            "paras": paragraphInfo.joined(separator: " | "),
            "lines": lineInfo.joined(separator: " | "),
        ])
    }

    private static func forcedPageBreakRanges(in attrStr: NSAttributedString) -> [NSRange] {
        guard attrStr.length > 0 else { return [] }
        var ranges: [NSRange] = []
        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.pageBreakAttribute,
            in: NSRange(location: 0, length: attrStr.length),
            options: []
        ) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func avoidPageBreakInsideRanges(in attrStr: NSAttributedString) -> [NSRange] {
        guard attrStr.length > 0 else { return [] }

        struct Accumulator {
            var range: NSRange
        }

        func collect(
            styleKey: NSAttributedString.Key,
            idKey: NSAttributedString.Key,
            into groups: inout [String: Accumulator]
        ) {
            attrStr.enumerateAttribute(
                styleKey,
                in: NSRange(location: 0, length: attrStr.length),
                options: []
            ) { value, effectiveRange, _ in
                guard let style = value as? HTMLAttributedStringBuilder.BlockRenderStyle,
                      style.avoidsPageBreakInside,
                      let blockID = attrStr.attribute(
                          idKey,
                          at: effectiveRange.location,
                          effectiveRange: nil
                      ) as? String
                else { return }

                if var existing = groups[blockID] {
                    existing.range = NSUnionRange(existing.range, effectiveRange)
                    groups[blockID] = existing
                } else {
                    groups[blockID] = Accumulator(range: effectiveRange)
                }
            }
        }

        var groups: [String: Accumulator] = [:]
        collect(
            styleKey: HTMLAttributedStringBuilder.outerContainerBlockRenderStyleAttribute,
            idKey: HTMLAttributedStringBuilder.outerContainerBlockRenderIDAttribute,
            into: &groups
        )
        collect(
            styleKey: HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            idKey: HTMLAttributedStringBuilder.containerBlockRenderIDAttribute,
            into: &groups
        )
        collect(
            styleKey: HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            idKey: HTMLAttributedStringBuilder.blockRenderIDAttribute,
            into: &groups
        )

        return groups.values
            .map(\.range)
            .filter { $0.length > 1 }
            .sorted {
                if $0.location != $1.location { return $0.location < $1.location }
                return $0.length < $1.length
            }
    }

    /// Returns CoreText frame attributes for the given writing mode.
    /// Vertical (.verticalRTL): kCTFrameProgressionAttributeName = rightToLeft
    ///   → CoreText lays out columns right-to-left, top-to-bottom.
    /// Horizontal (.horizontal): no special attributes.
    static func frameAttributes(for writingMode: ReaderWritingMode) -> [String: Any] {
        switch writingMode {
        case .horizontal:
            return [:]
        case .verticalRTL:
            return [
                kCTFrameProgressionAttributeName as String: Int(CTFrameProgression.rightToLeft.rawValue)
            ]
        }
    }

    private static func pageBackgroundColor(from attrStr: NSAttributedString) -> UIColor {
        guard attrStr.length > 0 else { return .systemBackground }
        let fullRange = NSRange(location: 0, length: attrStr.length)
        var result: UIColor?
        attrStr.enumerateAttribute(.backgroundColor, in: fullRange, options: []) { value, _, stop in
            if let color = value as? UIColor {
                result = color
                stop.pointee = true
            }
        }
        return result ?? .systemBackground
    }

    private static func colorsApproximatelyEqual(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        else {
            return lhs == rhs
        }
        let tolerance: CGFloat = 0.01
        return abs(lr - rr) <= tolerance
            && abs(lg - rg) <= tolerance
            && abs(lb - rb) <= tolerance
            && abs(la - ra) <= tolerance
    }

    static func makeFrame(
        framesetter: CTFramesetter,
        range: CFRange,
        path: CGPath,
        writingMode: ReaderWritingMode
    ) -> CTFrame {
        let attributes = frameAttributes(for: writingMode)
        let frameAttributes = attributes.isEmpty ? nil : attributes as CFDictionary
        return CTFramesetterCreateFrame(framesetter, range, path, frameAttributes)
    }

    // MARK: - CSS float support

    struct FloatMarker {
        let offset: Int
        let placeholder: HTMLAttributedStringBuilder.FloatPlaceholder
    }

    /// All CSS-float anchor markers in the string, in document order.
    static func floatMarkers(in attrStr: NSAttributedString) -> [FloatMarker] {
        guard attrStr.length > 0 else { return [] }
        var result: [FloatMarker] = []
        attrStr.enumerateAttribute(
            HTMLAttributedStringBuilder.floatAttribute,
            in: NSRange(location: 0, length: attrStr.length),
            options: []
        ) { value, range, _ in
            if let placeholder = value as? HTMLAttributedStringBuilder.FloatPlaceholder {
                result.append(FloatMarker(offset: range.location, placeholder: placeholder))
            }
        }
        return result
    }

    /// The CoreText frame path for a page: the content rect, with a rectangular notch carved out of one
    /// vertical edge when a CSS float occupies the page. CoreText then wraps lines beside the float. With no
    /// notch this is just the content rect (the common, unchanged case).
    static func framePath(contentPathRect: CGRect, floatNotch: CGRect?) -> CGPath {
        guard let notch = floatNotch, notch.width > 0, notch.height > 0 else {
            return CGPath(rect: contentPathRect, transform: nil)
        }
        let minX = contentPathRect.minX
        let maxX = contentPathRect.maxX
        let minY = contentPathRect.minY
        let maxY = contentPathRect.maxY
        let yb = max(minY, notch.minY)
        let yt = min(maxY, notch.maxY)
        guard yt > yb else { return CGPath(rect: contentPathRect, transform: nil) }

        let path = CGMutablePath()
        if notch.minX <= minX + 0.5 {
            // Notch on the LEFT edge (float:left).
            let nx = min(maxX, minX + notch.width)
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: yb))
            path.addLine(to: CGPoint(x: nx, y: yb))
            path.addLine(to: CGPoint(x: nx, y: yt))
            path.addLine(to: CGPoint(x: minX, y: yt))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: minY))
        } else {
            // Notch on the RIGHT edge (float:right).
            let nx = max(minX, maxX - notch.width)
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: maxX, y: yt))
            path.addLine(to: CGPoint(x: nx, y: yt))
            path.addLine(to: CGPoint(x: nx, y: yb))
            path.addLine(to: CGPoint(x: maxX, y: yb))
            path.addLine(to: CGPoint(x: maxX, y: minY))
        }
        path.closeSubpath()
        return path
    }

    /// The top edge (CoreText y-up, absolute coords) of the line containing `offset` within `frame`.
    static func lineTopY(in frame: CTFrame, offset: Int, contentPathRect: CGRect) -> CGFloat? {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            if offset >= r.location, offset < r.location + max(1, r.length) {
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                return contentPathRect.origin.y + origins[i].y + ascent
            }
        }
        return nil
    }

    /// Vertical mode: glyph-aware normalization → font cascade → paragraph style → vertical forms → ASCII exceptions.
    /// Horizontal mode: returns unchanged.
    static func preparedAttributedString(
        _ attrStr: NSAttributedString,
        writingMode: ReaderWritingMode,
        fontSize: CGFloat,
        maxInlineAnnotationAdvance: CGFloat?
    ) -> NSAttributedString {
        guard writingMode.isVertical, attrStr.length > 0 else { return attrStr }
        let mutable = NSMutableAttributedString(attributedString: attrStr)
        let fullRange = NSRange(location: 0, length: mutable.length)
        debugVerticalLog("prepare.begin len=\(mutable.length) rawPrefix=\"\(debugTextPreview(mutable.string, limit: 80))\"", verbose: true)
        debugAttributedPrefix(mutable, label: "prepare.before", limit: 18)

        // Step 1: Build per-font vertical substitution map from the primary font.
        //         Only substitutes characters the font truly lacks vert alternates for.
        let primaryFont = (attrStr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) ?? UIFont.systemFont(ofSize: fontSize)
        let verticalConfig = VerticalLayoutConfig(font: primaryFont as CTFont)
        let verticalMap = verticalConfig.substitutionMap

        // Step 2: Normalize punctuation in-place on mutableString to preserve attributes.
        //         Phase 1: half-width brackets → full-width (always).
        //         Phase 2: full-width → vertical presentation forms (only where font lacks vert glyphs).
        mutable.normalizeForVerticalLayoutInPlace(using: verticalMap)

        // Step 2b: CoreText trims or collapses leading whitespace at line starts.
        // In vertical books, EPUBs often encode first-line indent literally as
        // leading ideographic spaces. Preserve their advance with invisible spacer runs.
        let spacerCount = replaceLeadingIdeographicSpacesWithVerticalSpacers(in: mutable, fontSize: fontSize)
        debugVerticalLog("EPUBFLOW prepare.leadingIdeographicSpaceSpacers count=\(spacerCount) afterPrefix=\"\(debugTextPreview(mutable.string, limit: 80))\"")
        debugVerticalLog("prepare.leadingIdeographicSpaceSpacers count=\(spacerCount) afterPrefix=\"\(debugTextPreview(mutable.string, limit: 80))\"", verbose: true)
        debugAttributedPrefix(mutable, label: "prepare.afterSpacers", limit: 18)

        if let maxInlineAnnotationAdvance {
            let splitCount = splitOversizedInlineAnnotations(
                in: mutable,
                fontSize: fontSize,
                maxAdvance: maxInlineAnnotationAdvance
            )
            debugVerticalLog("prepare.splitOversizedInlineAnnotations count=\(splitCount) maxAdvance=\(maxInlineAnnotationAdvance)", verbose: splitCount == 0)
            debugAttributedPrefix(mutable, label: "prepare.afterAnnotationSplit", limit: 24)
        }

        // Step 3: Font cascade list for rare / supplemented CJK characters.
        //         PingFang → Songti → Kaiti → Heiti fallback chain.
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let ctFont = font as CTFont
            let descriptor = CTFontCopyFontDescriptor(ctFont)
            let fallbackNames = ["Songti TC", "Kaiti TC", "Heiti TC"]
            let fallbackDescriptors = fallbackNames.map { name in
                CTFontDescriptorCreateWithNameAndSize(name as CFString, font.pointSize)
            }
            let cascadeAttributes = [kCTFontCascadeListAttribute: fallbackDescriptors]
            let descriptorWithFallback = CTFontDescriptorCreateCopyWithAttributes(
                descriptor, cascadeAttributes as CFDictionary
            )
            let finalCTFont = CTFontCreateWithFontDescriptor(descriptorWithFallback, font.pointSize, nil)
            mutable.addAttribute(.font, value: finalCTFont, range: range)
        }

        // Step 4: Ensure every range has a paragraph style with CJK-vertical defaults.
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            let compactSpacing = mutable.attribute(
                HTMLAttributedStringBuilder.compactBlockSpacingAttribute,
                at: range.location,
                effectiveRange: nil
            ) != nil
            if let existing = value as? NSParagraphStyle {
                let updated = existing.mutableCopy() as! NSMutableParagraphStyle
                if compactSpacing {
                    let compactAfterMinimum: CGFloat = 0.01
                    let compactMaximum = max(compactAfterMinimum, fontSize * 0.15)
                    updated.paragraphSpacingBefore = min(max(0, updated.paragraphSpacingBefore), compactMaximum)
                    updated.paragraphSpacing = max(
                        compactAfterMinimum,
                        min(max(updated.paragraphSpacing, 0), compactMaximum)
                    )
                } else if updated.paragraphSpacing <= 0 {
                    updated.paragraphSpacing = fontSize * 0.8
                }
                if updated.lineSpacing <= 0 {
                    updated.lineSpacing = fontSize * 0.3
                }
                debugVerticalLog("EPUBFLOW prepare.paragraphStyle.existing range=(\(range.location),\(range.length)) firstIndent=\(updated.firstLineHeadIndent) headIndent=\(updated.headIndent) lineSpacing=\(updated.lineSpacing) paraSpacing=\(updated.paragraphSpacing)", verbose: range.location > 256)
                mutable.addAttribute(.paragraphStyle, value: updated, range: range)
            } else {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = fontSize * 2
                style.paragraphSpacing = compactSpacing ? 0.01 : fontSize * 0.8
                style.lineSpacing = fontSize * 0.3
                debugVerticalLog("EPUBFLOW prepare.paragraphStyle.fallback range=(\(range.location),\(range.length)) firstIndent=\(style.firstLineHeadIndent) headIndent=\(style.headIndent) lineSpacing=\(style.lineSpacing) paraSpacing=\(style.paragraphSpacing)", verbose: range.location > 256)
                mutable.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }

        // Step 5: Apply vertical forms globally.
        let verticalFormsKey = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)
        mutable.addAttribute(verticalFormsKey, value: true, range: fullRange)

        // Step 6: Remove vertical forms from non-CJK Latin / numeric / ASCII
        // punctuation ranges so mixed English IDs stay in one sideways run.
        let latinPattern = "[^\\p{Han}\u{3000}-\u{303F}\u{FF00}-\u{FFEF}\u{FE30}-\u{FE4F}\u{FE10}-\u{FE1F}]+"
        if let regex = try? NSRegularExpression(pattern: latinPattern, options: []) {
            let matches = regex.matches(in: mutable.string, options: [], range: fullRange)
            for match in matches {
                mutable.removeAttribute(verticalFormsKey, range: match.range)
                applyVerticalLatinBaselineAlignment(to: mutable, range: match.range)
            }
            debugVerticalLog("prepare.latinRuns count=\(matches.count)", verbose: true)
        }
        debugAttributedPrefix(mutable, label: "prepare.final", limit: 24)
        return mutable
    }

    private static func replaceLeadingIdeographicSpacesWithVerticalSpacers(
        in mutable: NSMutableAttributedString,
        fontSize: CGFloat
    ) -> Int {
        guard mutable.length > 0 else { return 0 }
        let nsString = mutable.string as NSString
        var ranges: [NSRange] = []
        var index = 0
        var atParagraphStart = true

        while index < mutable.length {
            let range = nsString.rangeOfComposedCharacterSequence(at: index)
            let unit = nsString.substring(with: range)
            if atParagraphStart, unit == "\u{3000}" {
                ranges.append(range)
                index = range.location + range.length
                continue
            }

            atParagraphStart = unit == "\n" || unit == "\u{2029}"
            index = range.location + range.length
        }

        for range in ranges.reversed() {
            let attrs = mutable.attributes(at: range.location, effectiveRange: nil)
            let font = verticalSpacerFont(from: attrs[.font], fallbackSize: fontSize)
            let textColor = attrs[.foregroundColor] as? UIColor ?? .clear
            let spacer = NSMutableAttributedString(attributedString: RunDelegateProvider.makeVerticalSpacerPlaceholder(
                advance: font.pointSize,
                font: font,
                textColor: textColor
            ))
            let spacerRange = NSRange(location: 0, length: spacer.length)
            spacer.addAttributes(attrs, range: spacerRange)
            spacer.addAttribute(HTMLAttributedStringBuilder.spacerRunAttribute, value: true, range: spacerRange)
            mutable.replaceCharacters(in: range, with: spacer)
        }
        return ranges.count
    }

    private static func verticalSpacerFont(from value: Any?, fallbackSize: CGFloat) -> UIFont {
        if let font = value as? UIFont {
            return font
        }
        return .systemFont(ofSize: fallbackSize)
    }

    private static func splitOversizedInlineAnnotations(
        in mutable: NSMutableAttributedString,
        fontSize: CGFloat,
        maxAdvance: CGFloat
    ) -> Int {
        guard mutable.length > 0, maxAdvance > 0 else { return 0 }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var replacements: [(range: NSRange, replacement: NSAttributedString, oldAdvance: CGFloat, chunks: Int)] = []
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(SelfPlaceholderKeys.inlineAnnotation, in: fullRange, options: []) { value, range, _ in
            guard value != nil,
                  let delegate = mutable.attribute(delegateKey, at: range.location, effectiveRange: nil)
            else { return }

            let ctDelegate = delegate as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(ctDelegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            guard let annotation = info as? InlineAnnotationRunInfo,
                  annotation.width > maxAdvance
            else { return }

            var baseAttributes = mutable.attributes(at: range.location, effectiveRange: nil)
            baseAttributes.removeValue(forKey: delegateKey)
            baseAttributes.removeValue(forKey: SelfPlaceholderKeys.inlineAnnotation)
            baseAttributes.removeValue(forKey: SelfPlaceholderKeys.spacer)

            let font = verticalSpacerFont(from: baseAttributes[.font], fallbackSize: fontSize)
            let textColor = baseAttributes[.foregroundColor] as? UIColor ?? .label
            let replacement = NSMutableAttributedString(attributedString: RunDelegateProvider.makeInlineAnnotationPlaceholders(
                attributedString: annotation.attributedString,
                placeholderFont: font,
                textColor: textColor,
                maxAdvance: maxAdvance
            ))
            guard replacement.length > 0, replacement.length > range.length else { return }

            let replacementRange = NSRange(location: 0, length: replacement.length)
            replacement.addAttributes(baseAttributes, range: replacementRange)
            replacement.addAttribute(SelfPlaceholderKeys.inlineAnnotation, value: true, range: replacementRange)
            replacement.addAttribute(SelfPlaceholderKeys.spacer, value: true, range: replacementRange)
            replacements.append((range, replacement, annotation.width, replacement.length))
        }

        for item in replacements.reversed() {
            mutable.replaceCharacters(in: item.range, with: item.replacement)
            debugVerticalLog("splitInlineAnnotation loc=\(item.range.location) oldAdvance=\(item.oldAdvance) maxAdvance=\(maxAdvance) chunks=\(item.chunks)")
        }
        return replacements.count
    }

    private enum SelfPlaceholderKeys {
        static let inlineAnnotation = HTMLAttributedStringBuilder.inlineAnnotationRunAttribute
        static let spacer = HTMLAttributedStringBuilder.spacerRunAttribute
    }

    private static func debugAttributedPrefix(
        _ attributedString: NSAttributedString,
        label: String,
        limit: Int
    ) {
        #if DEBUG
        guard attributedString.length > 0 else {
            debugVerticalLog("\(label) empty", verbose: true)
            return
        }
        let nsString = attributedString.string as NSString
        var parts: [String] = []
        var index = 0
        var seen = 0
        while index < attributedString.length, seen < limit {
            let range = nsString.rangeOfComposedCharacterSequence(at: index)
            let unit = nsString.substring(with: range)
            let attrs = attributedString.attributes(at: index, effectiveRange: nil)
            parts.append(debugUnitDescription(unit, attrs: attrs, location: index))
            index = range.location + range.length
            seen += 1
        }
        debugVerticalLog("\(label) \(parts.joined(separator: " | "))", verbose: true)
        #endif
    }

    private static func debugUnitDescription(
        _ unit: String,
        attrs: [NSAttributedString.Key: Any],
        location: Int
    ) -> String {
        #if DEBUG
        let scalarHex = unit.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: "+")
        let visible: String
        if unit == "\u{FFFC}" {
            visible = "OBJ"
        } else if unit == "\u{3000}" {
            visible = "IDEOSPACE"
        } else {
            visible = unit
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }

        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let verticalFormsKey = NSAttributedString.Key(kCTVerticalFormsAttributeName as String)
        var flags: [String] = []
        if attrs[delegateKey] != nil { flags.append("delegate") }
        if attrs[HTMLAttributedStringBuilder.spacerRunAttribute] != nil { flags.append("spacer") }
        if attrs[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] != nil { flags.append("annotation") }
        if attrs[verticalFormsKey] != nil { flags.append("vertical") }
        if let font = attrs[.font] as? UIFont {
            flags.append("font=\(String(format: "%.1f", font.pointSize))")
        } else if attrs[.font] != nil {
            flags.append("fontType=\(String(describing: type(of: attrs[.font]!)))")
        }
        if let baselineOffset = baselineOffsetValue(attrs[.baselineOffset]) {
            flags.append("baselineOffset=\(String(format: "%.2f", baselineOffset))")
        }
        if let paragraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle {
            flags.append("firstIndent=\(String(format: "%.1f", paragraphStyle.firstLineHeadIndent))")
            flags.append("lineSpacing=\(String(format: "%.1f", paragraphStyle.lineSpacing))")
        }
        if let delegate = attrs[delegateKey] {
            let ctDelegate = delegate as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(ctDelegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            if let annotation = info as? InlineAnnotationRunInfo {
                flags.append("annW=\(String(format: "%.1f", annotation.width))")
                flags.append("annDraw=\(String(format: "%.1f", annotation.drawWidth))x\(String(format: "%.1f", annotation.drawHeight))")
                flags.append("annText=\"\(debugTextPreview(annotation.attributedString.string, limit: 28))\"")
            } else {
                flags.append("runW=\(String(format: "%.1f", info.width))")
                flags.append("draw=\(String(format: "%.1f", info.drawWidth))x\(String(format: "%.1f", info.drawHeight))")
                flags.append("img=\(info.image == nil ? "nil" : "Y")")
                if !info.source.isEmpty { flags.append("src=\(info.source)") }
                if let alt = info.alt { flags.append("alt=\(alt)") }
            }
        }
        return "#\(location):\(visible){\(scalarHex)}[\(flags.joined(separator: ","))]"
        #else
        return ""
        #endif
    }

    private static func debugTextPreview(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{FFFC}", with: "OBJ")
            .replacingOccurrences(of: "\u{3000}", with: "IDEOSPACE")
        return String(normalized.prefix(limit))
    }

    /// Keep sideways Latin centered on the same ideographic baseline axis as
    /// neighboring full-width CJK glyphs in vertical frames.
    private static func applyVerticalLatinBaselineAlignment(
        to attributedString: NSMutableAttributedString,
        range: NSRange
    ) {
        attributedString.addAttribute(
            NSAttributedString.Key(kCTBaselineClassAttributeName as String),
            value: kCTBaselineClassIdeographicCentered,
            range: range
        )
        attributedString.enumerateAttribute(.font, in: range, options: []) { value, fontRange, _ in
            guard let offset = verticalLatinCenteringOffset(for: value) else { return }
            attributedString.addAttribute(.baselineOffset, value: offset, range: fontRange)
        }
    }

    private static func verticalLatinCenteringOffset(for fontValue: Any?) -> CGFloat? {
        let correctionFactor: CGFloat = 0.5
        if let font = fontValue as? UIFont {
            return -((font.ascender + font.descender) / 2) * correctionFactor
        }
        guard let fontValue,
              CFGetTypeID(fontValue as CFTypeRef) == CTFontGetTypeID()
        else { return nil }
        let font = fontValue as! CTFont
        return -((CTFontGetAscent(font) - CTFontGetDescent(font)) / 2) * correctionFactor
    }

    private static func baselineOffsetValue(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        return nil
    }

    /// Horizontal mode: snaps bottom inset to integer line grid for clean page fill.
    /// Vertical mode returns contentInsets unchanged — column-based layout doesn't
    /// use horizontal line-grid alignment.
    private static func gridAlignedContentInsets(
        _ contentInsets: UIEdgeInsets,
        renderSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        writingMode: ReaderWritingMode
    ) -> UIEdgeInsets {
        guard !writingMode.isVertical, contentInsets.bottom > 0 else {
            return contentInsets
        }
        let rawHeight = renderSize.height - contentInsets.top - contentInsets.bottom
        let lineHeight = max(1, fontSize + lineSpacing)
        let lineCount = floor(rawHeight / lineHeight)
        guard lineCount >= 1 else { return contentInsets }

        let alignedHeight = lineCount * lineHeight
        let alignedBottom = renderSize.height - contentInsets.top - alignedHeight
        guard alignedBottom.isFinite else { return contentInsets }

        var insets = contentInsets
        insets.bottom = max(contentInsets.bottom, alignedBottom)
        return insets
    }

    static func uiContentRect(
        renderSize: CGSize,
        contentInsets: UIEdgeInsets,
        fontSize: CGFloat,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        _ = fontSize
        _ = writingMode
        return CGRect(
            x: contentInsets.left,
            y: contentInsets.top,
            width: max(1, renderSize.width - contentInsets.left - contentInsets.right),
            height: max(1, renderSize.height - contentInsets.top - contentInsets.bottom)
        )
    }

    static func coreTextContentPathRect(
        renderSize: CGSize,
        contentInsets: UIEdgeInsets,
        fontSize: CGFloat,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        let contentRect = uiContentRect(
            renderSize: renderSize,
            contentInsets: contentInsets,
            fontSize: fontSize,
            writingMode: writingMode
        )
        return CGRect(
            x: contentRect.minX,
            y: contentInsets.bottom,
            width: contentRect.width,
            height: contentRect.height
        )
    }

    /// Orphan and widow control:
    /// - Orphan: last line of the previous page is a paragraph's first line → move to next page
    /// - Widow: first line of the next page is a paragraph's last line → also move the previous page's last line to the next page (ensures ≥2 lines)
    private static func applyOrphanControl(
        framesetter: CTFramesetter,
        pageRanges: inout [CFRange],
        attrStr: NSAttributedString,
        contentPathRect: CGRect,
        writingMode: ReaderWritingMode
    ) {
        guard pageRanges.count > 1 else { return }
        let nsString = attrStr.string as NSString
        let stringLength = attrStr.length
        let pagePath = CGPath(rect: contentPathRect, transform: nil)

        // Pass 1: Orphan — last line of the previous page is a paragraph's first line
        var i = 0
        while i < pageRanges.count - 1 {
            let frame = makeFrame(framesetter: framesetter, range: pageRanges[i], path: pagePath, writingMode: writingMode)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard lines.count >= 2, let lastLine = lines.last else { i += 1; continue }
            let lastRange = CTLineGetStringRange(lastLine)
            let isOrphan: Bool
            if lastRange.location == 0 {
                isOrphan = false
            } else {
                let ch = nsString.character(at: lastRange.location - 1)
                isOrphan = ch == 0x000A || ch == 0x2028 || ch == 0x2029
            }
            if isOrphan {
                let newLen = lastRange.location - pageRanges[i].location
                if newLen > 0 {
                    let nextEnd = pageRanges[i + 1].location + pageRanges[i + 1].length
                    pageRanges[i] = CFRangeMake(pageRanges[i].location, newLen)
                    pageRanges[i + 1] = CFRangeMake(lastRange.location, nextEnd - lastRange.location)
                }
            }
            i += 1
        }

        // Pass 2: Widow — first line of the next page is a paragraph's last line (and that page has ≥2 lines)
        for j in 1..<pageRanges.count {
            guard pageRanges[j].length > 0 else { continue }
            let frame = makeFrame(framesetter: framesetter, range: pageRanges[j], path: pagePath, writingMode: writingMode)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard lines.count >= 2 else { continue }
            let firstRange = CTLineGetStringRange(lines[0])
            let checkIdx = firstRange.location + firstRange.length
            let isWidow = checkIdx >= stringLength
                || nsString.character(at: checkIdx) == 0x000A
                || nsString.character(at: checkIdx) == 0x2028
                || nsString.character(at: checkIdx) == 0x2029
            guard isWidow else { continue }
            // Move the previous page's last line to this page
            let prevFrame = makeFrame(framesetter: framesetter, range: pageRanges[j - 1], path: pagePath, writingMode: writingMode)
            let prevLines = CTFrameGetLines(prevFrame) as! [CTLine]
            guard prevLines.count >= 2, let prevLast = prevLines.last else { continue }
            let prevLastRange = CTLineGetStringRange(prevLast)
            let newPrevLen = prevLastRange.location - pageRanges[j - 1].location
            guard newPrevLen > 0 else { continue }
            let newCurrEnd = pageRanges[j].location + pageRanges[j].length
            pageRanges[j - 1] = CFRangeMake(pageRanges[j - 1].location, newPrevLen)
            pageRanges[j] = CFRangeMake(prevLastRange.location, newCurrEnd - prevLastRange.location)
        }
    }

    /// True when `imageRunRange` is the only visible content on its CTLine — every other character on the
    /// line is whitespace (no text, and no second image). Used to decide whether an inline image should be
    /// centered like a figure rather than flushed to its text-flow position. A line carrying a second image
    /// (its `\u{FFFC}` is not whitespace) is treated as a flowed gallery row and left as-is.
    static func isStandaloneImageRun(
        _ imageRunRange: CFRange,
        line: CTLine,
        attrStr: NSAttributedString
    ) -> Bool {
        let lineRange = CTLineGetStringRange(line)
        let start = max(0, lineRange.location)
        let end = min(attrStr.length, lineRange.location + lineRange.length)
        guard end > start else { return true }
        let ns = attrStr.string as NSString
        var idx = start
        while idx < end {
            if idx >= imageRunRange.location, idx < imageRunRange.location + imageRunRange.length {
                idx += 1
                continue
            }
            let composed = ns.rangeOfComposedCharacterSequence(at: idx)
            let pieceEnd = min(end, composed.location + composed.length)
            let piece = ns.substring(with: NSRange(location: composed.location, length: max(0, pieceEnd - composed.location)))
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            idx = composed.location + composed.length
        }
        return true
    }

    private static func extractImages(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        renderSize: CGSize,
        contentPathRect: CGRect,
        attrStr: NSAttributedString,
        writingMode: ReaderWritingMode,
        floatNotches: [Int: CGRect] = [:]
    ) -> (inline: [Int: [RenderedAttachment]], block: [Int: [RenderedAttachment]], kinds: [PageKind]) {
        var inlineAttachments: [Int: [RenderedAttachment]] = [:]
        var blockAttachments: [Int: [RenderedAttachment]] = [:]
        var kinds = Array(repeating: PageKind.text, count: pageRanges.count)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let isVertical = writingMode.isVertical

        for (pageIdx, range) in pageRanges.enumerated() { autoreleasepool {
            let pagePath = framePath(contentPathRect: contentPathRect, floatNotch: floatNotches[pageIdx])
            let frame = makeFrame(framesetter: framesetter, range: range, path: pagePath, writingMode: writingMode)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

            for (lineIdx, line) in lines.enumerated() {
                let lineOrigin = origins[lineIdx]
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                for run in runs {
                    let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                    guard let delegate = attrs[delegateKey] else { continue }
                    // Skip spacer runs (not image placeholders)
                    guard attrs[HTMLAttributedStringBuilder.spacerRunAttribute] == nil else {
                        if isVertical {
                            let runRange = CTRunGetStringRange(run)
                            let textAdvance = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                            let ctDelegate = delegate as! CTRunDelegate
                            let ptr = CTRunDelegateGetRefCon(ctDelegate)
                            let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                            debugVerticalLog("spacerRun page=\(pageIdx) line=\(lineIdx) loc=\(runRange.location) lineOrigin=\(lineOrigin) textAdvance=\(textAdvance) width=\(info.width) draw=\(info.drawWidth)x\(info.drawHeight) ascent=\(info.ascent) descent=\(info.descent)", verbose: true)
                        }
                        continue
                    }
                    // CTRunDelegate is a CoreFoundation type; unconditional cast is correct
                    let ctDelegate = delegate as! CTRunDelegate
                    let ptr = CTRunDelegateGetRefCon(ctDelegate)
                    let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()

                    let paragraphStyle = attrStr.attribute(
                        .paragraphStyle,
                        at: max(0, CTRunGetStringRange(run).location),
                        effectiveRange: nil
                    ) as? NSParagraphStyle
                    let flush: CGFloat
                    switch paragraphStyle?.alignment ?? .natural {
                    case .center:
                        flush = 0.5
                    case .right:
                        flush = 1
                    default:
                        flush = 0
                    }
                    let penOffset = CGFloat(
                        CTLineGetPenOffsetForFlush(line, Double(flush), Double(contentPathRect.width))
                    )

                    var runAscent: CGFloat = 0
                    var runDescent: CGFloat = 0
                    _ = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &runAscent, &runDescent, nil)
                    var lineAscent: CGFloat = 0
                    var lineDescent: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                    let baselineY = contentPathRect.origin.y + lineOrigin.y
                    let lineHeight = lineAscent + lineDescent
                    let lineBottom = baselineY - lineDescent
                    let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
                    let uiY: CGFloat
                    if info.source == "mathml:", info.displayMode == .inline, !isVertical {
                        uiY = renderSize.height - (baselineY - info.descent) - info.drawHeight
                    } else {
                        uiY = renderSize.height - centeredBottom - info.drawHeight
                    }
                    if let img = info.image {
                        let hasBlockRenderable = attrs[HTMLAttributedStringBuilder.blockRenderStyleAttribute] != nil
                        let rect: CGRect
                        switch info.displayMode {
                        case .inline:
                            if isVertical {
                                // Vertical-rl manual rect. lineOrigin.x is the vertical
                                // baseline (glyph center), not left edge — subtract half
                                // width to center the image on the baseline.
                                let runLocation = CTRunGetStringRange(run).location
                                let textAdvance = CTLineGetOffsetForStringIndex(
                                    line,
                                    runLocation,
                                    nil
                                )
                                let columnBaselineX = contentPathRect.origin.x + lineOrigin.x
                                let lineTypographicCenterX = columnBaselineX + (lineAscent - lineDescent) / 2
                                let uiY = renderSize.height - (contentPathRect.origin.y + lineOrigin.y) + textAdvance
                                rect = CGRect(
                                    x: lineTypographicCenterX - (info.drawWidth / 2),
                                    y: uiY,
                                    width: info.drawWidth,
                                    height: info.drawHeight
                                )
                                let runBounds = CTRunGetImageBounds(run, nil, CFRangeMake(0, 0))
                                var firstRunPosition = CGPoint.zero
                                if CTRunGetGlyphCount(run) > 0 {
                                    CTRunGetPositions(run, CFRangeMake(0, 1), &firstRunPosition)
                                }
                                let coreTextRunBounds = CGRect(
                                    x: contentPathRect.origin.x + lineOrigin.x + runBounds.minX,
                                    y: contentPathRect.origin.y + lineOrigin.y + runBounds.minY,
                                    width: runBounds.width,
                                    height: runBounds.height
                                )
                                debugVerticalLog("imageRun page=\(pageIdx) line=\(lineIdx) loc=\(runLocation) src=\(info.source) alt=\(info.alt ?? "nil") lineOrigin=\(lineOrigin) contentPathRect=\(contentPathRect) columnBaselineX=\(columnBaselineX) lineAscent=\(lineAscent) lineDescent=\(lineDescent) lineTypographicCenterX=\(lineTypographicCenterX) centerMinusBaseline=\(lineTypographicCenterX - columnBaselineX) textAdvance=\(textAdvance) runPosition0=\(firstRunPosition) runImageBounds=\(runBounds) coreTextRunBounds=\(coreTextRunBounds) computedY=\(uiY) draw=\(info.drawWidth)x\(info.drawHeight) ascent=\(info.ascent) descent=\(info.descent) widthAdvance=\(info.width) finalRect=\(rect) midXMinusCenter=\(rect.midX - lineTypographicCenterX)", verbose: true)
                            } else {
                                let runRange = CTRunGetStringRange(run)
                                // A standalone image — alone on its line, e.g. the <img> in
                                // <figure><img/><figcaption/></figure> — reads as a figure and should be
                                // centered in the content box like a block image. Flushing it to the
                                // text-flow position leaves a lopsided right-hand gap (the reported uneven
                                // margins). Images that flow inline with text keep their flow position.
                                // Explicit author alignment (left/right) is honored; the default `.natural`
                                // is treated as "center this figure", matching Apple Books / Readium.
                                if Self.isStandaloneImageRun(runRange, line: line, attrStr: attrStr), !info.isTextSized {
                                    let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
                                    let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
                                    let boxWidth = max(1, contentPathRect.width - leftInset - rightInset)
                                    let occupiedWidth = min(boxWidth, info.width)
                                    let alignedX: CGFloat
                                    switch paragraphStyle?.alignment ?? .natural {
                                    case .left:
                                        alignedX = contentPathRect.origin.x + leftInset
                                    case .right:
                                        alignedX = contentPathRect.origin.x + leftInset + max(0, boxWidth - occupiedWidth)
                                    default: // .natural / .center / .justified → center the figure
                                        alignedX = contentPathRect.origin.x + leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                                    }
                                    rect = CGRect(
                                        x: alignedX + info.paddingLeft,
                                        y: uiY,
                                        width: info.drawWidth,
                                        height: info.drawHeight
                                    )
                                } else {
                                    let textAdvance = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                                    rect = CGRect(
                                        x: contentPathRect.origin.x + lineOrigin.x + penOffset + textAdvance + info.paddingLeft,
                                        y: uiY,
                                        width: info.drawWidth,
                                        height: info.drawHeight
                                    )
                                }
                            }
                        case .block:
                            let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
                            let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
                            let boxWidth = max(1, contentPathRect.width - leftInset - rightInset)
                            let occupiedWidth = min(boxWidth, info.width)
                            let alignedX: CGFloat
                            switch paragraphStyle?.alignment ?? .left {
                            case .center:
                                alignedX = contentPathRect.origin.x + leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                            case .right:
                                alignedX = contentPathRect.origin.x + leftInset + max(0, boxWidth - occupiedWidth)
                            default:
                                alignedX = contentPathRect.origin.x + leftInset
                            }
                            rect = CGRect(
                                x: alignedX + info.paddingLeft,
                                y: uiY,
                                width: info.drawWidth,
                                height: info.drawHeight
                            )
                        }

                        let linkHref = attrs[HTMLAttributedStringBuilder.internalLinkAttribute] as? String
                        let mediaAttachment = attrs[HTMLAttributedStringBuilder.mediaAttachmentAttribute] as? EPUBMediaAttachment
                        let attachment = RenderedAttachment(
                            rect: rect,
                            image: img,
                            opacity: info.opacity,
                            sourceHref: info.source.isEmpty ? nil : info.source,
                            alt: info.alt,
                            linkHref: linkHref?.isEmpty == false ? linkHref : nil,
                            mediaAttachment: mediaAttachment,
                            originalSize: img.size,
                            linkRegions: info.linkRegions,
                            allowsPreview: info.allowsPreview
                        )
                        switch info.displayMode {
                        case .inline:
                            inlineAttachments[pageIdx, default: []].append(attachment)
                        case .block:
                            if !hasBlockRenderable {
                                blockAttachments[pageIdx, default: []].append(attachment)
                            }
                        }
                    }
                }
            }
        } } // end autoreleasepool + for pageIdx

        let visibleContent = attrStr.string.unicodeScalars.filter { scalar in
            scalar != "\u{FFFC}" && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }

        if pageRanges.count == 1,
           visibleContent.isEmpty,
           blockAttachments.count == 1,
           let attachment = blockAttachments[0]?.first {
            // Convert contentPathRect (CoreText coordinates) to UIKit coordinate content area
            let uiContentRect = CGRect(
                x: contentPathRect.origin.x,
                y: renderSize.height - contentPathRect.maxY,
                width: contentPathRect.width,
                height: contentPathRect.height
            )
            let imageRect = aspectFitRect(for: attachment.image.size, in: uiContentRect)
            blockAttachments[0] = [RenderedAttachment(
                rect: imageRect,
                image: attachment.image,
                opacity: attachment.opacity,
                sourceHref: attachment.sourceHref,
                alt: attachment.alt,
                linkHref: attachment.linkHref,
                mediaAttachment: attachment.mediaAttachment,
                originalSize: attachment.originalSize,
                linkRegions: attachment.linkRegions,
                allowsPreview: attachment.allowsPreview
            )]
            kinds[0] = .image
        }

        return (inlineAttachments, blockAttachments, kinds)
    }

    private static func extractInlineAnnotations(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        renderSize: CGSize,
        contentPathRect: CGRect,
        writingMode: ReaderWritingMode,
        floatNotches: [Int: CGRect] = [:]
    ) -> [Int: [RenderedInlineAnnotation]] {
        // Inline annotations are a vertical-writing feature; CSS floats are horizontal-only, so the notch
        // map is irrelevant here and the rectangular path is correct.
        _ = floatNotches
        guard writingMode.isVertical else { return [:] }
        let pagePath = CGPath(rect: contentPathRect, transform: nil)
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var annotations: [Int: [RenderedInlineAnnotation]] = [:]

        for (pageIdx, range) in pageRanges.enumerated() {
            let frame = makeFrame(
                framesetter: framesetter,
                range: range,
                path: pagePath,
                writingMode: writingMode
            )
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

            for (lineIdx, line) in lines.enumerated() {
                let lineOrigin = origins[lineIdx]
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                for run in runs {
                    let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                    guard attrs[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] != nil,
                          let delegate = attrs[delegateKey]
                    else { continue }

                    let ctDelegate = delegate as! CTRunDelegate
                    let ptr = CTRunDelegateGetRefCon(ctDelegate)
                    let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                    guard let annotation = info as? InlineAnnotationRunInfo else { continue }

                    let runLocation = CTRunGetStringRange(run).location
                    let textAdvance = CTLineGetOffsetForStringIndex(line, runLocation, nil)
                    var lineAscent: CGFloat = 0
                    var lineDescent: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                    let baselineX = contentPathRect.origin.x + lineOrigin.x
                    let typographicCenterX = baselineX + (lineAscent - lineDescent) / 2
                    let uiRect = CGRect(
                        x: typographicCenterX - (annotation.drawWidth / 2),
                        y: renderSize.height - (contentPathRect.origin.y + lineOrigin.y) + textAdvance,
                        width: annotation.drawWidth,
                        height: annotation.drawHeight
                    )
                    let isOversized = annotation.drawHeight > contentPathRect.height
                    debugVerticalLog("annotationRun page=\(pageIdx) line=\(lineIdx) loc=\(runLocation) lineOrigin=\(lineOrigin) textAdvance=\(textAdvance) baselineX=\(baselineX) lineAscent=\(lineAscent) lineDescent=\(lineDescent) centerX=\(typographicCenterX) uiRect=\(uiRect) annWidth=\(annotation.width) draw=\(annotation.drawWidth)x\(annotation.drawHeight) text=\"\(debugTextPreview(annotation.attributedString.string, limit: 80))\"", verbose: !isOversized)
                    annotations[pageIdx, default: []].append(RenderedInlineAnnotation(
                        uiRect: uiRect,
                        attributedString: annotation.attributedString
                    ))
                }
            }
        }

        return annotations
    }

    private static func extractBlockRenderables(
        framesetter: CTFramesetter,
        pageRanges: [CFRange],
        contentPathRect: CGRect,
        renderSize: CGSize,
        attrStr: NSAttributedString,
        writingMode: ReaderWritingMode,
        floatNotches: [Int: CGRect] = [:]
    ) -> [Int: [RenderedBlockRenderable]] {
        var pageRenderables: [Int: [RenderedBlockRenderable]] = [:]

        for (pageIdx, range) in pageRanges.enumerated() { autoreleasepool {
            let pagePath = framePath(contentPathRect: contentPathRect, floatNotch: floatNotches[pageIdx])
            let frame = makeFrame(framesetter: framesetter, range: range, path: pagePath, writingMode: writingMode)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            guard !lines.isEmpty else { return }

            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

            struct DecorationGroup {
                let blockID: String
                let style: HTMLAttributedStringBuilder.BlockRenderStyle
                let ranges: [NSRange]
                var rect: CGRect
                var usesExplicitGeometry: Bool
                let layer: Int

                var isContainer: Bool {
                    layer > 0
                }
            }

            struct SpanGroup {
                let blockID: String
                let style: HTMLAttributedStringBuilder.BlockRenderStyle
                var ranges: [NSRange]
                let layer: Int
            }

            var spanGroupsByID: [String: SpanGroup] = [:]
            let pageNSRange = NSRange(location: range.location, length: range.length)
            func collectSpanGroups(
                styleKey: NSAttributedString.Key,
                idKey: NSAttributedString.Key,
                layer: Int
            ) {
                attrStr.enumerateAttribute(styleKey, in: pageNSRange, options: []) { value, effectiveRange, _ in
                    guard let renderStyle = value as? HTMLAttributedStringBuilder.BlockRenderStyle,
                          let blockID = attrStr.attribute(
                              idKey,
                              at: effectiveRange.location,
                              effectiveRange: nil
                          ) as? String
                    else { return }
                    if var existing = spanGroupsByID[blockID] {
                        existing.ranges.append(effectiveRange)
                        spanGroupsByID[blockID] = existing
                    } else {
                        spanGroupsByID[blockID] = SpanGroup(
                            blockID: blockID,
                            style: renderStyle,
                            ranges: [effectiveRange],
                            layer: layer
                        )
                    }
                }
            }

            collectSpanGroups(
                styleKey: HTMLAttributedStringBuilder.outerContainerBlockRenderStyleAttribute,
                idKey: HTMLAttributedStringBuilder.outerContainerBlockRenderIDAttribute,
                layer: 2
            )
            collectSpanGroups(
                styleKey: HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
                idKey: HTMLAttributedStringBuilder.containerBlockRenderIDAttribute,
                layer: 1
            )
            collectSpanGroups(
                styleKey: HTMLAttributedStringBuilder.blockRenderStyleAttribute,
                idKey: HTMLAttributedStringBuilder.blockRenderIDAttribute,
                layer: 0
            )

            var groups: [DecorationGroup] = spanGroupsByID.values.map {
                DecorationGroup(
                    blockID: $0.blockID,
                    style: $0.style,
                    ranges: $0.ranges,
                    rect: .null,
                    usesExplicitGeometry: false,
                    layer: $0.layer
                )
            }
            guard !groups.isEmpty else { return }

            for groupIndex in groups.indices {
                // Container decorations wrap already-flowed children; their Y must come from line origins.
                guard !groups[groupIndex].isContainer else { continue }
                if let explicitRect = computeExplicitBlockRenderableRect(
                    style: groups[groupIndex].style,
                    ranges: groups[groupIndex].ranges,
                    attrStr: attrStr,
                    contentPathRect: contentPathRect,
                    renderSize: renderSize
                ) {
                    groups[groupIndex].rect = explicitRect
                    groups[groupIndex].usesExplicitGeometry = true
                }
            }

            for (lineIdx, line) in lines.enumerated() {
                let lineRange = CTLineGetStringRange(line)
                let lineStart = lineRange.location
                guard lineStart < attrStr.length else { continue }

                let lineNSRange = NSRange(location: lineRange.location, length: lineRange.length)

                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                var lineWidth: CGFloat = 0
                lineWidth = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)

                let lineOrigin = origins[lineIdx]
                let adjustedOrigin = CGPoint(
                    x: lineOrigin.x + contentPathRect.minX,
                    y: lineOrigin.y + contentPathRect.minY
                )

                for groupIndex in groups.indices {
                    if groups[groupIndex].usesExplicitGeometry {
                        continue
                    }
                    let intersects = groups[groupIndex].ranges.contains { span in
                        NSIntersectionRange(span, lineNSRange).length > 0
                    }
                    guard intersects else { continue }

                    let standaloneImageRect = standaloneImageRenderableRect(
                        line: line,
                        lineOrigin: lineOrigin,
                        contentPathRect: contentPathRect,
                        renderSize: renderSize,
                        attrStr: attrStr,
                        ranges: groups[groupIndex].ranges,
                        writingMode: writingMode
                    )

                    let attributeLocation = max(
                        lineStart,
                        groups[groupIndex].ranges
                            .compactMap { span -> Int? in
                                let intersection = NSIntersectionRange(span, lineNSRange)
                                return intersection.length > 0 ? intersection.location : nil
                            }
                            .min() ?? lineStart
                    )
                    guard let paragraphStyle = attrStr.attribute(
                        .paragraphStyle,
                        at: attributeLocation,
                        effectiveRange: nil
                    ) as? NSParagraphStyle else { continue }

                    let leftInset = min(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
                    let rightInset = paragraphStyle.tailIndent < 0 ? -paragraphStyle.tailIndent : 0
                    let availableWidth = max(1, contentPathRect.width - leftInset - rightInset)
                    let preferredWidth = max(
                        1,
                        min(
                            availableWidth,
                            groups[groupIndex].style.blockImage.map { $0.drawSize.width + $0.paddingLeft + $0.paddingRight }
                                ?? groups[groupIndex].style.width
                                ?? availableWidth
                        )
                    )
                    let blockX: CGFloat
                    if groups[groupIndex].style.isHorizontallyCentered {
                        blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
                    } else {
                        switch groups[groupIndex].style.textAlign {
                        case .center:
                            blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
                        case .right:
                            blockX = contentPathRect.minX + leftInset + max(0, availableWidth - preferredWidth)
                        default:
                            blockX = contentPathRect.minX + leftInset
                        }
                    }
                    let lineHeight: CGFloat
                    let blockHeight: CGFloat
                    let uiY: CGFloat
                    let rectX: CGFloat
                    let rectW: CGFloat
                    if writingMode.isVertical {
                        // blockImage.drawSize: .width = physical width (X), .height = physical height (Y)
                        // lineWidth = inline (Y) extent; ascent/descent = block (X) extent
                        let blockExtent = lineAscent + abs(lineDescent)
                        lineHeight = lineWidth
                        blockHeight = max(
                            lineWidth,
                            groups[groupIndex].style.blockImage?.drawSize.height
                                ?? groups[groupIndex].style.height
                                ?? lineWidth
                        )
                        rectW = max(preferredWidth,
                            groups[groupIndex].style.blockImage?.drawSize.width
                            ?? blockExtent)
                        rectX = adjustedOrigin.x - rectW / 2   // center on column baseline
                        uiY = renderSize.height - adjustedOrigin.y
                    } else if let standaloneImageRect {
                        lineHeight = standaloneImageRect.height
                        blockHeight = standaloneImageRect.height
                        rectX = standaloneImageRect.minX
                        rectW = min(standaloneImageRect.width, preferredWidth)
                        uiY = standaloneImageRect.minY
                    } else {
                        lineHeight = max(paragraphStyle.minimumLineHeight, lineAscent + lineDescent)
                        blockHeight = max(
                            lineHeight,
                            groups[groupIndex].style.blockImage?.drawSize.height
                                ?? groups[groupIndex].style.height
                                ?? lineHeight
                        )
                        if groups[groupIndex].style.hugsContent {
                            // Shrink-to-fit bubble: size the box to the line's actual glyph run so
                            // it hugs the text exactly, immune to column-width rounding (a right
                            // float otherwise drifts a few points and clips its last glyph).
                            rectX = adjustedOrigin.x
                            rectW = max(1, lineWidth)
                        } else {
                            rectX = blockX
                            rectW = preferredWidth
                        }
                        uiY = renderSize.height - (adjustedOrigin.y + lineAscent)
                    }
                    let rect = CGRect(
                        x: rectX,
                        y: uiY,
                        width: rectW,
                        height: blockHeight
                    )

                    groups[groupIndex].rect = groups[groupIndex].rect.isNull
                        ? rect
                        : groups[groupIndex].rect.union(rect)
                }
            }

            let renderables = groups
                .filter { !$0.rect.isNull }
                .sorted { lhs, rhs in
                    if lhs.layer != rhs.layer { return lhs.layer > rhs.layer }
                    if lhs.rect.minY != rhs.rect.minY { return lhs.rect.minY < rhs.rect.minY }
                    return lhs.rect.minX < rhs.rect.minX
                }
                .map { group -> RenderedBlockRenderable in
                    let renderRect = blockDecorationRect(
                        from: group.rect,
                        style: group.style,
                        isContainer: group.isContainer,
                        writingMode: writingMode
                    )
                    // Container groups only render decoration (border/background), don't take over text rendering
                    let text: NSAttributedString? = (group.isContainer || !group.usesExplicitGeometry) ? nil : explicitRenderableText(
                        style: group.style,
                        ranges: group.ranges,
                        attrStr: attrStr,
                        explicitRect: renderRect
                    )
                    return RenderedBlockRenderable(
                        rect: renderRect,
                        style: group.style,
                        attributedText: text,
                        sourceRanges: text != nil ? group.ranges : [],
                        imageAttachment: makeBlockImageAttachment(
                            rect: renderRect,
                            style: group.style,
                            ranges: group.ranges,
                            attrStr: attrStr,
                            isVertical: writingMode.isVertical
                        )
                    )
                }
            if !renderables.isEmpty {
                pageRenderables[pageIdx] = renderables
            }
        } } // end autoreleasepool + for pageIdx

        return pageRenderables
    }

    private static func blockDecorationRect(
        from rect: CGRect,
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        isContainer: Bool,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        guard isContainer,
              !style.hugsContent,
              !writingMode.isVertical,
              !rect.isNull
        else { return rect }

        // reserveContainerBlockInsets already folded paragraphSpacingBefore + paddingTop +
        // borderTopWidth into the first child's paragraphSpacingBefore, which pushes the
        // child down and makes the container's union rect encompass the reserved space.
        // Trimming paragraphSpacingBefore here would double-count and pull the decoration
        // rect downward, misaligning the border with the content inside.
        guard style.borderTopWidth == 0, style.borderBottomWidth == 0,
              style.paddingTop == 0, style.paddingBottom == 0
        else { return rect }

        let topMargin = max(0, style.paragraphSpacingBefore)
        guard topMargin > 0 else { return rect }

        let consumedTop = min(topMargin, max(0, rect.height - 1))
        return CGRect(
            x: rect.minX,
            y: rect.minY + consumedTop,
            width: rect.width,
            height: max(1, rect.height - consumedTop)
        )
    }

    private static func standaloneImageRenderableRect(
        line: CTLine,
        lineOrigin: CGPoint,
        contentPathRect: CGRect,
        renderSize: CGSize,
        attrStr: NSAttributedString,
        ranges: [NSRange],
        writingMode: ReaderWritingMode
    ) -> CGRect? {
        guard !writingMode.isVertical else { return nil }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var union = CGRect.null

        for run in runs {
            let runRange = CTRunGetStringRange(run)
            let runNSRange = NSRange(location: runRange.location, length: runRange.length)
            let belongsToGroup = ranges.contains { NSIntersectionRange($0, runNSRange).length > 0 }
            guard belongsToGroup else { continue }

            let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            guard attrs[HTMLAttributedStringBuilder.spacerRunAttribute] == nil,
                  let delegate = attrs[delegateKey]
            else { continue }

            let ctDelegate = delegate as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(ctDelegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            guard info.image != nil,
                  !info.isTextSized,
                  isStandaloneImageRun(runRange, line: line, attrStr: attrStr)
            else { continue }

            let paragraphStyle = attrStr.attribute(
                .paragraphStyle,
                at: max(0, runRange.location),
                effectiveRange: nil
            ) as? NSParagraphStyle
            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
            let baselineY = contentPathRect.origin.y + lineOrigin.y
            let lineHeight = lineAscent + lineDescent
            let lineBottom = baselineY - lineDescent
            let centeredBottom = lineBottom + max(0, (lineHeight - info.drawHeight) / 2)
            let uiY = renderSize.height - centeredBottom - info.drawHeight

            let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
            let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
            let boxWidth = max(1, contentPathRect.width - leftInset - rightInset)
            let occupiedWidth = min(boxWidth, info.width)
            let alignedX: CGFloat
            switch info.displayMode {
            case .inline:
                switch paragraphStyle?.alignment ?? .natural {
                case .left:
                    alignedX = contentPathRect.origin.x + leftInset
                case .right:
                    alignedX = contentPathRect.origin.x + leftInset + max(0, boxWidth - occupiedWidth)
                default:
                    alignedX = contentPathRect.origin.x + leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                }
            case .block:
                switch paragraphStyle?.alignment ?? .left {
                case .center:
                    alignedX = contentPathRect.origin.x + leftInset + max(0, (boxWidth - occupiedWidth) / 2)
                case .right:
                    alignedX = contentPathRect.origin.x + leftInset + max(0, boxWidth - occupiedWidth)
                default:
                    alignedX = contentPathRect.origin.x + leftInset
                }
            }

            let rect = CGRect(
                x: alignedX + info.paddingLeft,
                y: uiY,
                width: info.drawWidth,
                height: info.drawHeight
            )
            union = union.isNull ? rect : union.union(rect)
        }

        return union.isNull ? nil : union
    }

    private static func computeExplicitBlockRenderableRect(
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString,
        contentPathRect: CGRect,
        renderSize: CGSize
    ) -> CGRect? {
        let mergedRange = mergeRanges(ranges)
        let mergedText: String
        if let mergedRange, mergedRange.location < attrStr.length {
            mergedText = (attrStr.string as NSString).substring(with: mergedRange)
        } else {
            mergedText = ""
        }
        let hasMeaningfulText = containsMeaningfulText(mergedText)
        let hasVisualDecoration =
            style.backgroundFillColor != nil
            || style.borderTopWidth > 0
            || style.borderBottomWidth > 0
            || style.blockImage != nil
        let hasExplicitGeometryHint =
            style.height != nil
            || style.blockImage != nil
            || (style.width != nil && style.isHorizontallyCentered)
        let usesExplicitGeometry =
            hasVisualDecoration
            && hasExplicitGeometryHint
            && (hasMeaningfulText || style.blockImage == nil)
        guard usesExplicitGeometry else { return nil }

        guard let mergedRange,
              mergedRange.location < attrStr.length
        else {
            return nil
        }

        let paragraphStyle = attrStr.attribute(
            .paragraphStyle,
            at: mergedRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle

        let leftInset = min(paragraphStyle?.headIndent ?? 0, paragraphStyle?.firstLineHeadIndent ?? 0)
        let rightInset = (paragraphStyle?.tailIndent ?? 0) < 0 ? -(paragraphStyle?.tailIndent ?? 0) : 0
        let availableWidth = max(1, contentPathRect.width - leftInset - rightInset)
        let preferredWidth = max(
            1,
            min(
                availableWidth,
                style.blockImage.map { $0.drawSize.width + $0.paddingLeft + $0.paddingRight }
                    ?? style.width
                    ?? availableWidth
            )
        )

        let blockX: CGFloat
        if style.isHorizontallyCentered {
            blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
        } else {
            switch style.textAlign {
            case .center:
                blockX = contentPathRect.minX + leftInset + max(0, (availableWidth - preferredWidth) / 2)
            case .right:
                blockX = contentPathRect.minX + leftInset + max(0, availableWidth - preferredWidth)
            default:
                blockX = contentPathRect.minX + leftInset
            }
        }

        let constrainedWidth = max(1, preferredWidth)
        let blockHeight: CGFloat
        if let blockImage = style.blockImage {
            blockHeight = max(blockImage.drawSize.height, style.height ?? 0)
        } else {
            let measured = measureHeight(
                for: attrStr.attributedSubstring(from: mergedRange),
                constrainedWidth: constrainedWidth
            )
            blockHeight = max(measured, style.height ?? 0)
        }

        let uiTop = (renderSize.height - contentPathRect.maxY) + style.visualOffsetBefore
        let blockRect = CGRect(
            x: blockX,
            y: uiTop,
            width: preferredWidth,
            height: max(1, blockHeight)
        )
        return blockRect
    }

    private static func makeBlockImageAttachment(
        rect: CGRect,
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString,
        isVertical: Bool = false
    ) -> RenderedAttachment? {
        guard let blockImage = style.blockImage,
              let image = blockImage.image
        else {
            return nil
        }

        var sourceHref = blockImage.source.isEmpty ? nil : blockImage.source
        var alt: String?
        var linkHref: String?
        var mediaAttachment: EPUBMediaAttachment?
        var linkRegions: [ImageLinkRegion] = []
        var allowsPreview = true
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)

        for range in ranges {
            let safeLocation = max(0, min(range.location, attrStr.length))
            let safeEnd = max(safeLocation, min(range.location + range.length, attrStr.length))
            guard safeEnd > safeLocation else { continue }
            let safeRange = NSRange(location: safeLocation, length: safeEnd - safeLocation)
            attrStr.enumerateAttribute(delegateKey, in: safeRange, options: []) { value, effectiveRange, stop in
                guard let delegate = value else { return }
                // Skip spacer runs (not image placeholders)
                guard attrStr.attribute(HTMLAttributedStringBuilder.spacerRunAttribute, at: effectiveRange.location, effectiveRange: nil) == nil else { return }
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                if !info.source.isEmpty {
                    sourceHref = info.source
                }
                alt = info.alt
                linkRegions = info.linkRegions
                allowsPreview = info.allowsPreview
                if let href = attrStr.attribute(
                    HTMLAttributedStringBuilder.internalLinkAttribute,
                    at: effectiveRange.location,
                    effectiveRange: nil
                ) as? String,
                   !href.isEmpty {
                    linkHref = href
                }
                mediaAttachment = attrStr.attribute(
                    HTMLAttributedStringBuilder.mediaAttachmentAttribute,
                    at: effectiveRange.location,
                    effectiveRange: nil
                ) as? EPUBMediaAttachment
                stop.pointee = true
            }
            if sourceHref != nil || alt != nil || linkHref != nil || mediaAttachment != nil
                || !linkRegions.isEmpty || !allowsPreview {
                break
            }
        }

        let imageRect = blockImageRect(in: rect, blockImage: blockImage, isVertical: isVertical)
        return RenderedAttachment(
            rect: imageRect,
            image: image,
            opacity: blockImage.opacity,
            sourceHref: sourceHref,
            alt: alt,
            linkHref: linkHref,
            mediaAttachment: mediaAttachment,
            originalSize: image.size,
            linkRegions: linkRegions,
            allowsPreview: allowsPreview
        )
    }

    static func blockImageRect(
        in availableRect: CGRect,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage,
        isVertical: Bool = false
    ) -> CGRect {
        let contentWidth = max(1, availableRect.width - blockImage.paddingLeft - blockImage.paddingRight)
        let drawWidth = min(blockImage.drawSize.width, contentWidth)
        // When the image is wider than the content column it gets clamped to `contentWidth`;
        // scale the height by the SAME factor so the aspect ratio is preserved (otherwise a
        // wide banner sized for the full screen width gets squished vertically in the column).
        let widthScale = blockImage.drawSize.width > 0 ? drawWidth / blockImage.drawSize.width : 1
        let drawHeight = blockImage.drawSize.height * widthScale
        let imgX: CGFloat
        if isVertical {
            imgX = availableRect.minX + max(0, (availableRect.width - drawWidth) / 2)
        } else {
            switch blockImage.alignment {
            case .center:
                imgX = availableRect.minX + blockImage.paddingLeft + max(0, (contentWidth - drawWidth) / 2)
            case .right:
                imgX = availableRect.minX + blockImage.paddingLeft + max(0, contentWidth - drawWidth)
            default:
                imgX = availableRect.minX + blockImage.paddingLeft
            }
        }
        let contentY = availableRect.minY + blockImage.paddingTop
        let contentHeight = max(1, availableRect.height - blockImage.paddingTop - blockImage.paddingBottom)
        let imgY = contentY + max(0, (contentHeight - drawHeight) / 2)
        return CGRect(x: imgX, y: imgY, width: drawWidth, height: drawHeight)
    }

    private static func explicitRenderableText(
        style: HTMLAttributedStringBuilder.BlockRenderStyle,
        ranges: [NSRange],
        attrStr: NSAttributedString,
        explicitRect: CGRect
    ) -> NSAttributedString? {
        guard !explicitRect.isNull,
              let mergedRange = mergeRanges(ranges),
              mergedRange.location < attrStr.length
        else {
            return nil
        }

        let text = NSMutableAttributedString(attributedString: attrStr.attributedSubstring(from: mergedRange))
        while text.length > 0 {
            let last = (text.string as NSString).character(at: text.length - 1)
            if last == 0x000A || last == 0x2028 || last == 0x2029 {
                text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
            } else {
                break
            }
        }

        guard containsMeaningfulText(text.string) else {
            return nil
        }

        let sanitized = NSMutableAttributedString(string: text.string)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var filtered: [NSAttributedString.Key: Any] = [:]
            for key in [
                NSAttributedString.Key.font,
                .foregroundColor,
                .kern,
                .baselineOffset,
                .underlineStyle,
                .underlineColor,
                .strikethroughStyle,
                .strikethroughColor,
                .paragraphStyle,
            ] {
                if let value = attributes[key] {
                    filtered[key] = value
                }
            }
            sanitized.setAttributes(filtered, range: range)
        }

        sanitized.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: sanitized.length)) { value, range, _ in
            guard let paragraphStyle = value as? NSParagraphStyle else { return }
            let normalized = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            normalized.paragraphSpacingBefore = 0
            normalized.paragraphSpacing = 0
            normalized.firstLineHeadIndent = 0
            normalized.headIndent = 0
            normalized.tailIndent = 0
            if style.isHorizontallyCentered {
                normalized.alignment = .center
            }
            sanitized.addAttribute(.paragraphStyle, value: normalized, range: range)
        }

        let hasExplicitTextGeometry =
            style.width != nil
            || style.isHorizontallyCentered
            || style.height != nil
        return hasExplicitTextGeometry ? sanitized : nil
    }

    private static func containsMeaningfulText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFFFC, 0x2028, 0x2029, 0x00A0:
                continue
            default:
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return true
        }
        return false
    }

    private static func mergeRanges(_ ranges: [NSRange]) -> NSRange? {
        guard let first = ranges.min(by: { $0.location < $1.location }) else { return nil }
        var lower = first.location
        var upper = first.location + first.length
        for range in ranges.dropFirst() {
            lower = min(lower, range.location)
            upper = max(upper, range.location + range.length)
        }
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private static func measureHeight(for attributedString: NSAttributedString, constrainedWidth: CGFloat) -> CGFloat {
        guard attributedString.length > 0 else { return 0 }
        let framesetter = CoreTextFramesetterFactory.make(for: attributedString)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attributedString.length),
            nil,
            CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(size.height)
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

}

// MARK: - Binary Search Extension

extension CoreTextPaginator.ChapterLayout {
    /// Given a UTF-16 charOffset, performs a binary search for the corresponding page index (O(log n))
    func pageIndex(for charOffset: Int) -> Int {
        guard !pageRanges.isEmpty else { return 0 }
        var lo = 0
        var hi = pageRanges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pageRanges[mid].location <= charOffset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}
