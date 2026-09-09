import Accessibility
import Combine
import Testing
import UIKit
@testable import yuedu_app

@Suite("Page bars survive engine lifecycle", .serialized)
struct EPUBPageBarsLifecycleTests {
    @Test @MainActor func firstFallbackChapterSnapshotKeepsPreboundBars() async throws {
        var entries = EPUBTestFixtures.proseSmoke().entries
        entries["OPS/chapter1.xhtml"] = Data(EPUBTestFixtures.xhtml(title: "Table",
            body: "<table><tr><td>Fallback chapter</td></tr></table>").utf8)
        let url = try await EPUBTestFixtures.makeArchive(entries: entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let renderer = EPUBPageRenderer()
        let expected = bars(title: "Fallback header")
        renderer.pageBarsProvider = { _ in expected }
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
            renderSize: CGSize(width: 360, height: 800), settings: EPUBTestFixtures.renderSettings())
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        #expect(engine.choice(for: 0)?.isBrowser == false)
        let firstSnapshot = try #require(engine.renderSnapshot(forPage: 0)?.pngData())
        renderer.pageBarsProvider = nil
        #expect(engine.renderSnapshot(forPage: 0)?.pngData() != firstSnapshot)
        renderer.pageBarsProvider = { _ in expected }
        #expect(engine.renderSnapshot(forPage: 0)?.pngData() == firstSnapshot)
    }

    @Test @MainActor func bindingBeforeAsyncEPUBOpenReachesCreatedEngine() async throws {
        let renderer = EPUBPageRenderer()
        let expected = bars(title: "Custom EPUB header")
        renderer.pageBarsProvider = { _ in expected }
        #expect(renderer.engine == nil)

        let url = try await EPUBTestFixtures.makeArchive(entries: EPUBTestFixtures.proseSmoke().entries)
        let session = try await PublicationSession.open(sourceURL: url)
        renderer.load(publicationSession: session, bookIdentifier: UUID().uuidString,
                      renderSize: CGSize(width: 360, height: 800),
                      settings: EPUBTestFixtures.renderSettings())
        let engine = try #require(renderer.engine as? BrowserLayoutPageEngine)
        #expect(engine.pageBarsProvider?(0) == expected)
        for await ready in renderer.$isCoreTextReady.values where ready { break }
        await engine.preloadChapter(at: 0)
        #expect(engine.choice(for: 0)?.isBrowser == true)
        let controller = try #require(engine.pageViewController(at: 0) as? BrowserLayoutPageViewController)
        #expect(controller.pageView.pageBars == expected)
        #expect(controller.pageView.accessibilityCustomContent?.map(\.value) == ["Custom EPUB header", "Custom footer"])
        let withBars = try #require(engine.renderSnapshot(forPage: 0)?.pngData())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 360, height: 800)
        controller.pageView.frame = CGRect(origin: .zero, size: size)
        let visiblePage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.pageView.draw(controller.pageView.bounds)
        }
        #expect(visiblePage.pngData() == withBars, "Visible Browser page and flip snapshot must carry identical bars")
        renderer.pageBarsProvider = nil
        #expect(controller.pageView.pageBars == nil)
        #expect(controller.pageView.accessibilityCustomContent?.isEmpty == true)
        let withoutBars = try #require(engine.renderSnapshot(forPage: 0)?.pngData())
        #expect(withBars != withoutBars, "Browser snapshots must paint the configured bars")
        renderer.pageBarsProvider = { _ in expected }
        #expect(controller.pageView.pageBars == expected)
        #expect(engine.renderSnapshot(forPage: 0)?.pngData() == withBars)

    }

    @Test @MainActor func replacementAndPreferenceChangesKeepOneProvider() throws {
        let renderer = EPUBPageRenderer()
        let first = bars(title: "First style")
        renderer.pageBarsProvider = { _ in first }
        loadText(into: renderer, title: "First source")
        let original = try #require(renderer.engine as? CoreTextPageEngine)
        #expect(original.pageBars(forGlobalPage: 0) == first)

        loadText(into: renderer, title: "Replacement source")
        let replacement = try #require(renderer.engine as? CoreTextPageEngine)
        #expect(replacement !== original)
        #expect(replacement.pageBars(forGlobalPage: 0) == first)

        let updated = bars(title: "Changed style")
        renderer.pageBarsProvider = { _ in updated }
        #expect(replacement.pageBars(forGlobalPage: 0) == updated)
        renderer.pageBarsProvider = nil
        #expect(replacement.pageBars(forGlobalPage: 0) == nil)
    }

    @Test @MainActor func imageOnlyEPUBPagesPaintBothConfiguredBars() async throws {
        let size = CGSize(width: 320, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let blank = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: NSAttributedString(string: "\u{FFFC}"),
            imagePage: HTMLAttributedStringBuilder.ImagePage(source: "cover.png", image: blank),
            renderSize: size, fontSize: 17
        )
        let rendered = renderer.image { context in
            CoreTextPageView.renderPage(layout: layout, pageIndex: 0,
                in: context.cgContext, bounds: CGRect(origin: .zero, size: size),
                bars: bars(title: "Custom image header"))
        }
        let cgImage = try #require(rendered.cgImage)
        let actual = try #require(cgImage.dataProvider?.data) as Data
        let reference = try #require(blank.cgImage?.dataProvider?.data) as Data
        let stride = cgImage.bytesPerRow
        #expect(actual[(40 * stride)..<(80 * stride)] != reference[(40 * stride)..<(80 * stride)])
        #expect(actual[(420 * stride)..<(460 * stride)] != reference[(420 * stride)..<(460 * stride)])
    }

    @MainActor private func loadText(into renderer: EPUBPageRenderer, title: String) {
        renderer.loadTXT(text: "A short chapter.", title: title,
                         bookIdentifier: UUID().uuidString,
                         renderSize: CGSize(width: 360, height: 800),
                         settings: EPUBTestFixtures.renderSettings())
    }

    private func bars(title: String) -> ReaderPageBars {
        let header = ReaderBarRenderModel(
            bar: .header, slots: [[.text(title)], [], []],
            font: .systemFont(ofSize: 13), color: .black, opacity: 1,
            horizontalPadding: 20, showsDivider: true, accessibilityValue: title
        )
        let footer = ReaderBarRenderModel(
            bar: .footer, slots: [[], [], [.text("Custom footer")]],
            font: .systemFont(ofSize: 12), color: .darkGray, opacity: 0.8,
            horizontalPadding: 24, showsDivider: false, accessibilityValue: "Custom footer"
        )
        return ReaderPageBars(header: header, footer: footer,
                              headerTopOffset: 40, footerBottomOffset: 30)
    }
}
