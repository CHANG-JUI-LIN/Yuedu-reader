import UIKit

/// Builds the in-content chapter-title run(s) from a `ChapterTitleStyle` and
/// appends them to the chapter's attributed string. Shared by the paged/scroll
/// TXT builder and the online builder so alignment / weight / two-line split
/// behave identically on both. The EPUB `<h1>` path does NOT use this — it keeps
/// its own CSS-driven heading rendering.
enum ChapterTitleAttributedBuilder {
    /// Appends the title (nothing if hidden/empty; one or two lines otherwise).
    /// When the style enables advanced CSS, the title is rendered from the
    /// user's HTML/CSS template through the shared IR engine instead.
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
            let t0 = CFAbsoluteTimeGetCurrent()
            let rendered = await renderAdvancedCSS(
                rawTitle: trimmed,
                style: style,
                settings: settings,
                renderWidth: renderWidth,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            )
            AppLogger.render(
                "⟐ title.css render ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))"
                    + " ok=\(rendered != nil) len=\(rendered?.length ?? 0)"
            )
            if let rendered {
                // 上距/下距 spacers frame the template block; the template's own
                // margins/padding handle everything inside.
                if style.topSpacing > 0 {
                    attr.append(spacerLine(height: style.topSpacing))
                }
                attr.append(rendered)
                if style.bottomSpacing > 0 {
                    attr.append(spacerLine(height: style.bottomSpacing))
                }
                return
            }
            // Fallback: the template is user-authored/imported HTML we cannot
            // validate upfront; if it parses to nothing, fall through to the
            // plain layout so the chapter still shows a title. Can be removed
            // once the template editor validates on save/import.
        }

        appendPlainLines(
            trimmedTitle: trimmed,
            style: style,
            themeTextColor: themeTextColor,
            letterSpacing: letterSpacing,
            to: attr
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
        alignment: NSTextAlignment,
        paragraphSpacing: CGFloat,
        color: UIColor,
        letterSpacing: CGFloat,
        to attr: NSMutableAttributedString
    ) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.paragraphSpacing = paragraphSpacing
        attr.append(NSAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
            .kern: letterSpacing as NSNumber,
        ]))
    }

    // MARK: - Advanced CSS layout

    /// Substitutes `{number}` / `{name}` into the light/dark template and renders
    /// it through the same IR pipeline as online HTML chapters (HTML → styled
    /// AST → RenderableNode → attributed string), so template CSS behaves
    /// exactly like book content. Returns nil when the template yields nothing.
    private static func renderAdvancedCSS(
        rawTitle: String,
        style: ChapterTitleStyle,
        settings: ReaderRenderSettings,
        renderWidth: CGFloat,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> NSAttributedString? {
        let (number, name) = ChapterTitleSplitter.split(rawTitle)
        let template = themeBackgroundColor.yd_isDark ? style.darkTemplate : style.lightTemplate
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
