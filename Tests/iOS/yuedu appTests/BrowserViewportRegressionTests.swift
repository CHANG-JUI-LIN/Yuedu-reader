@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserViewportRegressionTests {
    private nonisolated static let html = "<body>" + (0..<100).map {
        "<p id='p\($0)' style='margin:80px 0'>\($0) " + String(repeating: "中文 English <b>bold</b> text ", count: 12) + "</p>"
    }.joined() + "</body>"

    private nonisolated func document() -> HTMLLayoutDocument {
        HTMLLayoutDocument(html: Self.html, configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 600))
    }

    private func chapter() throws -> BrowserScrollChapter {
        let owner = try BrowserViewportLayoutOwner(document: document())
        return BrowserScrollChapter(spineIndex: 0, layoutOwner: owner, snapshot: owner.initialSnapshot,
            backgroundColor: .white, usesReaderBackground: false)
    }

    /// The host's request, awaited here only because a test inspects the result.
    private func ensureViewport(_ chapter: BrowserScrollChapter, _ bounds: CGRect, anchorOffset: Int? = nil) async {
        chapter.requestViewport(bounds, anchorOffset: anchorOffset)
        await chapter.waitForViewportIdle()
    }

    @Test func movingBackThroughMeasuredParagraphSpacingDoesNotRelayout() async throws {
        let chapter = try chapter()
        await ensureViewport(chapter, CGRect(x: 0, y: 0, width: 320, height: 6000))
        let before = chapter.layoutRevision
        let start = SourcePerfTrace.now
        for y in stride(from: CGFloat(4000), through: 2400, by: -8) {
            let anchor = chapter.sourceOffset(at: y)
            await ensureViewport(chapter, CGRect(x: 0, y: y - 2000, width: 320, height: 4600), anchorOffset: anchor)
        }
        let count = chapter.layoutRevision - before
        SourcePerfTrace.record("test.viewport.reverse", "updates=\(count)", since: start, thresholdMs: 0)
        print("[ViewportRegression] reverseUpdates=\(count) ms=\((SourcePerfTrace.now-start)*1000)")
        #expect(count == 0, "measured paragraph gaps must not invalidate a covered demand")
    }

    @Test func extendingDemandDoesNotRepaintAnUnchangedVisibleTile() async throws {
        let chapter = try chapter()
        await ensureViewport(chapter, CGRect(x: 0, y: 0, width: 320, height: 2400))
        let cell = BrowserScrollTileCell(frame: CGRect(x: 0, y: 0, width: 320, height: 2000))
        let first = try #require(chapter.tiles(width: 320).first)
        guard case .browser(let tile) = first else { Issue.record("expected browser tile"); return }
        cell.configure(tile: tile, horizontalInset: 0, leadingSpacing: 0)
        let before = cell.paintUpdateCount
        let textBefore = cell.interactiveView.pageSourceText
        await ensureViewport(chapter, CGRect(x: 0, y: 0, width: 320, height: 4800))
        let updated = try #require(chapter.tiles(width: 320).first)
        guard case .browser(let newTile) = updated else { Issue.record("expected browser tile"); return }
        cell.configure(tile: newTile, horizontalInset: 0, leadingSpacing: 0)
        #expect(cell.interactiveView.pageSourceText == textBefore)
        #expect(cell.paintUpdateCount == before, "offscreen preparation must not dirty unchanged visible glyphs")
    }

    @Test func reversingWithinRetainedWindowReusesPreparedPaint() throws {
        let session = try document().makeViewportSession()
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        func resources() -> [Int: TextDrawingResources] {
            Dictionary(session.document.displayList.items.compactMap {
                if case .text(let t) = $0, let resource = t.preparedDrawing { return (t.sourceRange.location, resource) }
                return nil
            }, uniquingKeysWith: { a, _ in a })
        }
        let first = resources()
        _ = try session.layout(in: CGRect(x: 0, y: 900, width: 320, height: 1800))
        let shaped = session.shapedLineCount
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        let reverse = resources()
        #expect(session.shapedLineCount == shaped)
        let reused = first.filter { reverse[$0.key] === $0.value }.count
        print("[ViewportRegression] paintReused=\(reused)/\(first.count)")
        #expect(reused == first.count, "retained layout must retain its drawing resources through reversal")
        session.discardRenderingResources()
        #expect(session.retainedLineCount == 0)
        #expect(session.retainedPaintResourceCount == 0, "eviction must release paint along with layout")
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        #expect(resources().keys.sorted() == first.keys.sorted(), "reload must restore all original runs")
    }

    @Test func paintComparisonDoesNotHideGeometryStyleOrImageChanges() {
        let font = UIFont.systemFont(ofSize: 18)
        func text(y: CGFloat = 0, color: UIColor = .black, target: String? = nil) -> DisplayList {
            DisplayList(items: [.text(DisplayTextItem(sourceRange: NSRange(location: 0, length: 2),
                nodeID: 1, linkTarget: target, writingMode: .horizontal,
                rect: .init(rawValue: CGRect(x: 0, y: y, width: 40, height: 24)), baselineY: y + 18,
                font: font, color: color, text: "中文", ctLine: nil))])
        }
        #expect(text().hasSameContents(as: text()))
        #expect(!text().hasSameContents(as: text(y: 1)))
        #expect(!text().hasSameContents(as: text(color: .red)))
        #expect(!text().hasSameContents(as: text(target: "#changed")))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        func list(_ bitmap: UIImage?) -> DisplayList {
            .init(items: [.image(.init(source: "image.png", image: bitmap, sourceRange: NSRange(location: 0, length: 1),
                nodeID: 2, linkTarget: nil, writingMode: .horizontal,
                rect: .init(rawValue: CGRect(x: 0, y: 0, width: 20, height: 40)), alt: "image"))])
        }
        #expect(list(image).hasSameContents(as: list(image)))
        #expect(!list(nil).hasSameContents(as: list(image)), "late image decoding must repaint")
    }
}
