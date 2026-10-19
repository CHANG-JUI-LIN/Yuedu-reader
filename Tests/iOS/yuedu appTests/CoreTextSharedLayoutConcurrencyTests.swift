@testable import yuedu_app
import YueduCoreText
import YueduCoreTextTypography
import CoreText
import Foundation
import os
import Testing
import UIKit

/// The paged reader renders an installed `ChapterLayout`'s pages from more than one thread
/// at once: `CoreTextPageEngine.prefetchPageImages` / `generateSnapshot` render a page on
/// the cooperative pool while the main thread draws the same page
/// (`CoreTextPageView.display` before the bitmap lands, `renderSnapshot` for the curl back
/// page) or hit-tests its lines (selection, annotation overlays, TTS highlight). Apple
/// documents Core Text layout objects as single-thread objects, so only the main thread
/// touches the layout's framesetter and frames; background renders go through
/// `CoreTextPagePrerenderer`, which lays pages out with a framesetter of its own. This suite
/// races exactly that:
/// every round paginates a never-drawn layout, releases main plus background threads on one
/// page at the same instant, and requires every bitmap and every line query to be one a
/// single thread could have produced.
///
/// What a single thread can produce is measured, not assumed: a ruby line answers line
/// queries differently before and after its first draw, so each page is also drawn and
/// queried in every serial order on independently paginated copies, and any of those
/// answers is legal.
///
/// Ruby is why: its line state is filled in lazily by draws and queries, and when the
/// background renders drew the main thread's own frames, two threads doing that at once
/// left a line drawing its annotation where no single thread ever puts it, for good —
/// 10 of 160 vertical ruby pages here. A frame per render laid out from the shared
/// framesetter was not enough: about half of all vertical ruby renders here went wrong.
/// Text without ruby never failed. Horizontal ruby is
/// not raced here: one thread drawing the same frame twice already moves the annotation,
/// so a whole-page bitmap cannot tell a race from that (2026-10-18 investigation note,
/// side-session-notes `shared-ctframe-concurrency`).
@Suite("CoreText shared layout concurrency", .serialized)
@MainActor
struct CoreTextSharedLayoutConcurrencyTests {
    private static let rounds = 40
    private static let workers = 6
    private nonisolated static let renderSize = CGSize(width: 360, height: 640)

    @Test(
        "a framesetter of the worker's own lays every page out as the layout did",
        arguments: [ReaderWritingMode.horizontal, .verticalRTL]
    )
    func ownFramesetterReproducesTheLayoutsPages(writingMode: ReaderWritingMode) async throws {
        let layout = await Self.paginate(Self.chapterText(round: 0, ruby: true), writingMode: writingMode)
        let fresh = await Self.paginate(Self.chapterText(round: 0, ruby: true), writingMode: writingMode)
        let framesetter = CoreTextFramesetterFactory.make(for: layout.attributedString)
        #expect(framesetter !== layout.framesetter)
        for page in layout.pageRanges.indices {
            let own = CoreTextPageView.makePageFrame(layout: layout, pageIndex: page, framesetter: framesetter)
            let artifact = layout.pageArtifacts[page].frame
            let ownRange = CTFrameGetVisibleStringRange(own)
            let artifactRange = CTFrameGetVisibleStringRange(artifact)
            #expect(ownRange.location == artifactRange.location && ownRange.length == artifactRange.length)
            #expect(CFArrayGetCount(CTFrameGetLines(own)) == CFArrayGetCount(CTFrameGetLines(artifact)))
            // Both drawn for the first time: identical pixels.
            #expect(Self.render(layout, page: page, frameSource: .own(own)) == Self.render(fresh, page: page), "page \(page)")
        }
    }

    @Test(
        "background renders racing the main thread's draws and queries of a page match a serial draw",
        arguments: zip([ReaderWritingMode.horizontal, .verticalRTL, .verticalRTL], [false, false, true])
    )
    func backgroundRendersRacingMainThreadMatchSerialDraw(writingMode: ReaderWritingMode, ruby: Bool) async throws {
        var raced = 0
        var mainDraws = 0
        var backgroundDraws = 0
        var serialQueryStateChanges = 0
        var serialImageStateChanges = 0
        // Warm the font caches first: the very first layout of these fonts in a process can
        // differ from later ones in a line width's ninth decimal.
        let warmUp = await Self.paginate(Self.chapterText(round: -1, ruby: ruby), writingMode: writingMode)
        for page in warmUp.pageRanges.indices { _ = Self.render(warmUp, page: page) }
        for round in 0..<Self.rounds {
            let text = Self.chapterText(round: round, ruby: ruby)
            let drawnFirst = await Self.paginate(text, writingMode: writingMode)
            let queriedFirst = await Self.paginate(text, writingMode: writingMode)
            let shared = await Self.paginate(text, writingMode: writingMode)
            try #require(drawnFirst.pageRanges.count > 1)
            #expect(shared.pageRanges.map(\.location) == drawnFirst.pageRanges.map(\.location))

            for page in 0..<min(4, shared.pageRanges.count) {
                // Every serial order a page goes through in the reader: drawn first, drawn
                // again, queried after a draw; queried first, then drawn.
                let firstDraw = Self.render(drawnFirst, page: page)
                let queryAfterOneDraw = Self.queryLines(drawnFirst.pageArtifacts[page].frame)
                let secondDraw = Self.render(drawnFirst, page: page)
                let warmQuery = Self.queryLines(drawnFirst.pageArtifacts[page].frame)
                let coldQuery = Self.queryLines(queriedFirst.pageArtifacts[page].frame)
                let drawAfterQuery = Self.render(queriedFirst, page: page)
                let queryAfterQueryAndDraw = Self.queryLines(queriedFirst.pageArtifacts[page].frame)
                let legalImages = [firstDraw, secondDraw, drawAfterQuery]
                let legalQueries = [coldQuery, queryAfterOneDraw, warmQuery, queryAfterQueryAndDraw]
                if Set(legalImages).count > 1 { serialImageStateChanges += 1 }
                if !legalQueries.allSatisfy({ Self.sameLines($0, coldQuery) }) { serialQueryStateChanges += 1 }

                let box = LayoutBox(layout: shared)
                let prerenderer = CoreTextPagePrerenderer()
                let results = Self.race(Self.workers) { _ in
                    // As in the reader: the main thread hit-tests (selection, TTS) and draws
                    // (display, curl snapshot) the page's own frame; the background renders
                    // the same page (prefetch, boundary snapshots) on the prerenderer.
                    guard Thread.isMainThread else {
                        return .background(Self.bytes(prerenderer.renderNow(.init(
                            layout: box.layout, pageIndex: page, size: Self.renderSize,
                            backgroundColor: UIColor.white.cgColor, bars: nil
                        ))))
                    }
                    let lines = Self.queryLines(box.layout.pageArtifacts[page].frame)
                    return .main(Self.render(box.layout, page: page), lines)
                }
                #expect(results.count == Self.workers)
                for result in results {
                    switch result {
                    case .background(let data):
                        backgroundDraws += 1
                        #expect(legalImages.contains(data), "round \(round) page \(page) background")
                    case .main(let data, let lines):
                        mainDraws += 1
                        #expect(legalImages.contains(data), "round \(round) page \(page) main")
                        // A line answers differently before and after its first draw, so
                        // legality is per line.
                        let illegal = lines.indices.filter { line in
                            !legalQueries.contains { Self.sameLine(lines[line], $0[line]) }
                        }
                        #expect(
                            lines.count == coldQuery.count && illegal.isEmpty,
                            "round \(round) page \(page) query lines \(illegal): \(illegal.prefix(2).map { Self.describeDifference(lines[$0], coldQuery[$0], warmQuery[$0]) })"
                        )
                    }
                }
                // The frame the race touched must still draw what a single thread draws.
                #expect(legalImages.contains(Self.render(shared, page: page)), "round \(round) page \(page) after race")
                raced += 1
            }
        }
        #expect(raced >= Self.rounds * 2)
        // The main thread must have been one of the racers, as it is in the reader.
        #expect(mainDraws > 0 && backgroundDraws > 0)
        print("SHARED_LAYOUT_RACE writingMode=\(writingMode) ruby=\(ruby) pages=\(raced) mainDraws=\(mainDraws) backgroundDraws=\(backgroundDraws) serialQueryStateChanges=\(serialQueryStateChanges) serialImageStateChanges=\(serialImageStateChanges)")
    }

    // MARK: - Helpers

    private enum RaceResult: Sendable {
        case background(Data)
        case main(Data, [[Double]])
    }

    /// `ChapterLayout` crosses into `concurrentPerform` the same way the reader hands it to
    /// `Task.detached` for prefetch: the very same instance, shared, unsynchronised.
    private struct LayoutBox: @unchecked Sendable {
        let layout: CoreTextPaginator.ChapterLayout
    }

    /// Runs `body` on `count` threads released at the same instant. Called from the main
    /// actor, so the main thread is one of them, as it is in the reader.
    private nonisolated static func race(
        _ count: Int,
        _ body: @escaping @Sendable (Int) -> RaceResult
    ) -> [RaceResult] {
        let arrived = OSAllocatedUnfairLock(initialState: 0)
        let results = OSAllocatedUnfairLock(initialState: [RaceResult?](repeating: nil, count: count))
        DispatchQueue.concurrentPerform(iterations: count) { worker in
            arrived.withLock { $0 += 1 }
            while arrived.withLock({ $0 }) < count {}
            let result = body(worker)
            results.withLock { $0[worker] = result }
        }
        return results.withLock { $0.compactMap { $0 } }
    }

    private static func paginate(
        _ text: NSAttributedString,
        writingMode: ReaderWritingMode
    ) async -> CoreTextPaginator.ChapterLayout {
        // A new paginator per call: its layout cache is per instance, so each call returns
        // a freshly built layout whose frames nothing has drawn yet.
        await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: text,
            renderSize: renderSize,
            fontSize: 18,
            contentInsets: UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20),
            writingMode: writingMode
        )
    }

    /// Through `CoreTextPageEngine.renderImage`, the app's page-to-bitmap path, so the
    /// main thread's draws and the prerenderer's are pixel-comparable.
    private nonisolated static func render(
        _ layout: CoreTextPaginator.ChapterLayout,
        page: Int,
        frameSource: CoreTextPageView.FrameSource = .layoutArtifact
    ) -> Data {
        bytes(CoreTextPageEngine.renderImage(
            layout: layout, pageIndex: page, size: renderSize,
            bgColor: UIColor.white.cgColor, bars: nil, frameSource: frameSource
        ))
    }

    private nonisolated static func bytes(_ image: UIImage) -> Data {
        image.cgImage!.dataProvider!.data! as Data
    }

    /// Line geometry from two independently paginated copies agrees to about 1e-9pt, not
    /// bit for bit; a race shows up as whole points (a misplaced ruby, a wrong image bound).
    private nonisolated static func sameLine(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-6 * max(1, abs($1)) }
    }

    private nonisolated static func sameLines(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { sameLine($0, $1) }
    }

    private nonisolated static func describeDifference(_ got: [Double], _ cold: [Double], _ warm: [Double]) -> String {
        let indices = got.indices.filter {
            $0 < cold.count && $0 < warm.count
                && abs(got[$0] - cold[$0]) > 1e-6 * max(1, abs(cold[$0]))
                && abs(got[$0] - warm[$0]) > 1e-6 * max(1, abs(warm[$0]))
        }
        return indices.prefix(4).map { "#\($0) got \(got[$0]) cold \(cold[$0]) warm \(warm[$0])" }.joined(separator: ", ")
    }

    /// The line queries the main thread runs on a page's frame for selection, annotation
    /// overlays and the TTS highlight.
    private nonisolated static func queryLines(_ frame: CTFrame) -> [[Double]] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        return lines.enumerated().map { index, line in
            var values: [Double] = [Double(origins[index].x), Double(origins[index].y)]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            values.append(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            values.append(Double(ascent))
            values.append(Double(descent))
            values.append(Double(CTLineGetTrailingWhitespaceWidth(line)))
            let imageBounds = CTLineGetImageBounds(line, nil)
            values.append(contentsOf: [imageBounds.minX, imageBounds.minY, imageBounds.width, imageBounds.height].map(Double.init))
            for x in stride(from: CGFloat(0), through: 320, by: 23) {
                values.append(Double(CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))))
            }
            let range = CTLineGetStringRange(line)
            for stringIndex in stride(from: range.location, to: range.location + range.length, by: 2) {
                var secondary: CGFloat = 0
                values.append(Double(CTLineGetOffsetForStringIndex(line, stringIndex, &secondary)))
                values.append(Double(secondary))
            }
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &positions)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(), &indices)
                values.append(positions.reduce(0) { $0 + Double($1.x) * 3 + Double($1.y) })
                values.append(Double(indices.reduce(0, +)))
                values.append(Double(CTRunGetImageBounds(run, nil, CFRange()).width))
            }
            return values
        }
    }

    /// Mixed-script chapter text in the shape `HTMLAttributedStringBuilder` produces: UIKit
    /// font and colour attributes, first-line indents, kerning, underlines, font fallback
    /// (emoji, Hangul, Arabic). Fixed colours keep the bitmaps free of trait resolution.
    private static func chapterText(round: Int, ruby: Bool) -> NSAttributedString {
        let paragraph = """
        第\(round)章　山雨欲來風滿樓。他說：「這是 CoreText 的測試，English words mixed in, 123,456.78!」\
        一段很長的中文段落，包含標點符號、引號『』與破折號——還有省略號……以及 emoji 😀👍🏽 和日文かなカナ。\
        한국어 문장도 있습니다. Ligatures: office final waffle. Arabic: مرحبا بالعالم.\n
        """
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 36
        style.lineSpacing = 6
        let text = NSMutableAttributedString()
        for index in 0..<14 {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: index % 5 == 3 ? UIFont.boldSystemFont(ofSize: 18) : UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor(red: 0.1, green: 0.1, blue: 0.1 + CGFloat(index % 3) * 0.2, alpha: 1),
                .backgroundColor: UIColor.white,
                .paragraphStyle: style,
                .kern: index % 4 == 0 ? 0.6 : 0,
            ]
            if index % 6 == 2 {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let piece = NSMutableAttributedString(string: paragraph, attributes: attributes)
            if ruby {
                // `<ruby>` as HTMLAttributedStringBuilder emits it, over the chapter number.
                piece.addAttribute(
                    HTMLAttributedStringBuilder.rubyAnnotationAttribute,
                    value: HTMLAttributedStringBuilder.makeRubyAnnotation(text: "ルビ"),
                    range: NSRange(location: 1, length: 2)
                )
            }
            text.append(piece)
        }
        return text
    }
}
