import CryptoKit
import Testing
import UIKit
@testable import YueduCoreText
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct ContinuousScrollCostTests {
    @Test func paragraphBoundaryAnchorBelongsToTheFollowingParagraph() throws {
        let html = "<body style='margin:0'><p style='margin:24px 0'>短</p>"
            + "<p id='second' style='margin:24px 0'>" + String(repeating: "後段文字", count: 30) + "</p></body>"
        let session = try HTMLLayoutDocument(html: html,
            configuration: BrowserLayoutConfig(renderWidth: 392, renderHeight: 810)).makeViewportSession()
        let offset = try #require(session.anchorOffsets["second"])
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 392, height: 2400))
        let painted = try #require(session.document.documentPoint(forCharOffset: offset))
        #expect(abs(session.documentY(for: offset) - painted.y) < 0.5)
        let before = session.documentY(for: offset)
        session.discardRenderingResources()
        #expect(session.documentY(for: offset) == before)
        _ = try session.layout(in: CGRect(x: 0, y: before, width: 392, height: 810), anchorOffset: offset)
        #expect(session.documentY(for: offset) == before)
    }

    @Test func viewportFontResourcesSurviveParagraphEvictionAndStaySessionLocal() throws {
        let html = "<body>" + (0..<80).map {
            "<p id='p\($0)'>" + String(repeating: "中文 identical font ", count: 30) + "</p>"
        }.joined() + "</body>"
        var config = BrowserLayoutConfig(renderWidth: 392, renderHeight: 810)
        var calls = 0
        config.fontResolver = { _, _, _, size in calls += 1; return UIFont.systemFont(ofSize: size) }
        let session = try HTMLLayoutDocument(html: html, configuration: config).makeViewportSession()
        _ = try session.layout(in: CGRect(x: 0, y: 0, width: 392, height: 2400))
        let initialCalls = calls
        #expect(initialCalls > 0)
        for paragraph in [50, 40, 30, 40, 0] {
            session.discardRenderingResources()
            let offset = try #require(session.anchorOffsets["p\(paragraph)"])
            _ = try session.layout(in: CGRect(x: 0, y: session.documentY(for: offset),
                width: 392, height: 2400), anchorOffset: offset)
            #expect(calls == initialCalls, "new paragraphs reuse the same final font")
        }
        let other = try HTMLLayoutDocument(html: html, configuration: config).makeViewportSession()
        _ = try other.layout(in: CGRect(x: 0, y: 0, width: 392, height: 2400))
        #expect(calls > initialCalls, "different sessions must not inherit publication fonts")
    }

    @Test func viewportFontCacheHasABoundAcrossAuthoredSizes() {
        let cache = InlineFontCache()
        for size in 1...256 {
            var style = ComputedStyle()
            style.fontSize = CGFloat(size)
            let font = cache.resolve(style) { UIFont.systemFont(ofSize: CGFloat(size)) }
            #expect(font.pointSize == CGFloat(size))
        }
        #expect(cache.count == 128)
    }

    @Test func repeatedOverlayUpdatesPreserveOutput() {
        let locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = ReaderOverlayContentSnapshot(bookTitle: "Book", chapterTitle: "Chapter",
            chapterPage: 3, chapterPageCount: 12, pageScope: .chapterBody, totalProgress: 0.257,
            now: Date(timeIntervalSince1970: 0), batteryLevel: 0.42, isCharging: false,
            readingDuration: 3661, estimatedRemainingTime: 732)
        let fields: [(ReaderOverlayComponentKind, ReaderOverlayDisplayFormat)] = [
            (.chapterPage, .fraction), (.totalProgressText, .percentage),
            (.currentTime, .hourMinute24), (.currentDate, .compact),
            (.weekday, .detailed), (.readingDuration, .compact)
        ]
        var result: [String] = []
        let start = SourcePerfTrace.now
        for _ in 0..<500 {
            result = fields.map { snapshot.text(for: $0.0, format: $0.1, locale: locale, calendar: calendar) }
        }
        SourcePerfTrace.record("test.scroll.overlay", "updates=500 fields=6", since: start, thresholdMs: 0)
        print("[ScrollCost] overlay500Ms=\((SourcePerfTrace.now - start) * 1000)")
        #expect(result == ["3/12", "25.7%", "00:00", "1/1/70", "Thursday", "1h 1m"])
    }

    @Test func unmeasuredReverseLayoutPreservesRasterAndAnchor() throws {
        let text = "春眠不覺曉，處處聞啼鳥。 English typography with words and punc\u{00AD}tuation 👨‍👩‍👧‍👦 e\u{0301} "
        let html = "<body>" + (0..<160).map {
            "<p id='p\($0)' style='margin:12px 0;letter-spacing:\($0.isMultiple(of: 3) ? "0.5px" : "normal")'>\($0) "
                + String(repeating: text, count: 4) + "</p>"
        }.joined() + "</body>"
        var config = BrowserLayoutConfig(renderWidth: 392, renderHeight: 810, rootFontSize: 20)
        config.defaultTextAlignment = .justified
        config.fontResolver = { _, _, _, size in UIFont.systemFont(ofSize: size) }
        let session = try HTMLLayoutDocument(html: html, configuration: config).makeViewportSession()
        var timings: [Double] = []
        for p in [100, 95, 90, 85, 80, 85, 90, 95, 100] {
            let offset = try #require(session.anchorOffsets["p\(p)"])
            let start = SourcePerfTrace.now
            let document = try session.layout(in: CGRect(x: 0, y: session.documentY(for: offset),
                width: 392, height: 4810), anchorOffset: offset)
            timings.append((SourcePerfTrace.now - start) * 1000)
            SourcePerfTrace.record("test.scroll.reverseLayout", "paragraph=\(p)", since: start, thresholdMs: 0)
            let y = session.documentY(for: offset)
            #expect(abs(session.sourceOffset(at: y + 1) - offset) < 60)
            #expect(document.documentPoint(forCharOffset: offset) != nil)
            let rect = CGRect(x: 0, y: y, width: 392, height: 810)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: rect.size))
                document.items(in: rect).draw(in: context.cgContext)
            }
            let bytes = try #require(image.pngData())
            print("[ScrollRaster] paragraph=\(p) sha256=\(SHA256.hash(data: bytes))")
        }
        print("[ScrollCost] reverseLayoutMs=\(timings)")
    }

    @Test func visibleTileDemandAvoidsDoublePrelayoutWithIdenticalVisiblePixels() throws {
        let html = "<body>" + (0..<160).map {
            "<p id='p\($0)' style='margin:12px 0'>\($0) "
                + String(repeating: "春眠不覺曉，處處聞啼鳥。", count: 24) + "</p>"
        }.joined() + "</body>"
        var config = BrowserLayoutConfig(renderWidth: 392, renderHeight: 810, rootFontSize: 20)
        config.defaultTextAlignment = .justified
        config.fontResolver = { _, _, _, size in UIFont.systemFont(ofSize: size) }
        var pixels: [Int: [Data]] = [:]
        for demandHeight in [Int(6610), 3240] {
            let session = try HTMLLayoutDocument(html: html, configuration: config).makeViewportSession()
            var timings: [Double] = []
            var shapes: [Int] = []
            for p in [100, 95, 90, 85, 80, 85, 90, 95, 100] {
                let offset = try #require(session.anchorOffsets["p\(p)"])
                let before = session.shapedLineCount
                let start = SourcePerfTrace.now
                let document = try session.layout(in: CGRect(x: 0,
                    y: session.documentY(for: offset) - CGFloat(demandHeight - 810) / 2,
                    width: 392, height: CGFloat(demandHeight)), anchorOffset: offset)
                timings.append((SourcePerfTrace.now - start) * 1000)
                shapes.append(session.shapedLineCount - before)
                SourcePerfTrace.record("test.scroll.demand", "height=\(demandHeight) paragraph=\(p)", since: start, thresholdMs: 0)
                let rect = CGRect(x: 0, y: session.documentY(for: offset), width: 392, height: 810)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: rect.size))
                    document.items(in: rect).draw(in: context.cgContext)
                }
                let data = try #require(image.pngData())
                let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-demand-\(demandHeight)-\(p)-\(timings.count).png")
                try data.write(to: imageURL)
                print("[ScrollDemandPixels] height=\(demandHeight) paragraph=\(p) y=\(rect.minY) offset=\(offset) image=\(imageURL.path)")
                pixels[demandHeight, default: []].append(data)
            }
            print("[ScrollDemand] height=\(demandHeight) ms=\(timings) shaped=\(shapes) retained=\(session.retainedLineCount)")
        }
        #expect(pixels[6610] == pixels[3240], "right-sized demand must not omit or shift visible text")
    }
}
