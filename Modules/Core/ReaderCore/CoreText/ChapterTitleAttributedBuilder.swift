import UIKit

/// Builds the in-content chapter-title run(s) from a `ChapterTitleStyle` and
/// appends them to the chapter's attributed string. Shared by the paged/scroll
/// TXT builder and the online builder so alignment / weight / two-line split
/// behave identically on both. The EPUB `<h1>` path does NOT use this — it keeps
/// its own CSS-driven heading rendering.
enum ChapterTitleAttributedBuilder {
    static let designRenderPlanAttribute = NSAttributedString.Key("YDChapterTitleRenderPlan")

    /// Appends the title (nothing if hidden/empty; one or two lines otherwise).
    /// When advanced styling is enabled, a structured design is compiled into
    /// a CoreText render-plan marker. Only unmigrated `legacySource` values use
    /// the former HTML/CSS IR path.
    /// - Parameters:
    ///   - title: raw chapter title (e.g. "第一章 初入江湖").
    ///   - style: the resolved chapter-title style.
    ///   - settings: full render settings; the CSS path derives line metrics
    ///     and writing mode from them so the template matches the body.
    ///   - renderWidth: content width the title block lays out in (CSS path).
    ///   - themeTextColor: current theme text color.
    ///   - themeBackgroundColor: current theme background; picks the light or
    ///     dark template on the CSS path.
    ///   - letterSpacing: reader letter spacing, applied as `.kern` for parity
    ///     with the body text.
    ///   - attr: destination; title runs are appended in order.
    static func append(
        title: String,
        style: ChapterTitleStyle,
        settings: ReaderRenderSettings,
        renderWidth: CGFloat,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor,
        letterSpacing: CGFloat,
        to attr: NSMutableAttributedString
    ) async {
        guard style.visible else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if style.advancedCSSEnabled {
            guard let design = style.design else {
                AppLogger.render("chapterTitle structured design missing; title block omitted")
                return
            }

            if design.layers.isEmpty, let legacySource = design.legacySource {
                // Compatibility path for settings decoded before the structured
                // HTML codec migrated `legacySource`. Delete this branch once
                // decode/import always persists at least one converted layer.
                // A migrated design may retain its source for audit/export;
                // non-empty layers remain the authoritative render model.
                let template = themeBackgroundColor.yd_isDark
                    ? legacySource.dark
                    : legacySource.light
                let t0 = CFAbsoluteTimeGetCurrent()
                let rendered = await renderLegacyAdvancedCSS(
                    rawTitle: trimmed,
                    template: template,
                    style: style,
                    settings: settings,
                    renderWidth: renderWidth,
                    themeTextColor: themeTextColor,
                    themeBackgroundColor: themeBackgroundColor
                )
                AppLogger.render(
                    "⟐ title.css.legacy render ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))"
                        + " ok=\(rendered != nil) len=\(rendered?.length ?? 0)"
                )
                guard let rendered else {
                    AppLogger.render("chapterTitle legacySource render failed; title block omitted")
                    return
                }
                let titleBlock = NSMutableAttributedString(attributedString: rendered)
                applyBottomSpacing(style.bottomSpacing, to: titleBlock)
                if style.topSpacing > 0 {
                    attr.append(spacerLine(height: style.topSpacing))
                }
                attr.append(titleBlock)
                return
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let titleBlock = try await compileDesignBlock(
                    title: trimmed,
                    design: design,
                    appearance: themeBackgroundColor.yd_isDark ? .dark : .light,
                    writingMode: settings.writingMode,
                    renderWidth: renderWidth,
                    bottomSpacing: style.bottomSpacing,
                    assetStore: .shared
                )
                if style.topSpacing > 0 {
                    attr.append(spacerLine(height: style.topSpacing))
                }
                attr.append(titleBlock)
                AppLogger.render(
                    "⟐ title.design compile ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))"
                        + " ok=true len=\(titleBlock.length)"
                )
                return
            } catch {
                // Rendering never guesses a second representation. The same
                // throwing helper is used by editor/apply validation so this
                // error can be surfaced before the design becomes active.
                AppLogger.render(
                    "chapterTitle structured design compile failed; title block omitted error=\(error)"
                )
                return
            }
        }

        appendPlainLines(
            trimmedTitle: trimmed,
            style: style,
            themeTextColor: themeTextColor,
            letterSpacing: letterSpacing,
            to: attr
        )
    }

    /// Validates and compiles a structured title into the transparent source
    /// marker consumed by the paginator. Editor/apply code calls this throwing
    /// API directly; the legacy non-throwing builder entry point logs and omits
    /// an invalid block instead of silently degrading to a different layout.
    static func compileDesignBlock(
        title: String,
        design: ChapterTitleDesign,
        appearance: ReaderStyleAppearance,
        writingMode: ReaderWritingMode,
        renderWidth: CGFloat,
        bottomSpacing: CGFloat,
        assetStore: ReaderStyleAssetStore
    ) async throws -> NSAttributedString {
        let plan = try await ChapterTitleDesignRenderer.compile(
            title: title,
            design: design,
            appearance: appearance,
            writingMode: writingMode,
            renderWidth: renderWidth,
            assetStore: assetStore
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = plan.canvasSize.height
        paragraph.maximumLineHeight = plan.canvasSize.height
        paragraph.paragraphSpacing = max(bottomSpacing, 0)
        let marker = NSMutableAttributedString(
            string: title + "\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 1),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: paragraph,
            ]
        )
        marker.addAttribute(
            designRenderPlanAttribute,
            value: plan,
            range: NSRange(location: 0, length: marker.length)
        )
        return marker
    }

    /// Adds reader-controlled body separation to the template's final visible paragraph while
    /// retaining any margin authored by the template itself.
    static func applyBottomSpacing(
        _ spacing: CGFloat,
        to attributedString: NSMutableAttributedString
    ) {
        guard spacing > 0, attributedString.length > 0 else { return }
        let text = attributedString.string as NSString
        var lastVisibleIndex = attributedString.length - 1
        while lastVisibleIndex >= 0 {
            let scalar = text.character(at: lastVisibleIndex)
            let isWhitespace = UnicodeScalar(scalar).map {
                CharacterSet.whitespacesAndNewlines.contains($0)
            } ?? false
            if !isWhitespace { break }
            lastVisibleIndex -= 1
        }
        guard lastVisibleIndex >= 0 else { return }

        let paragraphRange = text.paragraphRange(
            for: NSRange(location: lastVisibleIndex, length: 0)
        )
        let existing = attributedString.attribute(
            .paragraphStyle,
            at: lastVisibleIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let paragraph = (existing?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing += spacing
        attributedString.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: paragraphRange
        )
    }

    // MARK: - Plain (non-CSS) layout

    private static func appendPlainLines(
        trimmedTitle: String,
        style: ChapterTitleStyle,
        themeTextColor: UIColor,
        letterSpacing: CGFloat,
        to attr: NSMutableAttributedString
    ) {
        // 上距 (top spacing): CoreText ignores `paragraphSpacingBefore` on the
        // first paragraph of a frame — the chapter title is exactly that first
        // paragraph — so a fixed-height spacer line carries the top spacing
        // instead (same technique as the EPUB heading path). This is why the TXT
        // / online "標題上距" setting now actually takes effect.
        if style.topSpacing > 0 {
            attr.append(spacerLine(height: style.topSpacing))
        }

        let alignment = style.alignment.nsTextAlignment
        let (number, name): (String?, String) = style.splitEnabled
            ? ChapterTitleSplitter.split(trimmedTitle)
            : (nil, trimmedTitle)

        if let number {
            // Two lines: a small number line and the large name line. The gap
            // between them is a fraction of the name size so they read as one
            // title; the name line carries 與正文間距 (bottom spacing).
            let numberSize = max(1, style.size * style.numberRelativeSize)
            appendLine(
                number,
                font: UserReaderFontResolver.titleFont(
                    size: numberSize, weight: style.weight, postScriptName: style.numberFontName()
                ),
                isBoldRequested: style.weight.uiFontWeight.rawValue >= UIFont.Weight.semibold.rawValue,
                alignment: alignment,
                paragraphSpacing: style.size * 0.1,
                color: themeTextColor,
                letterSpacing: letterSpacing,
                to: attr
            )
            appendLine(
                name,
                font: UserReaderFontResolver.titleFont(
                    size: style.size, weight: style.weight, postScriptName: style.nameFontName()
                ),
                isBoldRequested: style.weight.uiFontWeight.rawValue >= UIFont.Weight.semibold.rawValue,
                alignment: alignment,
                paragraphSpacing: style.bottomSpacing,
                color: themeTextColor,
                letterSpacing: letterSpacing,
                to: attr
            )
        } else {
            appendLine(
                name,
                font: UserReaderFontResolver.titleFont(
                    size: style.size, weight: style.weight, postScriptName: style.nameFontName()
                ),
                isBoldRequested: style.weight.uiFontWeight.rawValue >= UIFont.Weight.semibold.rawValue,
                alignment: alignment,
                paragraphSpacing: style.bottomSpacing,
                color: themeTextColor,
                letterSpacing: letterSpacing,
                to: attr
            )
        }
    }

    private static func appendLine(
        _ text: String,
        font: UIFont,
        isBoldRequested: Bool,
        alignment: NSTextAlignment,
        paragraphSpacing: CGFloat,
        color: UIColor,
        letterSpacing: CGFloat,
        to attr: NSMutableAttributedString
    ) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.paragraphSpacing = paragraphSpacing
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
            .kern: letterSpacing as NSNumber,
        ]
        attributes.merge(
            UserReaderFontResolver.syntheticBoldAttributes(
                for: font,
                isBoldRequested: isBoldRequested
            )
        ) { _, new in new }
        attr.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }

    // MARK: - Advanced CSS layout

    /// Substitutes `{number}` / `{name}` into the light/dark template and renders
    /// it through the same IR pipeline as online HTML chapters (HTML → styled
    /// AST → RenderableNode → attributed string), so template CSS behaves
    /// exactly like book content. Returns nil when the template yields nothing.
    private static func renderLegacyAdvancedCSS(
        rawTitle: String,
        template: String,
        style: ChapterTitleStyle,
        settings: ReaderRenderSettings,
        renderWidth: CGFloat,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> NSAttributedString? {
        let (number, name) = ChapterTitleSplitter.split(rawTitle)
        let html = template
            .replacingOccurrences(of: "{number}", with: ReaderHTMLUtilities.escapeHTML(number ?? ""))
            .replacingOccurrences(of: "{name}", with: ReaderHTMLUtilities.escapeHTML(name))
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // 1em in the template is anchored to the title size (標題大小), not the
        // body font size, so size sliders keep working with templates.
        let cfg = HTMLAttributedStringBuilder.Config(
            fontSize: style.size,
            lineHeightMultiple: settings.lineHeightMultiple,
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor,
            fontFamilyName: UserReaderFontResolver.selectedPostScriptName,
            renderWidth: renderWidth,
            writingMode: settings.writingMode
        )
        let builder = HTMLAttributedStringBuilder()
        guard let ast = await builder.buildStyledAST(html: html, config: cfg) else {
            AppLogger.render("chapterTitle advancedCSS template parse failed", context: [
                "len": html.count
            ])
            return nil
        }

        let nodes = HTMLStyledASTRenderableNodeConverter.convert(
            body: ast,
            whitespacePolicy: .trimTextNodeBoundaries
        )
        // The renderer re-anchors the AST's relative font multipliers at
        // `baseFontSize`, so it must match the CSS resolution root above
        // (style.size) or every px/em in the template renders scaled. Paragraph
        // spacing inside the template block is the template's own business
        // (margins); zero here so body spacing doesn't leak between title lines.
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: themeTextColor,
                baseFontSize: style.size,
                paragraphSpacing: 0,
                fontFamily: UserReaderFontResolver.selectedPostScriptName,
                renderWidth: renderWidth
            )
        )
        let rendered = await renderer.render(nodes)
        guard rendered.length > 0 else {
            AppLogger.render("chapterTitle advancedCSS rendered empty", context: [
                "len": html.count
            ])
            return nil
        }
        return rendered
    }

    /// A zero-visible fixed-height blank line used to carry top/bottom spacing.
    private static func spacerLine(height: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = height
        para.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 1),
            .foregroundColor: UIColor.clear,
            .paragraphStyle: para,
        ])
    }
}

private extension UIColor {
    /// Luminance-based dark test, for choosing the light vs dark template.
    var yd_isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
    }
}
