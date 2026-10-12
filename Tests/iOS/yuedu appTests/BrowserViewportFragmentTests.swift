@testable import YueduCoreText
import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
@MainActor
struct BrowserViewportFragmentTests {
    private func document(_ list: DisplayList, height: CGFloat = 4000) -> BrowserScrollDocument {
        BrowserScrollDocument(displayList: list, contentHeight: height, sourceText: "sample",
                              anchorOffsets: [:], linkAnchors: [:], contentWidth: 320)
    }
    private func lines(count: Int = 120, color: UIColor = .black) -> BrowserScrollDocument {
        let font = UIFont.systemFont(ofSize: 19)
        let items: [DisplayItem] = (0..<count).map { n in
            let text = "\(n) 中文 office fi Ágj"
            let value = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            return .text(.init(sourceRange: NSRange(location: n * 30, length: (text as NSString).length),
                nodeID: n + 1, linkTarget: nil, writingMode: .horizontal,
                rect: .init(rawValue: CGRect(x: 10.25, y: CGFloat(n) * 32 + 8.25, width: 260, height: 26)),
                baselineY: CGFloat(n) * 32 + 28.25, font: font, color: color, text: text,
                ctLine: CTLineCreateWithAttributedString(value),
                sourceMapping: .linear(shapedRange: NSRange(location: 0, length: value.length))))
        }
        return document(.init(items: items), height: CGFloat(count) * 32 + 40)
    }
    private func chapter(_ document: BrowserScrollDocument) -> BrowserScrollChapter {
        BrowserScrollChapter(spineIndex: 1, document: document, backgroundColor: .white, usesReaderBackground: false)
    }
    private func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }
    private func original(_ document: BrowserScrollDocument, size: CGSize) -> UIImage {
        renderer(size).image { r in
            UIColor.white.setFill(); r.fill(CGRect(origin: .zero, size: size))
            ReaderDisplayListDrawer.draw(document.displayList, in: r.cgContext)
        }
    }
    private func renderedHost(_ document: BrowserScrollDocument, size: CGSize) async -> UIImage {
        let host = ReaderViewportFragmentHost(frame: CGRect(origin: .zero, size: size))
        host.update([.init(chapter: chapter(document), origin: .zero, width: size.width)],
                    viewport: host.bounds, scale: 3)
        // Bitmaps are painted off the main thread; compose once they are installed.
        await host.waitForRasterIdle()
        #expect(host.mainThreadRasterCount == 0)
        return renderer(size).image { r in
            UIColor.white.setFill(); r.fill(CGRect(origin: .zero, size: size))
            host.layer.render(in: r.cgContext)
        }
    }
    private func bytes(_ image: UIImage) throws -> [UInt8] {
        let image = try #require(image.cgImage)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func compare(_ doc: BrowserScrollDocument, size: CGSize, name: String) async throws {
        let reference = original(doc, size: size), actual = await renderedHost(doc, size: size)
        let a = try bytes(reference), b = try bytes(actual)
        #expect(a.count == b.count)
        var sum = 0, different = 0, maximum = 0
        for (x, y) in zip(a, b) {
            let delta = abs(Int(x) - Int(y)); sum += delta; maximum = max(maximum, delta)
            if delta > 8 { different += 1 }
        }
        let mean = Double(sum) / Double(a.count), ratio = Double(different) / Double(a.count)
        print("[FragmentPixels] \(name) mean=\(mean) largeDifference=\(ratio) max=\(maximum)")
        if ratio >= 0.0001 {
            let root = FileManager.default.temporaryDirectory
            try reference.pngData()?.write(to: root.appendingPathComponent("fragment-" + name + "-before.png"))
            try actual.pngData()?.write(to: root.appendingPathComponent("fragment-" + name + "-after.png"))
            print("[FragmentPixelFiles] \(root.path) fragment-\(name)")
        }
        // Separate transparent backing stores can round premultiplied colors by
        // one level. Missing ink, seams or changed compositing exceed this bound.
        #expect(mean < 0.1, "\(name) average component difference")
        #expect(maximum <= 3, "\(name) only premultiplied-color rounding is allowed")
        #expect(ratio < 0.0001, "\(name) missing/clipped/double-painted pixels")
    }

    @Test func actualLayerCompositionPreservesRichTextAndCSSPaint() async throws {
        let html = """
        <body style='margin:0'><div style='margin:18px; padding:12px; border:3px dashed #348; border-radius:11px; background:#dfebee'>
        <p style='margin:0; font-size:23px'><ruby>漢字<rt>かんじ</rt></ruby> office ffi café <i>italic Ágj</i></p>
        <div style='float:left;width:82px;height:97px;background:#abc;border:2px dotted #931'>Float</div>
        <p style='line-height:1.6'>中文 around float <b>bold</b> <span style='background:#fc9'>inline background</span> 中文文字 English words 中文文字 English words 中文文字 English words 中文文字 English words</p>
        <div style='background:rgba(100,30,90,0.3);border:4px solid #358;padding:7px'>Nested <span style='color:#942'>foreground</span></div>
        </div></body>
        """
        let pipeline = try BrowserLayoutDocument(html: html, cssTexts: [], config: BrowserLayoutConfig())
            .makeLayout(containerSize: CGSize(width: 320, height: 900))
        let doc = BrowserScrollDocument.make(pipeline: pipeline, contentWidth: 320, contentInsets: .zero)
        try await compare(doc, size: CGSize(width: 320, height: ceil(doc.contentHeight + 4)), name: "ruby-float-css")
    }

    @Test func tallImageSubdivisionHasNoSeamOrScaleChange() async throws {
        let image = renderer(CGSize(width: 93, height: 171)).image { r in
            for y in 0..<171 {
                UIColor(red: CGFloat(y % 29) / 29, green: CGFloat(y % 41) / 41, blue: 0.4, alpha: 1).setFill()
                r.fill(CGRect(x: 0, y: y, width: 93, height: 1))
            }
        }
        let doc = document(.init(items: [.image(.init(source: "test", image: image,
            sourceRange: NSRange(location: 0, length: 1), nodeID: 1, linkTarget: nil,
            writingMode: .horizontal, rect: .init(rawValue: CGRect(x: 22.25, y: 11.25, width: 261.5, height: 2184.5)), alt: ""))]), height: 2220)
        let fragments = doc.paintFragments(in: CGRect(x: 0, y: 0, width: 320, height: 2220), scale: 3)
        #expect(fragments.count == 3)
        #expect(fragments.allSatisfy { $0.documentRect.height <= 1024 })
        try await compare(doc, size: CGSize(width: 320, height: 2220), name: "tall-image-seams")
    }

    /// Scroll mode paints a ruby line in several bitmaps — the annotation's baseline cuts
    /// the line's run of items — so a quote around a ruby word drew one frame per bitmap
    /// (和蘭人形, 2026-10-12). Each bitmap now paints its share of one box, seamlessly.
    @Test func highlightAroundRubyIsOneBoxAcrossFragments() async throws {
        let red = ReaderStyleBorder(width: 2, colorHex: 0xFF0000)
        let style = ReaderStyleRuleStyle(decoration: ReaderStyleDecorationStyle(
            padding: .init(top: 2, leading: 6, bottom: 2, trailing: 6),
            borders: [.leading: red, .trailing: red]
        ))
        let rules = RegexHighlightConfiguration(isEnabled: true, rules: [], customRules: [RegexHighlightRule(
            id: "ruby-frame", name: "frame", pattern: "「[^」]*」", isEnabled: true, isBuiltIn: false,
            options: [], lightStyle: style, darkStyle: style
        )])
        let config = BrowserLayoutConfig(textTransform: BrowserReaderAttributes.transform(
            configuration: rules, appearance: .light, assetRevision: 0
        ))
        // A paragraph follows: the chapter view clips at the content height, which would
        // cut the padding of a box on the chapter's last line in either rendering.
        let html = "<body style='margin:0'><p style='margin:20px'>前「<ruby>卑怯者<rt>ひきょうもの</rt></ruby>、な、名乗れ」後</p><p>次</p></body>"
        let pipeline = try BrowserLayoutDocument(html: html, cssTexts: [], config: config)
            .makeLayout(containerSize: CGSize(width: 320, height: 200))
        let doc = BrowserScrollDocument.make(pipeline: pipeline, contentWidth: 320, contentInsets: .zero)
        let size = CGSize(width: 320, height: ceil(doc.contentHeight + 4))
        // 前「卑怯者 | ひきょうもの | 、な、名乗れ」後 | 次: the annotation cuts the quote's line.
        let glyphs = doc.paintFragments(in: CGRect(origin: .zero, size: size), scale: 3)
            .filter { $0.textPaintPhase == .glyphs }
        #expect(glyphs.count >= 4, "the ruby must split the line into several fragments")

        #expect(try maximumRedRunsPerRow(await renderedHost(doc, size: size)) == 2)
        // The bitmaps meet without a seam: the same pixels as one whole-page draw.
        try await compare(doc, size: size, name: "ruby-highlight-box")
    }

    private func maximumRedRunsPerRow(_ image: UIImage) throws -> Int {
        let pixels = try bytes(image)
        let width = try #require(image.cgImage).width
        return stride(from: 0, to: pixels.count, by: width * 4).map { row in
            var runs = 0
            var inRun = false
            for x in 0..<width {
                let i = row + x * 4
                let isRed = pixels[i] > 200 && pixels[i + 1] < 60 && pixels[i + 2] < 60
                if isRed, !inRun { runs += 1 }
                inRun = isRed
            }
            return runs
        }.max() ?? 0
    }

    @Test func overlappingRuleDecorationsStayUnderAllGlyphsIncludingShadows() async throws {
        let font = UIFont.systemFont(ofSize: 22)
        let style = ReaderStyleDecorationStyle(backgroundColorHex: 0xFFCC66,
            padding: .init(top: 16, leading: 18, bottom: 16, trailing: 18),
            cornerRadius: 5, shadows: [.init(colorHex: 0x773399, radius: 3, x: 5, y: 7)])
        let items: [DisplayItem] = (0..<3).map { n in
            let text = "Overlapping \(n)"
            let attributes = NSAttributedString(string: text, attributes: [.font: font,
                RegexHighlightDecoration.attributeKey: RegexHighlightDecoration(style: style, assetRevision: 0)])
            return .text(.init(sourceRange: NSRange(location: n * 20, length: attributes.length), nodeID: n + 1,
                linkTarget: nil, writingMode: .horizontal,
                rect: .init(rawValue: CGRect(x: 42, y: 45 + n * 28, width: 210, height: 27)),
                baselineY: CGFloat(67 + n * 28), font: font, color: .black, text: text,
                ctLine: CTLineCreateWithAttributedString(attributes),
                sourceMapping: .linear(shapedRange: NSRange(location: 0, length: attributes.length))))
        }
        try await compare(document(.init(items: items), height: 190), size: CGSize(width: 320, height: 190), name: "overlapping-decorations")
    }

    @Test func moderateForwardAndReverseMotionReusesContentAcrossOldTileBoundary() async {
        let chapter = chapter(lines())
        let host = ReaderViewportFragmentHost(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        let input = ReaderViewportFragmentHost.Input(chapter: chapter, origin: .zero, width: 320)
        func scroll(_ y: CGFloat) { host.update([input], viewport: CGRect(x: 0, y: y, width: 320, height: 600), scale: 3) }
        // Let each warm-up bitmap arrive: one still in flight when the next jump
        // leaves it behind is cancelled, and requested again when it returns.
        for y: CGFloat in [400, 800, 400] {
            scroll(y)
            await host.waitForRasterIdle()
        }
        let baseline = host.redrawCount
        let resident = host.visibleSurfaces.map { ($0, $0.drawCount) }
        let identities = Dictionary(uniqueKeysWithValues: host.visibleSurfaces.compactMap { s in s.fragment.map { ($0.id, ObjectIdentifier(s)) } })
        let orders = Dictionary(uniqueKeysWithValues: host.visibleSurfaces.compactMap { s in s.fragment.map { ($0.id, $0.paintOrder) } })
        for y in stride(from: CGFloat(400), through: 800, by: 10) { scroll(y) }
        for y in stride(from: CGFloat(800), through: 400, by: -10) { scroll(y) }
        await host.waitForRasterIdle()
        // Resident text keeps its bitmap. Painting ahead in the direction of travel
        // may still request the few lines that the far end of this range had
        // pushed out of retention (one screen around the viewport).
        print("[FragmentReuse] requestsWhileCrossing=\(host.redrawCount - baseline)")
        let visible = host.visibleSurfaces
        #expect(visible.allSatisfy { $0.hasRaster })
        for (surface, draws) in resident {
            #expect(visible.contains { $0 === surface }, "the same position shows the same surfaces")
            #expect(surface.drawCount == draws, "crossing a 600pt interaction tile must not redraw resident text")
        }
        for s in host.visibleSurfaces {
            if let id = s.fragment?.id, let old = identities[id] { #expect(old == ObjectIdentifier(s)) }
            if let id = s.fragment?.id, let order = orders[id] { #expect(s.fragment?.paintOrder == order) }
        }
        #expect(host.visibleSurfaces.count > 10)
        #expect(host.estimatedBackingBytes < ReaderViewportFragmentHost.retainedByteLimit)
    }

    @Test func evictionReentryMemoryPressureAndReplacementKeepOnlyCurrentOwners() throws {
        let chapter = chapter(lines(count: 200))
        let host = ReaderViewportFragmentHost()
        let input = ReaderViewportFragmentHost.Input(chapter: chapter, origin: .zero, width: 320)
        func scroll(_ y: CGFloat) { host.update([input], viewport: CGRect(x: 0, y: y, width: 320, height: 600), scale: 3) }
        autoreleasepool { scroll(0); CATransaction.flush() }
        let firstIDs = Set(host.visibleSurfaces.compactMap { $0.fragment?.id })
        weak var expired: BrowserFragmentSurface?
        autoreleasepool { expired = host.visibleSurfaces.first }
        autoreleasepool { scroll(4000); CATransaction.flush() }
        #expect(expired == nil, "retired surfaces must release their CTLine/backing stores")
        #expect(host.evictedCount > 0)
        scroll(0)
        #expect(Set(host.visibleSurfaces.compactMap { $0.fragment?.id }) == firstIDs)
        scroll(300)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(host.retainedSurfaceCount == host.visibleSurfaces.count)
        #expect(host.retainedSurfaceCount <= ReaderViewportFragmentHost.retainedSurfaceLimit)
        let replacement = self.chapter(lines(color: .red))
        weak var old: BrowserFragmentSurface?
        autoreleasepool { old = host.visibleSurfaces.first }
        autoreleasepool { host.update([.init(chapter: replacement, origin: .zero, width: 320)],
                    viewport: CGRect(x: 0, y: 0, width: 320, height: 600), scale: 3); CATransaction.flush() }
        #expect(old == nil)
        #expect(host.visibleSurfaces.allSatisfy { surface in
            surface.fragment?.displayList.items.allSatisfy { if case .text(let t) = $0 { return t.color == .red }; return true } == true
        })
        host.reset()
        #expect(host.retainedSurfaceCount == 0 && host.subviews.isEmpty)
    }

    @Test func positionOnlyMovesSurfaceButActualPaintAndScaleChangesRedraw() throws {
        let doc = lines(count: 1)
        let demand = CGRect(x: 0, y: 0, width: 320, height: 600)
        let first = try #require(doc.paintFragments(in: demand, scale: 3).first)
        let translated = document(doc.displayList.items(in: CGRect(x: 0, y: -90, width: 320, height: 600), filteringItems: false))
        let moved = try #require(translated.paintFragments(in: demand, scale: 3).first)
        #expect(first.id == moved.id)
        let surface = BrowserFragmentSurface()
        #expect(surface.configure(first, scale: 3, skipBackground: false))
        #expect(!surface.configure(moved, scale: 3, skipBackground: false))
        #expect(abs(surface.frame.minY - first.documentRect.minY - 90) < 0.001)
        #expect(surface.configure(moved, scale: 2, skipBackground: false))
        let recolored = try #require(lines(count: 1, color: .red).paintFragments(in: demand, scale: 3).first)
        #expect(surface.configure(recolored, scale: 3, skipBackground: false))
        #expect(surface.configure(recolored, scale: 3, skipBackground: true))
    }

    /// EPUB chapters on the browser engine: a scroll update only asks for
    /// bitmaps; the worker paints them. Visible text is blank until its bitmap
    /// arrives (the chosen trade-off), and nothing is painted on the main thread.
    @Test func browserFragmentsArePaintedOffTheMainThread() async {
        let host = ReaderViewportFragmentHost(frame: CGRect(x: 0, y: 0, width: 320, height: 4000))
        let input = ReaderViewportFragmentHost.Input(chapter: chapter(lines()), origin: .zero, width: 320)
        let viewport = CGRect(x: 0, y: 300, width: 320, height: 600)
        host.update([input], viewport: viewport, scale: 3)
        #expect(!host.visibleSurfaces.isEmpty)
        #expect(host.visibleSurfaces.allSatisfy { $0.fragment != nil && !$0.hasRaster })
        #expect(host.lateFragmentCount > 0)
        let requests = host.redrawCount
        await host.waitForRasterIdle()
        #expect(host.visibleSurfaces.allSatisfy { $0.hasRaster })
        #expect(host.mainThreadRasterCount == 0)
        host.update([input], viewport: viewport, scale: 3)
        #expect(host.lateFragmentCount == 0)
        #expect(host.redrawCount == requests, "an installed bitmap is not requested again")
    }

    /// Core Text layout objects are used by one thread at a time. The worker
    /// draws with lines of its own, built from the same drawing text: the
    /// prepared lines stay with the main thread's paint-bounds queries.
    @Test func workerDrawsWithItsOwnTextLinesAndIdenticalPixels() throws {
        let fragments = lines(count: 6).paintFragments(in: CGRect(x: 0, y: 0, width: 320, height: 600), scale: 3)
        let texts = fragments.filter { $0.displayList.items.contains { if case .text = $0 { true } else { false } } }
        #expect(texts.count >= 6)
        for fragment in texts {
            let own = fragment.displayListWithOwnTextLines()
            #expect(own.items.count == fragment.displayList.items.count)
            for (shared, copy) in zip(fragment.displayList.items, own.items) {
                guard case .text(let a) = shared, case .text(let b) = copy else { continue }
                let prepared = try #require(a.preparedDrawing), mine = try #require(b.preparedDrawing)
                #expect(prepared.line !== mine.line)
                #expect(prepared.attributed === mine.attributed)
            }
            let size = fragment.renderingRect.size
            let draw = { (list: DisplayList) in
                self.renderer(size).image { r in
                    ReaderDisplayListDrawer.draw(list, in: r.cgContext, textPaintPhase: fragment.textPaintPhase)
                }
            }
            #expect(try bytes(draw(own)) == bytes(draw(fragment.displayList)))
        }
    }
}
