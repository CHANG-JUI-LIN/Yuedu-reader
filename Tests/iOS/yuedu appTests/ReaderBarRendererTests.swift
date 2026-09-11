import CoreFoundation
import Testing
import UIKit
@testable import yuedu_app

struct ReaderBarRendererTests {

    @Test @MainActor func everyComponentUsesItsOwnAppearanceColor() throws {
        let snapshot = ReaderOverlayContentSnapshot(
            bookTitle: "Book", chapterTitle: "Chapter", chapterPage: 2, chapterPageCount: 10,
            totalProgress: 0.2, now: Date(timeIntervalSince1970: 0), batteryLevel: 0.7,
            isCharging: false, readingDuration: 60, estimatedRemainingTime: 240
        )
        let builder = ReaderBarRenderModelBuilder()
        for kind in ReaderOverlayComponentKind.allCases {
            var layout = ReaderBarLayout(fields: [.init(
                kind: kind, slot: .headerLeft,
                configuration: .init(customText: "Custom", showsBatteryPercentage: true),
                color: .init(source: .custom, hexRGBA: 0xFF0000FF, darkHexRGBA: 0x00FF00FF)
            )])
            layout.style.color = .init(source: .custom, hexRGBA: 0x0000FFFF, darkHexRGBA: 0x0000FFFF)
            for (appearance, hex) in [(UIUserInterfaceStyle.light, "#FF0000FF"), (.dark, "#00FF00FF")] {
                let model = builder.model(for: .header, layout: layout, content: snapshot,
                                          readerTextColor: .white, horizontalPadding: 0,
                                          svgAssetStore: nil, userInterfaceStyle: appearance, displayScale: 1)
                let field = try #require(model.slots[0].first)
                let color: UIColor?
                switch field {
                case .text(_, let value), .progress(_, let value), .image(_, _, let value): color = value
                }
                #expect(ReaderOverlayPresentationResolver.rgbaHex(try #require(color), userInterfaceStyle: appearance) == hex)
                #expect(ReaderOverlayPresentationResolver.rgbaHex(model.color, userInterfaceStyle: appearance) == "#0000FFFF")
            }
        }
    }

    @Test @MainActor func neighboringTextProgressAndBatteryPercentageKeepSeparateColors() throws {
        let emptyImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let model = ReaderBarRenderModel(
            bar: .footer,
            slots: [[.text("Chapter", color: .red)], [.image(emptyImage, percentage: "80%", color: .green)], [.progress(1, color: .blue)]],
            font: .systemFont(ofSize: 16), color: .white, opacity: 1,
            horizontalPadding: 0, showsDivider: false, accessibilityValue: ""
        )
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 30)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            ReaderBarRenderer.draw(model, in: bounds, canvasHeight: bounds.height, context: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 300 * 30 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: 300, height: 30, bitsPerComponent: 8,
                bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cgImage, in: bounds)
        }
        for region in 0..<3 {
            var channels = [0, 0, 0]
            for y in 0..<30 {
                for x in (region * 100)..<((region + 1) * 100) {
                    for channel in 0..<3 { channels[channel] += Int(bytes[(y * 300 + x) * 4 + channel]) }
                }
            }
            #expect(channels[region] > 1000)
            #expect(channels[(region + 1) % 3] == 0)
            #expect(channels[(region + 2) % 3] == 0)
        }
    }

    @Test @MainActor func drawnTextUsesConfiguredColorAndOpacity() throws {
        func render(color: UIColor, opacity: Double) throws -> Data {
            let model = ReaderBarRenderModel(
                bar: .header, slots: [[.text("Chapter"), .text("3/12")], [], []],
                font: .systemFont(ofSize: 16), color: color, opacity: opacity,
                horizontalPadding: 0, showsDivider: false, accessibilityValue: "Chapter 3/12"
            )
            let bounds = CGRect(x: 0, y: 0, width: 240, height: 30)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
                ReaderBarRenderer.draw(model, in: bounds, canvasHeight: bounds.height, context: context.cgContext)
            }
            return try #require(image.pngData())
        }
        let red = try render(color: .red, opacity: 1)
        #expect(red != (try render(color: .green, opacity: 1)), "CoreText must use the configured foreground")
        #expect(red != (try render(color: .red, opacity: 0.25)), "Text must honor bar opacity")
        #expect(try render(color: .black, opacity: 1) != render(color: .white, opacity: 1),
                "Day and night text must draw different pixels")
    }

    @Test @MainActor func legacyCustomColorAdaptsToNight() {
        let style = ReaderBarStyle(color: .init(source: .custom, hexRGBA: 0x123456FF))
        let day = ReaderBarStyleResolver.resolve(style, readerTextColor: .black, userInterfaceStyle: .light)
        let night = ReaderBarStyleResolver.resolve(style, readerTextColor: .white, userInterfaceStyle: .dark)
        #expect(ReaderOverlayPresentationResolver.rgbaHex(day.color, userInterfaceStyle: .light) == "#123456FF")
        #expect(night.color == UIColor.white)
    }

    @Test @MainActor func dynamicTextResolvesUsingReaderAppearance() {
        let text = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
        let night = ReaderBarStyleResolver.resolve(.init(), readerTextColor: text, userInterfaceStyle: .dark)
        // Drawing under light UIKit traits must still use the night reader color.
        #expect(ReaderOverlayPresentationResolver.rgbaHex(night.color, userInterfaceStyle: .light) == "#FFFFFFFF")
    }

    @Test @MainActor func pagedAndScrollBarsRefreshBothAppearanceColors() throws {
        var layout = ReaderBarLayout.default
        layout.style.color = .init(source: .custom, hexRGBA: 0x123456FF, darkHexRGBA: 0xABCDEF80)
        let snapshot = ReaderOverlayContentSnapshot(
            bookTitle: "Book", chapterTitle: "Chapter", chapterPage: 2, chapterPageCount: 10,
            totalProgress: 0.2, now: Date(timeIntervalSince1970: 0), batteryLevel: 0.7,
            isCharging: false, readingDuration: 60, estimatedRemainingTime: 240
        )
        var environment = ReaderPageBarsEnvironment(
            layout: layout, headerEnabled: true, footerEnabled: true, readerTextColor: .black,
            headerHorizontalPadding: 16, footerHorizontalPadding: 16,
            headerTopOffset: 20, footerBottomOffset: 20, bookTitle: snapshot.bookTitle,
            now: snapshot.now, batteryLevel: snapshot.batteryLevel, isCharging: false,
            readingDuration: 60, userInterfaceStyle: .light, displayScale: 1
        )
        let controller = ReaderPageBarsController()
        for (appearance, hex) in [(UIUserInterfaceStyle.light, "#123456FF"), (.dark, "#ABCDEF80"), (.light, "#123456FF")] {
            environment.userInterfaceStyle = appearance
            controller.update(environment: environment, svgAssetStore: nil) { _ in
                ReaderPageBarsPageContent(chapterTitle: "Chapter", chapterPage: 2, chapterPageCount: 10,
                                         totalProgress: 0.2, estimatedRemainingTime: 240)
            }
            let paged = try #require(controller.bars(forGlobalPage: 0))
            for bar in [ReaderBar.header, .footer] {
                let page = try #require(bar == .header ? paged.header : paged.footer)
                let scroll = controller.model(for: bar, snapshot: snapshot, environment: environment)
                #expect(ReaderOverlayPresentationResolver.rgbaHex(page.color, userInterfaceStyle: appearance) == hex)
                #expect(page == scroll)
            }
        }
        environment.layout.style.color.source = .readerText
        environment.readerTextColor = .white
        let automatic = controller.model(for: .header, snapshot: snapshot, environment: environment)
        #expect(automatic.color == UIColor.white)
    }

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
