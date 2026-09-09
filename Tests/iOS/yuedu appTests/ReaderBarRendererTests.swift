import CoreFoundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderBarRendererTests {

    /// The bars used to assume a flat 16pt row. The style lets the reader pick
    /// 8–16pt, and a 16pt face does not fit in a 16pt row — descenders were being
    /// clipped. The band has to follow the font.
    @Test("A band is never shorter than the type it holds")
    func rowFitsItsFont() {
        for size in stride(from: 8.0, through: 16.0, by: 1.0) {
            let row = ReaderBarRenderer.rowHeight(fontSize: CGFloat(size))
            #expect(row >= UIFont.systemFont(ofSize: CGFloat(size)).lineHeight)
        }
    }

    @Test("Row height rises with the font size")
    func rowGrowsWithFont() {
        #expect(
            ReaderBarRenderer.rowHeight(fontSize: 16)
                > ReaderBarRenderer.rowHeight(fontSize: 8)
        )
    }

    /// legado's own Compose port keeps this floor for a reason: a bar that
    /// collapsed when every slot was empty would hand its height to the text area,
    /// which repaginates, which changes what the bar says, which can change its
    /// height again.
    @Test("An empty bar keeps its floor rather than collapsing")
    func emptyBarKeepsItsFloor() {
        let empty = ReaderBarRenderModel(
            bar: .header,
            slots: [[], [], []],
            font: .systemFont(ofSize: 11),
            color: .black,
            opacity: 1,
            horizontalPadding: 16,
            showsDivider: false,
            accessibilityValue: ""
        )
        #expect(empty.isEmpty)
        #expect(ReaderPageBars.extent(of: empty) == ReaderBarRenderer.rowHeight(fontSize: 11))
        #expect(ReaderPageBars.extent(of: empty) > 0)
    }

    @Test("A divider adds its own half point to the band")
    func dividerAddsToTheBand() {
        let plain = ReaderBarRenderer.extent(fontSize: 11, showsDivider: false)
        let ruled = ReaderBarRenderer.extent(fontSize: 11, showsDivider: true)
        #expect(ruled - plain == ReaderBarRenderer.dividerHeight)
    }

    /// The band the bar draws in and the band the paginator reserves have to be
    /// the same number, or the text runs under the bar.
    @Test("Reserved insets grow by exactly the band's height")
    func reservationMatchesTheBand() {
        let extents = (
            header: ReaderBarRenderer.extent(fontSize: 11, showsDivider: false),
            footer: ReaderBarRenderer.extent(fontSize: 11, showsDivider: true)
        )
        let insets = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: true,
            showsFooter: true,
            verticalMargin: 12,
            headerExtent: extents.header,
            footerExtent: extents.footer
        )

        #expect(
            insets.top == ReaderLayoutMetrics.headerBarTopOffset(safeTop: 59)
                + extents.header + 12
        )
        #expect(
            insets.bottom == ReaderLayoutMetrics.footerBarBottomOffset(safeBottom: 34)
                + extents.footer + 12
        )
    }

    /// A page's bars sit exactly where the reservation put them: the header band
    /// starts at `headerTopOffset`, the footer band ends at `footerBottomOffset`
    /// from the bottom.
    @Test("Bars land inside the bands that were reserved for them")
    func barsLandInTheirBands() {
        let model = ReaderBarRenderModel(
            bar: .header,
            slots: [[.text("第一回")], [], []],
            font: .systemFont(ofSize: 11),
            color: .black,
            opacity: 1,
            horizontalPadding: 16,
            showsDivider: false,
            accessibilityValue: "章節名 第一回"
        )
        var footer = model
        footer.bar = .footer

        let bars = ReaderPageBars(
            header: model,
            footer: footer,
            headerTopOffset: 65,
            footerBottomOffset: 38
        )
        let page = CGSize(width: 390, height: 844)
        let extent = ReaderPageBars.extent(of: model)
        let insets = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: true,
            showsFooter: true,
            verticalMargin: 0,
            headerTopPadding: 6,
            footerBottomPadding: 4,
            headerExtent: extent,
            footerExtent: extent
        )

        // The header band's bottom edge is where the text may start, and the
        // footer band's top edge is where it must stop.
        #expect(bars.headerTopOffset + extent == insets.top)
        #expect(page.height - (bars.footerBottomOffset + extent) == page.height - insets.bottom)
    }
}
