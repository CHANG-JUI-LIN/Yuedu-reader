import CoreGraphics
import Foundation

/// The values 匯出閱讀設定 writes for the layout half of a package. Taken on the
/// main actor from `GlobalSettings` / `ReaderConfig`, then encoded off it.
struct ReaderLayoutSnapshot: Equatable, Sendable {
    var name: String?
    var fontSize: CGFloat
    var isBold: Bool
    var lineHeightMultiple: CGFloat
    var letterSpacing: CGFloat
    var paragraphSpacingMultiplier: CGFloat
    var pageMarginH: CGFloat
    var pageMarginV: CGFloat
    var footerBottomPadding: CGFloat
    var footerTextGap: CGFloat
    var titleVisible: Bool
    var titleSize: CGFloat
    var titleTopSpacing: CGFloat
    var titleBottomSpacing: CGFloat
    var pageTurnStyle: PageTurnStyle
    var scrollMode: Bool
    var readerOverlayLayout: ReaderOverlayLayout
}

/// Writes exactly the `readConfig.json` shape `ReaderLayoutPresetImporter` reads.
///
/// Deliberately the inverse of `LegadoReadConfig.readerLayoutPreset(overlayLayout:)`
/// rather than a new schema: an exported file therefore round-trips through the
/// one import route the app already has (no second parser), and legado can open
/// it too. `readerOverlayLayout` rides alongside as an extra key legado ignores
/// and Yuedu's importer picks up.
enum ReaderLayoutPresetExporter {
    static func encode(_ snapshot: ReaderLayoutSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ExportedReadConfig(snapshot))
    }

    /// legado's `pageAnim`. Scroll mode is its own value there, so it outranks
    /// the page-turn animation exactly as the importer's reading does.
    static func pageAnim(for snapshot: ReaderLayoutSnapshot) -> Int {
        if snapshot.scrollMode { return 3 }
        switch snapshot.pageTurnStyle {
        case .slide: return 0
        case .cover: return 1
        case .curl: return 2
        // legado has no "no animation" value; the importer maps anything else to
        // `nil` and leaves the receiving device's own choice alone.
        case .none: return -1
        }
    }
}

/// Key names are legado's, not Swift's — renaming any of them breaks both the
/// round trip through `LegadoReadConfig` and legado interop.
private struct ExportedReadConfig: Encodable {
    let name: String?
    let textSize: CGFloat
    let textBold: Int
    let lineSpacingExtra: CGFloat
    let letterSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let paddingLeft: CGFloat
    let paddingRight: CGFloat
    let paddingTop: CGFloat
    let paddingBottom: CGFloat
    let footerPaddingBottom: CGFloat
    let footerPaddingTop: CGFloat
    let headerMode: Int
    let titleSize: CGFloat
    let titleTopSpacing: CGFloat
    let titleBottomSpacing: CGFloat
    let pageAnim: Int
    let readerOverlayLayout: ReaderOverlayLayout

    init(_ snapshot: ReaderLayoutSnapshot) {
        name = snapshot.name
        textSize = snapshot.fontSize
        textBold = snapshot.isBold ? 1 : 0
        // legado stores extra leading in points, not a multiple.
        lineSpacingExtra = max(0, (snapshot.lineHeightMultiple - 1) * snapshot.fontSize)
        letterSpacing = snapshot.letterSpacing
        paragraphSpacing = max(0, snapshot.paragraphSpacingMultiplier * snapshot.fontSize)
        paddingLeft = snapshot.pageMarginH
        paddingRight = snapshot.pageMarginH
        paddingTop = snapshot.pageMarginV
        paddingBottom = snapshot.pageMarginV
        footerPaddingBottom = snapshot.footerBottomPadding
        footerPaddingTop = snapshot.footerTextGap
        headerMode = snapshot.titleVisible ? 1 : 0
        titleSize = snapshot.titleSize
        titleTopSpacing = snapshot.titleTopSpacing
        titleBottomSpacing = snapshot.titleBottomSpacing
        pageAnim = ReaderLayoutPresetExporter.pageAnim(for: snapshot)
        readerOverlayLayout = snapshot.readerOverlayLayout
    }
}
