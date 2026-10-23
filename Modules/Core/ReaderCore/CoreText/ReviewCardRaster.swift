import CryptoKit
import os
import UIKit
import WebKit

/// The one way a source review card (本章說 / 作者說 / 神評論) becomes an image, whichever
/// route it took into the reader — `<img src="data:…svg">` through `OnlineImageLoader`, or an
/// inline `<svg>` through `NodeAttributedStringRenderer`.
///
/// When the reader wears a template for the card's kind (氣泡設定), the card is redrawn from
/// it, in the reading font, size and colour. Otherwise the source's card is drawn as authored,
/// its canvas widened so its text matches the prose (`ReviewCardSVGMetrics`).
enum ReviewCardRaster {
    /// The reading text a card sits among.
    struct Reader: Sendable {
        let font: UIFont
        let textColor: UIColor
    }

    /// - Parameters:
    ///   - reader: nil when the caller has no reader text to match; the card keeps its
    ///     column-width sizing and the source's drawing.
    ///   - isAuthorSized: the markup sized the SVG itself (or it is a Legado `style:"text"`
    ///     icon); it is drawn as authored.
    @MainActor
    static func image(
        svg: String,
        columnWidth: CGFloat,
        reader: Reader?,
        styleWidth: CGFloat? = nil,
        styleHeight: CGFloat? = nil,
        isAuthorSized: Bool = false,
        baseURL: URL? = nil,
        path: String
    ) async -> UIImage? {
        if !isAuthorSized, let reader,
           let templated = templatedSVG(svg, columnWidth: columnWidth, reader: reader, path: path) {
            return await SVGWebViewRasterizer.shared.renderCard(
                svgString: templated,
                width: columnWidth,
                isNight: CommentBubbleSVGRecognizer.isNightTheme(themeTextColor: reader.textColor)
            )
        }
        let drawn: String
        if !isAuthorSized, let reader {
            drawn = ReviewCardSVGMetrics.reshapedForColumn(
                svg: svg,
                bodyPointSize: reader.font.pointSize,
                columnWidth: columnWidth,
                path: path
            ) ?? svg
        } else {
            drawn = svg
        }
        let size = SVGWebViewRasterizer.shared.resolveSVGSize(
            styleWidth: styleWidth,
            styleHeight: styleHeight,
            svgString: drawn,
            renderWidth: columnWidth
        )
        return await SVGWebViewRasterizer.shared.render(svgString: drawn, size: size, baseURL: baseURL)
    }

    /// A template drawn over sample content, for 氣泡設定's previews, on `theme` — the
    /// preview's own, which is 黑色 in the night preview whatever the reader is on.
    @MainActor
    static func preview(
        templateSource: String,
        kind: ReaderCommentCardKind,
        colorHex: String?,
        reader: Reader,
        theme: ReaderTheme,
        width: CGFloat
    ) async throws -> UIImage? {
        let template = try ReviewCardTemplate(source: templateSource)
        let appearance = appearance(for: reader, theme: theme)
        let filled = template.filled(
            with: ReviewCardContent.sample(for: kind),
            appearance: appearance,
            width: width,
            colorHex: colorHex ?? appearance.textColorHex
        )
        return await SVGWebViewRasterizer.shared.renderCard(
            svgString: filled,
            width: width,
            isNight: appearance.isNight
        )
    }

    /// The card redrawn from the template its kind wears, or nil when the source's card is
    /// drawn instead.
    ///
    /// Fallback, by design: a card this build cannot read (`ReviewCardContent.extract` finds
    /// no heading or hint naming its kind, or nothing a comment is made of) is drawn as the
    /// source authored it. That is the real case of a source shipping a card layout nobody
    /// has seen, as 含遇見's 作家說 was until its heading was read. Remove a case once its
    /// layout is read.
    @MainActor
    static func templatedSVG(
        _ svg: String,
        columnWidth: CGFloat,
        reader: Reader,
        path: String
    ) -> String? {
        let settings = GlobalSettings.snapshot
        let anyTemplateWorn = ReaderCommentCardKind.allCases.contains {
            settings.wornCommentCardTemplate(for: $0) != nil
        }
        guard anyTemplateWorn else { return nil }
        guard let card = ReviewCardContent.extract(from: svg) else {
            if ReviewCardSVGMetrics.textCard(in: svg) != nil {
                CommentBubbleSVGRecognizer.diag("reviewCard unread → source card", context: [
                    "path": path,
                    "len": svg.count,
                ])
            }
            return nil
        }
        guard let worn = settings.wornCommentCardTemplate(for: card.kind) else { return nil }

        let source: String
        let customColor: String?
        let isNight = CommentBubbleSVGRecognizer.isNightTheme(themeTextColor: reader.textColor)
        switch worn {
        case .builtin:
            source = ReviewCardTemplate.builtinSource(for: card.kind)
            customColor = nil
        case .custom(let style):
            source = style.svg
            customColor = style.colorHex(isNight: isNight)
        }
        do {
            let template = try ReviewCardTemplate(source: source)
            let appearance = appearance(for: reader, theme: ReaderConfig.shared.theme)
            return template.filled(
                with: card,
                appearance: appearance,
                width: columnWidth,
                colorHex: customColor ?? appearance.textColorHex
            )
        } catch {
            // A stored template is checked when it is saved; one that no longer reads came
            // from a build with another template contract. Say so and draw the source card.
            AppLogger.error("comment card template unreadable; drawing the source card", error: error, context: [
                "kind": card.kind.rawValue,
                "path": path,
            ])
            return nil
        }
    }

    static func appearance(for reader: Reader, theme: ReaderTheme) -> ReviewCardTemplate.Appearance {
        let fonts = ReviewCardFonts.css(for: reader.font)
        return ReviewCardTemplate.Appearance(
            pointSize: reader.font.pointSize,
            fontFamilyCSS: fonts.family,
            fontFaceCSS: fonts.fontFace,
            textColorHex: CommentBubbleSVGRecognizer.hexString(reader.textColor),
            accentHex: CommentBubbleSVGRecognizer.hexString(theme.commentCardAccent),
            isNight: CommentBubbleSVGRecognizer.isNightTheme(themeTextColor: reader.textColor)
        )
    }
}

/// A panel of the system's glass behind a card's text — a template's `data-yd-glass`
/// element — in the card image's points.
struct ReviewCardGlassPanel: Equatable, Sendable {
    let rect: CGRect
    let cornerRadius: CGFloat

    /// The panel on a card drawn into `frame` (the image's own size scaled to fit).
    func placed(in frame: CGRect, imageSize: CGSize) -> (rect: CGRect, cornerRadius: CGFloat) {
        let scale = imageSize.width > 0 ? frame.width / imageSize.width : 1
        return (
            CGRect(
                x: frame.minX + rect.minX * scale,
                y: frame.minY + rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ),
            cornerRadius * scale
        )
    }
}

/// A card drawn from a template with glass panels: its text on a clear background, and where
/// the reader puts the system's glass behind it. Glass samples what lies behind it live, so it
/// cannot be part of a bitmap; the panels travel with the image instead.
final class ReviewCardImage: UIImage, @unchecked Sendable {
    /// Set once, by the initializer, as is `isNight`.
    private(set) var glassPanels: [ReviewCardGlassPanel] = []
    /// The theme the card was filled for. Its text colour was picked for that theme, so its
    /// glass takes the matching dark or light look.
    private(set) var isNight = false

    convenience init?(image: UIImage, glassPanels: [ReviewCardGlassPanel], isNight: Bool) {
        guard let cgImage = image.cgImage else { return nil }
        self.init(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        self.glassPanels = glassPanels
        self.isNight = isNight
    }
}

/// The reading font, as the WebView that draws card templates can use it.
///
/// WebKit draws in its own process, which sees the system's fonts but none this app
/// registered — the fonts a reader imported. Those are served to it from their files through
/// the `yd-font:` scheme instead.
enum ReviewCardFonts {
    static let scheme = "yd-font"
    private static let servedFamily = "yd-reader-font"
    private static let files = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    static func css(for font: UIFont) -> (family: String, fontFace: String) {
        let fallback = "-apple-system, sans-serif"
        // The system font's family is private (".SFUI…"); WebKit names it -apple-system.
        guard !font.familyName.hasPrefix(".") else { return (fallback, "") }
        let family = "\"\(font.familyName.replacingOccurrences(of: "\"", with: ""))\", \(fallback)"
        guard let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL,
              !url.path.contains("/System/Library/") else {
            return (family, "")
        }
        let token = SHA256.hash(data: Data(url.path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        files.withLock { $0[token] = url }
        let face = "@font-face{font-family:\"\(servedFamily)\";src:url(\"\(scheme)://font/\(token)\");}"
        return ("\"\(servedFamily)\", \(family)", face)
    }

    static func fileURL(token: String) -> URL? {
        files.withLock { $0[token] }
    }
}

/// Serves `ReviewCardFonts`' files to the card WebViews.
final class ReviewCardFontSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = ReviewCardFonts.fileURL(token: url.lastPathComponent) else {
            AppLogger.render("⟐ reviewCard font not registered", context: [
                "url": urlSchemeTask.request.url?.absoluteString ?? "",
            ])
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let mimeType = fileURL.pathExtension.lowercased() == "otf" ? "font/otf" : "font/ttf"
            urlSchemeTask.didReceive(URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            ))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            AppLogger.error("reviewCard font unreadable", error: error, context: ["file": fileURL.lastPathComponent])
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
