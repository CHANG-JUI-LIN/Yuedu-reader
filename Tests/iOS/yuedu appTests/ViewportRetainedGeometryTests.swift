import CoreText
import Testing
import UIKit
@testable import YueduCoreText
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ViewportRetainedGeometryTests {
    private func makeSession() throws -> BrowserViewportSession {
        let html = "<body>" + (0..<500).map {
            "<p id='p\($0)' style='margin:12px 0'>Paragraph \($0) "
            + String(repeating: "中文 continuous content é 👩🏽‍💻 ", count: 8) + "</p>"
        }.joined() + "</body>"
        return try HTMLLayoutDocument(html: html,
            configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 800)).makeViewportSession()
    }

    @Test func retainedReverseWindowCostAndSourcePositions() throws {
        let session = try makeSession()
        for y in stride(from: 0, through: 9600, by: 800) {
            _ = try session.layout(in: CGRect(x: 0, y: y, width: 320, height: 1800))
        }
        let shaped = session.shapedLineCount
        let height = session.document.contentHeight
        let passes = session.geometryPassCount
        let reused = session.retainedViewportReuseCount
        var durations: [Double] = []
        for y in [8800, 8000, 7200, 8000, 8800, 8000, 7200, 8000, 8800, 8000] {
            let rect = CGRect(x: 0, y: y, width: 320, height: 1800)
            let anchor = session.sourceOffset(at: rect.minY)
            let before = session.documentY(for: anchor)
            let start = SourcePerfTrace.now
            let document = try session.layout(in: rect, anchorOffset: anchor)
            durations.append((SourcePerfTrace.now - start) * 1000)
            SourcePerfTrace.record("test.viewport.retainedGeometry", "y=\(y)", since: start, thresholdMs: 0)
            #expect(!document.items(in: rect).items.isEmpty)
            #expect(session.documentY(for: anchor) == before)
            #expect(session.lastReuseCandidateCount < 20, "a 500-paragraph chapter must only validate the demanded paragraphs")
        }
        #expect(session.shapedLineCount == shaped)
        #expect(session.document.contentHeight == height)
        #expect(session.geometryPassCount == passes, "resident text must not trigger a whole-tree layout")
        #expect(session.retainedViewportReuseCount == reused + durations.count)
        print("[RetainedGeometry] reverseMs=\(durations) retained=\(session.retainedLineCount)")
    }

    @Test func retirementCostAndRestore() throws {
        let session = try makeSession()
        for y in stride(from: 0, through: 6400, by: 800) {
            _ = try session.layout(in: CGRect(x: 0, y: y, width: 320, height: 1800))
        }
        let anchor = session.sourceOffset(at: 6800)
        let y = session.documentY(for: anchor)
        let before = session.retainedLineCount
        let snapshots = session.snapshotCount
        let start = SourcePerfTrace.now
        session.discardRenderingResources()
        let ms = (SourcePerfTrace.now - start) * 1000
        SourcePerfTrace.record("test.viewport.retire", "lines=\(before)", since: start, thresholdMs: 0)
        #expect(session.retainedLineCount == 0)
        #expect(session.retainedPaintResourceCount == 0)
        #expect(session.snapshotCount == snapshots, "retirement must not rebuild a paint snapshot")
        #expect(session.documentY(for: anchor) == y)
        _ = try session.layout(in: CGRect(x: 0, y: 6400, width: 320, height: 1800), anchorOffset: anchor)
        #expect(session.documentY(for: anchor) == y)
        #expect(session.retainedLineCount > 0)
        print("[RetainedGeometry] retirementMs=\(ms) lines=\(before)")
    }

    @Test func retainedNestedFloatRubyImagesAndDecorationsKeepExactPixels() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        let html = """
        <body style='background:#eee'><div style='border:2px solid red;padding:9px;margin:12px'>
        <p><span style='float:left;width:60px'>浮動 float</span>這是<ruby>漢字<rt>かんじ</rt></ruby><b>bold</b> English text。</p>
        <p style='text-indent:2em;margin:14px 0'>\(String(repeating: "文字 <span style='background:#afa;border:1px solid blue'>decorated</span> ", count: 22))</p>
        <img src='image.png' style='width:60px'/><p>\(String(repeating: "中文 é 👩🏽‍💻 ", count: 50))</p>
        </div></body>
        """
        let input = HTMLLayoutDocument(input: .currentCompatibility(html: html, cssTexts: []),
            configuration: BrowserLayoutConfig(renderWidth: 320, renderHeight: 800), imageLoader: { _ in image })
        let session = try input.makeViewportSession()
        let reference = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 6000))
        let passes = session.geometryPassCount
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        for y in [0, 300, 600, 900, 600, 300, 0] {
            let rect = CGRect(x: 0, y: y, width: 320, height: 600)
            let actual = try session.layout(in: rect)
            func pixels(_ document: BrowserScrollDocument) -> Data? {
                UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: rect.size))
                    document.items(in: rect).draw(in: context.cgContext)
                }.pngData()
            }
            #expect(try #require(pixels(actual)) == pixels(reference), "retained paint must be pixel-identical at y=\(y)")
        }
        #expect(session.geometryPassCount == passes)
    }

    @Test func missingOrRetiredLinesUseNormalGeometryTransaction() throws {
        let session = try makeSession()
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        let initial = session.geometryPassCount
        let offset = try #require(session.anchorOffsets["p150"])
        _ = try session.layout(in: CGRect(x: 0, y: session.documentY(for: offset), width: 320, height: 1800), anchorOffset: offset)
        #expect(session.geometryPassCount > initial)
        #expect(session.document.documentPoint(forCharOffset: offset) != nil)
        session.discardRenderingResources()
        let retired = session.geometryPassCount
        _ = try session.layout(in: CGRect(x: 0, y: session.documentY(for: offset), width: 320, height: 1800), anchorOffset: offset)
        #expect(session.geometryPassCount > retired)
        #expect(session.document.documentPoint(forCharOffset: offset) != nil)
    }

    @Test func intersectionIndexMatchesLinearSearchAcrossOverlapsAndUpdates() {
        let ranges: [ClosedRange<CGFloat>] = [0...50_000, 100...100, 100...160, -20...0]
            + (0..<2000).map { i in
                let start = CGFloat((i * 7919) % 40_000)
                return start...(start + CGFloat(i % 91))
            }
        var index = BrowserViewportIntervalIndex()
        for updated in [ranges, Array(ranges.reversed()), Array(ranges.dropFirst(29)), []] {
            index.update(updated)
            for start in stride(from: CGFloat(-30), through: 40_100, by: 71) {
                for length: CGFloat in [0, 1, 170] {
                    let query = start...(start + length)
                    let expected = updated.indices.filter { updated[$0].overlaps(query) }
                    #expect(index.intersecting(query) == expected)
                }
            }
        }
    }

    @Test func expirationReleasesOldPaintAndKeepsSurvivingIdentity() throws {
        let session = try makeSession()
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        func firstResource() -> TextDrawingResources? {
            for case .text(let item) in session.document.displayList.items {
                if let resource = item.preparedDrawing { return resource }
            }
            return nil
        }
        weak let old = firstResource()
        #expect(old != nil)
        _ = try session.layout(in: CGRect(x: 0, y: 600, width: 320, height: 1800))
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 320, height: 1800))
        #expect(firstResource() === old, "surviving entries must keep their drawing resource")
        let target = try #require(session.anchorOffsets["p150"])
        _ = try session.layout(in: CGRect(x: 0, y: session.documentY(for: target), width: 320, height: 1800), anchorOffset: target)
        #expect(old == nil, "the cache must actually release expired resources")
        #expect(session.retainedLineCount < 400)
        #expect(session.retainedPaintResourceCount < 400)
    }

    @Test func staleGeometryIndexWidthOrEntryVersionCannotReuseLines() throws {
        let text = String(repeating: "viewport 中文 ", count: 30)
        let style = ComputedStyle()
        let box = BlockBox(style: style, inlineRuns: [InlineRun(text: text, style: style,
            sourceRange: NSRange(location: 0, length: (text as NSString).length))])
        let state = BrowserViewportLayoutState()
        state.forceComplete = true
        _ = BlockLayout.layOut(root: box, containerWidth: 320, sourceText: text, viewport: state)
        state.updateGeometry(root: box, origin: .zero)
        state.forceComplete = false
        let rect = CGRect(x: 0, y: 0, width: 320, height: 200)
        let candidates = Array(state.geometry.values)
        let revision = state.geometryRevision
        #expect(state.restoreRetainedViewport(in: rect, anchor: 0, candidates: candidates, indexedRevision: revision))
        #expect(!state.restoreRetainedViewport(in: rect, anchor: 0, candidates: candidates, indexedRevision: revision &+ 1))
        let entry = try #require(state.entries[ObjectIdentifier(box)])
        let width = entry.width
        entry.width += 1
        #expect(!state.restoreRetainedViewport(in: rect, anchor: 0, candidates: candidates, indexedRevision: revision))
        entry.width = width
        entry.version &+= 1
        #expect(!state.restoreRetainedViewport(in: rect, anchor: 0, candidates: candidates, indexedRevision: revision))
    }
}
