import CoreGraphics

/// 左右邊距 is the reader's own number on every device: 0 puts the text at the page edge.
///
/// iPad used to add a readable-width inset on top of it — up to ~250pt a side on a
/// landscape iPad mini — so even 0 left a wide empty band (reported 2026-10-10). That
/// inset now survives only as the slider's upper bound, so the old narrow column is
/// still one drag away instead of being forced on everyone.
enum ReaderReadableWidthPolicy {
    /// The slider's ceiling wherever the former inset was zero (iPhone, narrow windows).
    static let compactUpperBound: CGFloat = 50
    /// Text never gets narrower than this, whatever margin was stored.
    static let minimumTextWidth: CGFloat = 200

    /// The margin the page is laid out with. `pageMarginH` syncs across devices and
    /// arrives through theme and qitheme imports, so a value picked on a landscape iPad
    /// can land on a phone or a single spread page; this keeps a text column there
    /// instead of a zero or negative width. Below that ceiling the user's value is
    /// used exactly.
    static func effectiveMargin(_ margin: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let ceiling = max(0, (pageWidth - minimumTextWidth) / 2)
        return min(max(0, margin), ceiling)
    }

    /// The 左右邊距 slider's maximum: the default margin plus the readable-width inset
    /// iPad used to force, i.e. the look iPad had before 0 meant the edge.
    static func sliderUpperBound(
        pageWidth: CGFloat,
        usesReadableWidth: Bool,
        defaultMargin: CGFloat
    ) -> CGFloat {
        guard usesReadableWidth else { return compactUpperBound }
        let regularInset = min(DSLayout.readerRegularExtraHorizontalInset,
                               max(0, (pageWidth - DSLayout.readableNarrowWidth) / 2))
        let formerInset = max(regularInset, (pageWidth - DSLayout.readableCompactWidth) / 2)
        return max(compactUpperBound, (defaultMargin + formerInset).rounded(.up))
    }
}
