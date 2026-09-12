import UIKit
import CoreText
import YueduCoreText

/// Product rule evaluation stays in Reader; the package maps the resulting attributes
/// to its own unchanged UTF-16 source ranges before shaping.
enum BrowserReaderAttributes {
    static func transform(settings: ReaderRenderSettings) -> ((NSMutableAttributedString) -> Void)? {
        transform(configuration: settings.regexHighlightConfiguration,
                  appearance: settings.readerStyleAppearance, assetRevision: settings.readerStyleAssetRevision)
    }

    static func transform(configuration: RegexHighlightConfiguration,
                          appearance: ReaderStyleAppearance, assetRevision: UInt64) -> ((NSMutableAttributedString) -> Void)? {
        guard configuration.isEnabled else { return nil }
        return { text in
            do {
                let result = try RegexHighlightEngine.apply(configuration: configuration,
                    appearance: appearance, assetRevision: assetRevision, to: text)
                for diagnostic in result.diagnostics {
                    AppLogger.render("browser regex highlight diagnostic", context: ["diagnostic": String(describing: diagnostic)])
                }
            } catch {
                AppLogger.render("browser regex highlight apply failed", context: ["error": String(describing: error)])
            }
        }
    }
}

/// Reader-only rule decorations; HTML/CSS backgrounds/borders and all glyphs are drawn in the package.
enum ReaderDisplayListDrawer {
    static func draw(_ list: DisplayList, in context: CGContext, skipAuthoredBackgroundPaint: Bool = false) {
        list.draw(in: context, skipAuthoredBackgroundPaint: skipAuthoredBackgroundPaint) { line, text, context in
            RegexHighlightDecorationRenderer.drawHorizontal(line: line, origin: .zero,
                attributedString: text, range: NSRange(location: 0, length: text.length), context: context)
        }
    }
}
