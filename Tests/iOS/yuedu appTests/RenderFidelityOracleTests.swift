import CoreText
import Foundation
import Testing
import UIKit
import WebKit
@testable import YueduCoreText
@testable import yuedu_app

/// Opt-in capture for the render-fidelity oracle: the same EPUB chapter laid out
/// by the production scroll route (`.browserAuto`, including its Legacy fallback)
/// and by a WKWebView reference, each written as one geometry dump plus a coarse
/// pixel grid. `scripts/fidelity/fidelity.py` scores the pair; nothing here decides
/// a score. Contract: `docs/browser-layout/fidelity-loop/ORACLE.md`.
///
/// Frozen: `scripts/fidelity/oracle.lock` pins this file.
/// Ordinary test runs do nothing — the plan path arrives through the environment.
@Suite(.serialized)
@MainActor
struct RenderFidelityOracleTests {
    @Test func captureRenderFidelity() async throws {
        guard let planPath = ProcessInfo.processInfo.environment["YUEDU_FIDELITY_PLAN"] else { return }
        let plan = try JSONDecoder().decode(FidelityPlan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        // Font fallback and punctuation follow the process language on both
        // sides: the same chapter breaks its lines differently under another one.
        guard FidelityProfile.language.hasPrefix(plan.language) else {
            throw FidelityError.message("the test process runs in '\(FidelityProfile.language)'; the plan asks for "
                                        + "'\(plan.language)' (xcodebuild -testLanguage / -testRegion)")
        }
        let refKey = FidelityProfile.referenceKey
        let runRoot = URL(fileURLWithPath: plan.out).appendingPathComponent("runs").appendingPathComponent(plan.run)
        let refRoot = URL(fileURLWithPath: plan.out).appendingPathComponent("ref").appendingPathComponent(refKey)
        var index: [[String: Any]] = []
        var captured = 0
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let indexFile = runRoot.appendingPathComponent("capture-index.json")
        // Rewritten after every chapter: a run that dies part-way still says what it measured.
        func writeIndex(complete: Bool) throws {
            let summary: [String: Any] = ["schema": 1, "run": plan.run, "refKey": refKey, "complete": complete,
                                          "profile": FidelityProfile.description, "chapters": index]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: indexFile, options: .atomic)
        }
        try writeIndex(complete: false)

        for book in plan.books {
            let session: PublicationSession
            do {
                session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: book.epub))
            } catch {
                index.append(["book": book.id, "error": "open failed: \(error)"])
                print("FIDELITY book=\(book.id) open failed: \(error)")
                try writeIndex(complete: false)
                continue
            }
            let vertical = session.epubWritingMode == .verticalRL
            var web: FidelityWebReference?
            for chapter in FidelityPlan.sample(count: session.chapters.count, book: book, sets: plan.sets) {
                let href = session.chapters[chapter.spine].href
                var entry: [String: Any] = ["book": book.id, "spine": chapter.spine, "set": chapter.set, "href": href]
                let refDirectory = refRoot.appendingPathComponent(book.id).appendingPathComponent("\(chapter.spine)")
                let runDirectory = runRoot.appendingPathComponent(book.id).appendingPathComponent("\(chapter.spine)")
                print("FIDELITY-START book=\(book.id) spine=\(chapter.spine)")
                if plan.sides.contains("webkit"),
                   !FileManager.default.fileExists(atPath: refDirectory.appendingPathComponent("dump.json").path) {
                    do {
                        let file = try FidelityCorpus.chapterFile(root: book.root, href: href)
                        if web == nil { web = FidelityWebReference(viewport: FidelityProfile.viewport(vertical: vertical)) }
                        let start = Date()
                        try await web!.capture(file: file, root: URL(fileURLWithPath: book.root),
                                               identity: (book.id, chapter.spine, href),
                                               directory: refDirectory, saveTiles: plan.saveTiles)
                        entry["webkitMs"] = Date().timeIntervalSince(start) * 1000
                    } catch {
                        entry["webkitError"] = "\(error)"
                        // A reference that failed half-way must not look like a cached one.
                        if FileManager.default.fileExists(atPath: refDirectory.path) {
                            do {
                                try FileManager.default.removeItem(at: refDirectory)
                            } catch {
                                entry["webkitError"] = "\(entry["webkitError"] ?? ""); partial reference not removed: \(error)"
                            }
                        }
                        web?.discard()
                        web = nil
                    }
                }
                if plan.sides.contains("engine") {
                    do {
                        let start = Date()
                        let route = try await FidelityEngineCapture.capture(
                            session: session, vertical: vertical,
                            identity: (book.id, chapter.spine, href),
                            directory: runDirectory, saveTiles: plan.saveTiles)
                        entry["engineMs"] = Date().timeIntervalSince(start) * 1000
                        entry["route"] = route
                        captured += 1
                    } catch {
                        entry["engineError"] = "\(error)"
                    }
                }
                print("FIDELITY book=\(book.id) spine=\(chapter.spine) \(entry["route"] ?? "-") "
                      + "web=\(entry["webkitError"] ?? entry["webkitMs"] ?? "cached") engine=\(entry["engineError"] ?? entry["engineMs"] ?? "-")")
                index.append(entry)
                try writeIndex(complete: false)
            }
            web?.discard()
        }

        try writeIndex(complete: true)
        print("FIDELITY-INDEX \(indexFile.path)")
        if plan.sides.contains("engine") { #expect(captured > 0, "no chapter was captured") }
    }
}

// MARK: - Plan and profile

private struct FidelityPlan: Decodable {
    struct Book: Decodable {
        let id: String
        let epub: String
        let root: String
        let dev: Int
        let holdout: Int
        let pinned: [Int]
        /// Explicit spine indices; replaces the sample when present.
        let only: [Int]?
    }
    let out: String
    let run: String
    /// The language every capture of this plan runs in, e.g. `zh-Hant`.
    let language: String
    let sides: [String]
    let sets: [String]
    let saveTiles: Int
    let books: [Book]

    /// The chapter sample, from the chapter list the reader itself uses.
    /// `dev`: pinned chapters plus evenly spaced ones, both ends included.
    /// `holdout`: the midpoints between them, never a `dev` chapter. Fixes are
    /// tuned against `dev`; `holdout` exists to catch a fix that only fits it.
    static func sample(count: Int, book: Book, sets: [String]) -> [(spine: Int, set: String)] {
        guard count > 0 else { return [] }
        if let only = book.only {
            return Set(only).filter { (0..<count).contains($0) }.sorted().map { ($0, "only") }
        }
        var dev = Set(book.pinned.filter { (0..<count).contains($0) })
        let devTarget = min(count, book.dev)
        if devTarget == 1 { dev.insert(0) }
        if devTarget > 1 {
            for step in 0..<devTarget {
                dev.insert(Int((Double(step) * Double(count - 1) / Double(devTarget - 1)).rounded()))
            }
        }
        var holdout = Set<Int>()
        let holdoutTarget = min(max(0, count - dev.count), book.holdout)
        for step in 0..<holdoutTarget {
            let start = min(count - 1, Int(((Double(step) + 0.5) * Double(count - 1) / Double(holdoutTarget)).rounded()))
            var probe = start
            while dev.contains(probe) || holdout.contains(probe) {
                probe = (probe + 1) % count
                if probe == start { break }
            }
            if !dev.contains(probe), !holdout.contains(probe) { holdout.insert(probe) }
        }
        var result: [(spine: Int, set: String)] = []
        if sets.contains("dev") { result += dev.map { ($0, "dev") } }
        if sets.contains("holdout") { result += holdout.map { ($0, "holdout") } }
        return result.sorted { $0.spine < $1.spine }
    }
}

/// One neutral reading profile for both sides. The reader's typographic defaults
/// are the root's inherited values in the engine (`ComputedStyleTreeBuilder.buildTree`),
/// so the reference gets the same values as the first, lowest-priority author rule:
/// any publication rule still overrides them on either side.
private enum FidelityProfile {
    static let screen = CGSize(width: 390, height: 800)
    static let margin: CGFloat = 12
    static let fontSize: CGFloat = 17
    static let lineHeight: CGFloat = 1.5
    static let cell = 4
    static let bitmapScale: CGFloat = 2
    static let extractorVersion = 2

    /// The language the process lays text out in (`-testLanguage`), whatever the
    /// simulator is set to.
    static var language: String { Locale.preferredLanguages.first ?? "" }

    /// What the scroll host lays a chapter out in: the screen between the side
    /// margins at its full height or, in vertical writing, the full width at the
    /// height between the margins (`CoreTextCollectionScrollViewController`).
    static func viewport(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: screen.width, height: screen.height - 2 * margin)
                 : CGSize(width: screen.width - 2 * margin, height: screen.height)
    }

    /// The reader's scroll-surface settings with every optional typographic
    /// override at its neutral value, so only publication CSS separates the two sides.
    static func settings(vertical: Bool) -> ReaderRenderSettings {
        var settings = ReaderRenderSettings(
            theme: "fidelity", textColor: .black, backgroundColor: .white,
            fontSize: fontSize, lineHeightMultiple: lineHeight, lineSpacing: 0, paragraphSpacing: 0,
            letterSpacing: 0, marginH: margin, marginV: margin, footerHeight: ReaderLayoutMetrics.footerHeight,
            contentInsets: UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin))
        settings.writingMode = vertical ? .verticalRTL : .horizontal
        return settings
    }

    /// The reader's own defaults, and nothing else:
    /// - `InlineLayout.resolvedFont` starts from PingFangSC-Regular when neither the
    ///   reader nor the publication names a family; `makeBrowserConfig` justifies by default.
    /// - `BlockLayout.resolveReplacedSize` never lets an image exceed its container
    ///   and keeps its proportions, as every reading system does.
    static let referenceCSS = "html{font-size:\(Int(fontSize))px;line-height:\(Double(lineHeight));text-align:justify;"
        + "font-family:\"PingFang SC\";-webkit-text-size-adjust:100%;text-size-adjust:100%}"
        + "img{max-width:100%;height:auto}svg,video{max-width:100%}"

    @MainActor static var description: [String: Any] {
        ["screenWidth": Double(screen.width), "screenHeight": Double(screen.height), "margin": Double(margin),
         "fontSize": Double(fontSize),
         "lineHeight": Double(lineHeight), "cell": cell, "referenceCSS": referenceCSS,
         "system": UIDevice.current.systemVersion, "extractor": extractorVersion, "language": language]
    }

    /// Names the reference cache: a reference is reusable only under the same
    /// profile, extractor, language and system WebKit.
    @MainActor static var referenceKey: String {
        var hash: UInt64 = 0xcbf29ce484222325
        let seed = "\(screen)|\(margin)|\(fontSize)|\(lineHeight)|\(cell)|\(referenceCSS)|\(extractorVersion)|\(language)"
            + "|\(FidelityWebReference.bootstrapSource)|\(FidelityWebReference.extractorSource)"
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "ios\(UIDevice.current.systemVersion)-\(String(hash, radix: 16))"
    }
}

private enum FidelityError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "" }
}

private enum FidelityCorpus {
    static func chapterFile(root: String, href: String) throws -> URL {
        let base = URL(fileURLWithPath: root)
        for candidate in [href, href.removingPercentEncoding ?? href] {
            let url = base.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw FidelityError.message("extracted chapter file missing for \(href)")
    }
}

// MARK: - Pixel grid

/// RGBA, top row first.
private struct FidelityBitmap {
    let width: Int
    let height: Int
    let scale: CGFloat
    var data: [UInt8]

    static func make(pointSize: CGSize, scale: CGFloat, draw: (CGContext) -> Void) throws -> FidelityBitmap {
        let width = max(1, Int((pointSize.width * scale).rounded(.up)))
        let height = max(1, Int((pointSize.height * scale).rounded(.up)))
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            UIGraphicsPushContext(context)
            draw(context)
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { throw FidelityError.message("bitmap context unavailable for \(pointSize)") }
        return FidelityBitmap(width: width, height: height, scale: scale, data: data)
    }

    func jpeg() -> Data? {
        let provider = CGDataProvider(data: Data(data) as CFData)
        guard let provider, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up).jpegData(compressionQuality: 0.6)
    }
}

/// Per 4pt cell: mean colour, then the colour most pixels share. The second one
/// is the paper under text, which is what a missing background changes.
private struct FidelityGrid {
    let cols: Int
    let rows: Int
    private(set) var bytes: [UInt8]

    init(documentSize: CGSize) {
        cols = max(1, Int((documentSize.width / CGFloat(FidelityProfile.cell)).rounded(.up)))
        rows = max(1, Int((documentSize.height / CGFloat(FidelityProfile.cell)).rounded(.up)))
        bytes = [UInt8](repeating: 255, count: cols * rows * 6)
    }

    /// Tiles a document with viewport-sized windows whose origins sit on cell
    /// boundaries and overlap by one cell, so every cell lies wholly inside one.
    static func tileOrigins(documentSize: CGSize, viewport: CGSize, vertical: Bool) -> [CGPoint] {
        let cell = CGFloat(FidelityProfile.cell)
        let extent = vertical ? documentSize.width : documentSize.height
        let window = vertical ? viewport.width : viewport.height
        let last = max(0, ((extent - window) / cell).rounded(.down) * cell)
        let step = max(cell, (window / cell).rounded(.down) * cell - cell)
        var offsets: [CGFloat] = []
        var offset: CGFloat = 0
        while offset < last { offsets.append(offset); offset += step }
        offsets.append(last)
        return offsets.map { vertical ? CGPoint(x: $0, y: 0) : CGPoint(x: 0, y: $0) }
    }

    mutating func accumulate(_ bitmap: FidelityBitmap, origin: CGPoint) {
        let cell = FidelityProfile.cell
        let pixelsPerCell = Int(bitmap.scale) * cell
        let firstCol = Int(origin.x) / cell, firstRow = Int(origin.y) / cell
        let lastDocCol = cols - 1, lastDocRow = rows - 1
        var histogram = [UInt16](repeating: 0, count: 512)
        var touched: [Int] = []
        touched.reserveCapacity(pixelsPerCell * pixelsPerCell)
        bitmap.data.withUnsafeBufferPointer { pixels in
            var cellRow = 0
            while cellRow * pixelsPerCell < bitmap.height {
                defer { cellRow += 1 }
                let row = firstRow + cellRow
                guard row <= lastDocRow else { break }
                let y0 = cellRow * pixelsPerCell, y1 = min(bitmap.height, y0 + pixelsPerCell)
                // A cell cut by the tile edge belongs to the neighbouring tile,
                // unless the document itself ends there.
                if y1 - y0 < pixelsPerCell, row != lastDocRow { continue }
                var cellCol = 0
                while cellCol * pixelsPerCell < bitmap.width {
                    defer { cellCol += 1 }
                    let col = firstCol + cellCol
                    guard col <= lastDocCol else { break }
                    let x0 = cellCol * pixelsPerCell, x1 = min(bitmap.width, x0 + pixelsPerCell)
                    if x1 - x0 < pixelsPerCell, col != lastDocCol { continue }
                    var red = 0, green = 0, blue = 0, count = 0
                    touched.removeAll(keepingCapacity: true)
                    for y in y0..<y1 {
                        var offset = (y * bitmap.width + x0) * 4
                        for _ in x0..<x1 {
                            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                            red += r; green += g; blue += b; count += 1
                            let key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)
                            if histogram[key] == 0 { touched.append(key) }
                            histogram[key] += 1
                            offset += 4
                        }
                    }
                    guard count > 0 else { continue }
                    var mode = touched[0]
                    for key in touched where histogram[key] > histogram[mode] { mode = key }
                    var modeRed = 0, modeGreen = 0, modeBlue = 0, modeCount = 0
                    for y in y0..<y1 {
                        var offset = (y * bitmap.width + x0) * 4
                        for _ in x0..<x1 {
                            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                            if (((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)) == mode {
                                modeRed += r; modeGreen += g; modeBlue += b; modeCount += 1
                            }
                            offset += 4
                        }
                    }
                    for key in touched { histogram[key] = 0 }
                    let base = (row * cols + col) * 6
                    bytes[base] = UInt8(red / count)
                    bytes[base + 1] = UInt8(green / count)
                    bytes[base + 2] = UInt8(blue / count)
                    bytes[base + 3] = UInt8(modeRed / max(1, modeCount))
                    bytes[base + 4] = UInt8(modeGreen / max(1, modeCount))
                    bytes[base + 5] = UInt8(modeBlue / max(1, modeCount))
                }
            }
        }
    }

    var descriptor: [String: Any] { ["size": FidelityProfile.cell, "cols": cols, "rows": rows, "file": "cells.bin"] }
}

private enum FidelityOutput {
    static func number(_ value: CGFloat) -> Double {
        value.isFinite ? (Double(value) * 100).rounded() / 100 : 0
    }

    static func hex(_ color: UIColor) -> (String, Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return ("000000", 1) }
        func channel(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
        return (String(format: "%02x%02x%02x", channel(red), channel(green), channel(blue)), Double(alpha))
    }

    static func write(dump: [String: Any], grid: FidelityGrid, tiles: [Data], directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dump = dump
        var names: [String] = []
        for (index, data) in tiles.enumerated() {
            let name = String(format: "tile-%03d.jpg", index)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }
        dump["tiles"] = names
        dump["cells"] = grid.descriptor
        try Data(grid.bytes).write(to: directory.appendingPathComponent("cells.bin"), options: .atomic)
        // Written last: its presence marks a complete capture.
        try JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("dump.json"), options: .atomic)
    }
}

// MARK: - Engine side

@MainActor
private enum FidelityEngineCapture {
    /// Returns the route label (`browser` / `legacy: …`).
    static func capture(session: PublicationSession, vertical: Bool, identity: (book: String, spine: Int, href: String),
                        directory: URL, saveTiles: Int) async throws -> String {
        let start = Date()
        let settings = FidelityProfile.settings(vertical: vertical)
        let viewport = FidelityProfile.viewport(vertical: vertical)
        let screen = FidelityProfile.screen
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: screen)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
                                        offsetStore: CharOffsetStore(directoryURL: scratch))
        legacy.applyThemeChange(textColor: settings.textColor, backgroundColor: settings.backgroundColor)
        let resource = EPUBBrowserLayoutResourceAdapter(session: session)
        let auto = BrowserLayoutPageEngine(resource: resource, delegate: legacy, settings: settings,
                                           mode: .browserAuto, showDebugOverlay: false)
        defer { auto.cancelPendingWork(); legacy.cancelPendingWork() }
        let scroll = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        auto.usesViewportScrolling = true
        await auto.start(renderSize: screen, bookId: UUID().uuidString)
        scroll.browserAutoEngine = auto
        // As the scroll host calls it: `contentWidth` is the extent along a line.
        await scroll.start(initialChapter: identity.spine,
                           contentWidth: vertical ? viewport.height : viewport.width,
                           imageContentWidth: screen.width - 2 * FidelityProfile.margin,
                           viewportExtent: vertical ? viewport.width : viewport.height,
                           loadAdjacentChapters: false)
        guard let range = scroll.chapterRanges[identity.spine], !range.isEmpty else {
            throw FidelityError.message("scroll engine produced no items")
        }
        let route = auto.choice(for: identity.spine)?.debugLabel ?? "unknown"
        var dump: [String: Any] = [
            "schema": 1, "side": "engine", "book": identity.book, "spine": identity.spine, "href": identity.href,
            "writingMode": vertical ? "vertical-rl" : "horizontal-tb",
            "viewportWidth": Double(viewport.width), "viewportHeight": Double(viewport.height),
            "routeDetail": route,
        ]
        let grid: FidelityGrid
        var tiles: [Data] = []

        if let chapter = scroll.browserChapter(at: identity.spine) {
            var document = chapter.document
            if let owner = chapter.layoutOwner {
                // One transaction for the whole chapter: nothing below the first
                // screen is measured until a host asks for it.
                document = try await owner.layout(
                    in: CGRect(x: 0, y: 0, width: viewport.width, height: 4_000_000), anchorOffset: nil).document
            }
            let size = document.contentSize
            dump["route"] = "browser"
            dump["contentWidth"] = FidelityOutput.number(size.width)
            dump["contentHeight"] = FidelityOutput.number(size.height)
            dump["text"] = document.sourceText
            let content = browserContent(document.displayList)
            dump["fragments"] = content.fragments
            dump["ruby"] = content.ruby
            dump["images"] = content.images
            dump["boxes"] = content.boxes
            var builderGrid = FidelityGrid(documentSize: size)
            let background = chapter.pageBackground
            for origin in FidelityGrid.tileOrigins(documentSize: size, viewport: viewport, vertical: vertical) {
                let rect = CGRect(origin: origin, size: viewport)
                let bitmap = try FidelityBitmap.make(pointSize: viewport, scale: FidelityProfile.bitmapScale) { context in
                    (background?.color ?? settings.backgroundColor).setFill()
                    UIRectFill(CGRect(origin: .zero, size: viewport))
                    if let background, let image = chapter.pageBackgroundImage {
                        drawPageBackground(background, image: image, tile: rect, viewport: viewport, in: context)
                    }
                    ReaderDisplayListDrawer.draw(document.items(in: rect), in: context)
                }
                builderGrid.accumulate(bitmap, origin: origin)
                if tiles.count < saveTiles, let data = bitmap.jpeg() { tiles.append(data) }
            }
            grid = builderGrid
        } else {
            let chunks: [CoreTextChunk] = scroll.chunks[range].compactMap { $0.legacyChunk }
            guard !chunks.isEmpty else { throw FidelityError.message("legacy route produced no chunks") }
            chunks.forEach { $0.materializeFrameIfNeeded() }
            let extent = chunks.reduce(CGFloat(0)) { $0 + (vertical ? $1.width : $1.height) }
            let size = vertical ? CGSize(width: extent, height: viewport.height) : CGSize(width: viewport.width, height: extent)
            // Reading order starts at the top, or at the right edge in vertical-rl.
            var origins: [CGPoint] = []
            var advance: CGFloat = 0
            for chunk in chunks {
                origins.append(vertical ? CGPoint(x: extent - advance - chunk.width, y: 0) : CGPoint(x: 0, y: advance))
                advance += vertical ? chunk.width : chunk.height
            }
            dump["route"] = "legacy"
            dump["contentWidth"] = FidelityOutput.number(size.width)
            dump["contentHeight"] = FidelityOutput.number(size.height)
            var fragments: [[String: Any]] = [], images: [[String: Any]] = [], boxes: [[String: Any]] = []
            var notes: [LegacyNote] = []
            for (chunk, origin) in zip(chunks, origins) {
                legacyContent(chunk, origin: origin, fragments: &fragments, images: &images, boxes: &boxes)
                notes += try legacyNotes(in: chunk, origin: origin)
            }
            // The reference has a note's text in the flow; here it hangs off a
            // placeholder. Splice it in so both sides read the same stream.
            let text = LegacyText(chapter: chunks[0].attributedString.string, notes: notes)
            for index in fragments.indices {
                fragments[index]["s"] = text.moved(fragments[index]["s"] as! Int)
                fragments[index]["e"] = text.moved(fragments[index]["e"] as! Int)
            }
            for index in images.indices { images[index]["at"] = text.moved(images[index]["at"] as! Int) }
            for (note, start) in zip(text.notes, text.starts) {
                noteContent(note, start: start, fragments: &fragments, images: &images)
            }
            dump["text"] = text.composed
            dump["fragments"] = fragments
            dump["ruby"] = [[String: Any]]()
            dump["images"] = images
            dump["boxes"] = boxes
            // Enough to tell an empty frame from an empty chapter when nothing was painted.
            dump["chunks"] = chunks.map { chunk -> [String: Any] in
                ["width": FidelityOutput.number(chunk.width), "height": FidelityOutput.number(chunk.height),
                 "characters": chunk.charRange.length, "imageOnly": chunk.isImageOnly,
                 "lines": chunk.frame.map { CFArrayGetCount(CTFrameGetLines($0)) } ?? -1,
                 "attachments": chunk.attachments.count, "blocks": chunk.blockRenderables.count,
                 "notes": chunk.inlineAnnotations.count]
            }
            var builderGrid = FidelityGrid(documentSize: size)
            for tileOrigin in FidelityGrid.tileOrigins(documentSize: size, viewport: viewport, vertical: vertical) {
                let rect = CGRect(origin: tileOrigin, size: viewport)
                let bitmap = try FidelityBitmap.make(pointSize: viewport, scale: FidelityProfile.bitmapScale) { context in
                    settings.backgroundColor.setFill()
                    UIRectFill(CGRect(origin: .zero, size: viewport))
                    for (chunk, origin) in zip(chunks, origins) {
                        let frame = CGRect(origin: origin, size: CGSize(width: chunk.width, height: chunk.height))
                        guard frame.intersects(rect) else { continue }
                        context.saveGState()
                        context.translateBy(x: frame.minX - rect.minX, y: frame.minY - rect.minY)
                        let bounds = CGRect(origin: .zero, size: frame.size)
                        if let color = chunk.pageBackgroundColor { color.setFill(); UIRectFill(bounds) }
                        if let image = chunk.pageBackgroundImage {
                            for page in CoreTextChunkBackdropView.backgroundTileRects(
                                in: bounds, viewportSize: viewport, axis: vertical ? .horizontalRTL : .vertical) {
                                CoreTextPageView.drawPageBackground(image, in: page)
                            }
                        }
                        CoreTextChunkDrawView.draw(chunk, bounds: bounds)
                        context.restoreGState()
                    }
                }
                builderGrid.accumulate(bitmap, origin: tileOrigin)
                if tiles.count < saveTiles, let data = bitmap.jpeg() { tiles.append(data) }
            }
            grid = builderGrid
        }
        dump["ms"] = Date().timeIntervalSince(start) * 1000
        try FidelityOutput.write(dump: dump, grid: grid, tiles: tiles, directory: directory)
        return route
    }

    /// One screen of artwork per viewport, or one per window when it is fixed —
    /// what `BrowserChapterBackdropView` shows behind a viewport-driven chapter.
    private static func drawPageBackground(_ background: BrowserPageBackground, image: UIImage, tile: CGRect,
                                           viewport: CGSize, in context: CGContext) {
        let drawn = background.imageRect(for: image.size, onPageOf: viewport)
        let tops: [CGFloat]
        if background.isFixed {
            tops = [tile.minY]
        } else {
            let first = (tile.minY / viewport.height).rounded(.down)
            tops = [first * viewport.height, (first + 1) * viewport.height]
        }
        for top in tops {
            let page = CGRect(x: 0, y: top - tile.minY, width: viewport.width, height: viewport.height)
            context.saveGState()
            context.clip(to: page)
            image.draw(in: drawn.offsetBy(dx: 0, dy: top - tile.minY))
            context.restoreGState()
        }
    }

    private static func traits(of font: CTFont, attributes: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool) {
        let symbolic = CTFontGetSymbolicTraits(font)
        let stroke = (attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0
        let slanted = CTFontGetMatrix(font).c != 0 || ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) != 0
        return (symbolic.contains(.traitBold) || stroke < 0, symbolic.contains(.traitItalic) || slanted)
    }

    /// The content area of a run: baseline − ascent … baseline + descent on the
    /// block axis, advance on the inline axis. WebKit's text rects are the same box.
    private static func fragment(start: Int, end: Int, inlineStart: CGFloat, advance: CGFloat, baseline: CGFloat,
                                 font: CTFont, color: UIColor, bold: Bool, italic: Bool, vertical: Bool) -> [String: Any] {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let rect = vertical
            ? CGRect(x: baseline - descent, y: inlineStart, width: ascent + descent, height: advance)
            : CGRect(x: inlineStart, y: baseline - ascent, width: advance, height: ascent + descent)
        return ["s": start, "e": end,
                "x": FidelityOutput.number(rect.minX), "y": FidelityOutput.number(rect.minY),
                "w": FidelityOutput.number(rect.width), "h": FidelityOutput.number(rect.height),
                "fs": FidelityOutput.number(CTFontGetSize(font)), "fw": bold ? 700 : 400, "it": italic,
                "c": FidelityOutput.hex(color).0, "ff": CTFontCopyPostScriptName(font) as String]
    }

    private static func browserContent(_ list: DisplayList)
        -> (fragments: [[String: Any]], ruby: [[String: Any]], images: [[String: Any]], boxes: [[String: Any]]) {
        var fragments: [[String: Any]] = [], ruby: [[String: Any]] = [], images: [[String: Any]] = [], boxes: [[String: Any]] = []
        for item in list.items {
            switch item {
            case .text(let text):
                let rect = text.rect.rawValue
                let vertical = text.writingMode.isVertical
                let font = text.font as CTFont
                let attributed = text.attributedText
                let attributes = attributed.length > 0 ? attributed.attributes(at: 0, effectiveRange: nil) : [:]
                let style = traits(of: font, attributes: attributes)
                var entry = fragment(start: text.sourceRange.location, end: NSMaxRange(text.sourceRange),
                                     inlineStart: vertical ? rect.minY : rect.minX,
                                     advance: vertical ? rect.height : rect.width, baseline: text.baselineY,
                                     font: font, color: text.color, bold: style.bold, italic: style.italic, vertical: vertical)
                if case .linear = text.sourceMapping, text.sourceRange.length > 0 {
                    fragments.append(entry)
                } else {
                    // Ruby annotations and generated text own no source characters.
                    entry["n"] = (text.renderedTextOverride ?? text.text).count
                    ruby.append(entry)
                }
            case .image(let image):
                let rect = image.rect.rawValue
                images.append(["x": FidelityOutput.number(rect.minX), "y": FidelityOutput.number(rect.minY),
                               "w": FidelityOutput.number(rect.width), "h": FidelityOutput.number(rect.height),
                               "src": image.source, "at": image.sourceRange.location, "page": image.isBackgroundPaint])
            case .fill(let fill):
                let rect = fill.rect.rawValue
                let color = FidelityOutput.hex(fill.color)
                boxes.append(["x": FidelityOutput.number(rect.minX), "y": FidelityOutput.number(rect.minY),
                              "w": FidelityOutput.number(rect.width), "h": FidelityOutput.number(rect.height),
                              "bg": color.1 > 0 ? color.0 : "", "page": fill.isBackgroundPaint,
                              "bw": [fill.borderTop, fill.borderRight, fill.borderBottom, fill.borderLeft]
                                  .map { $0.isVisible ? FidelityOutput.number($0.width) : 0 },
                              "rad": FidelityOutput.number(fill.cornerRadius)])
            }
        }
        return (fragments, ruby, images, boxes)
    }

    private static func legacyContent(_ chunk: CoreTextChunk, origin: CGPoint, fragments: inout [[String: Any]],
                                      images: inout [[String: Any]], boxes: inout [[String: Any]]) {
        let vertical = chunk.writingMode.isVertical
        func image(_ attachment: CoreTextPaginator.RenderedAttachment) -> [String: Any] {
            let rect = attachment.rect.offsetBy(dx: origin.x, dy: origin.y)
            return ["x": FidelityOutput.number(rect.minX), "y": FidelityOutput.number(rect.minY),
                    "w": FidelityOutput.number(rect.width), "h": FidelityOutput.number(rect.height),
                    "src": attachment.sourceHref ?? "", "at": chunk.charRange.location, "page": false]
        }
        // The painter draws both lists; a picture that is in both is one picture.
        var drawn = Set<String>()
        func add(_ attachment: CoreTextPaginator.RenderedAttachment) {
            let entry = image(attachment)
            let key = ["src", "x", "y", "w", "h"].map { "\(entry[$0] ?? "")" }.joined(separator: "|")
            if drawn.insert(key).inserted { images.append(entry) }
        }
        chunk.attachments.forEach(add)
        for block in chunk.blockRenderables {
            if let attachment = block.imageAttachment { add(attachment) }
            let rect = block.rect.offsetBy(dx: origin.x, dy: origin.y)
            boxes.append(["x": FidelityOutput.number(rect.minX), "y": FidelityOutput.number(rect.minY),
                          "w": FidelityOutput.number(rect.width), "h": FidelityOutput.number(rect.height),
                          "bg": "", "page": false, "bw": [0, 0, 0, 0], "rad": 0])
        }
        guard let frame = chunk.frame else { return }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &lineOrigins)
        let attributed = chunk.attributedString
        let suppressed = chunk.blockRenderables.flatMap { $0.suppressesSourceText ? $0.sourceRanges : [] }

        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let range = NSIntersectionRange(NSRange(location: lineRange.location, length: lineRange.length),
                                            NSRange(location: 0, length: attributed.length))
            guard range.length > 0 else { continue }
            let lineOrigin = lineOrigins[index]
            if vertical {
                // Vertical frames are drawn exactly as laid out. Line origins are
                // bottom-up inside the chunk; a line advances down the page.
                appendVerticalRuns(of: line, top: origin.y + chunk.height - lineOrigin.y,
                                   baseline: origin.x + lineOrigin.x, to: &fragments)
                continue
            }
            // A horizontal line is painted by `CoreTextHorizontalLineDrawer`, which
            // decides for itself whether a justified line is stretched, whatever
            // the framesetter did to the frame's copy. The line is therefore
            // measured unstretched, and the stretch is read off what the drawer
            // actually paints: how far its ink ends beyond the unstretched ink.
            let natural = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range))
            let naturalWidth = CGFloat(CTLineGetTypographicBounds(natural, nil, nil, nil)
                                       - CTLineGetTrailingWhitespaceWidth(natural))
            let start = max(0, lineOrigin.x)
            var drawnWidth = naturalWidth
            // A block that redraws its own text paints it within these lines' area.
            if !suppressed.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                var ascent: CGFloat = 0, descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let pad: CGFloat = 4
                let strip = CGSize(width: chunk.width + 16, height: ascent + descent + 2 * pad)
                let painted = inkExtent(in: strip) { context in
                    CoreTextHorizontalLineDrawer.drawLines(
                        of: frame, contentWidth: chunk.width, contentMinX: 0,
                        contentMinY: -(lineOrigin.y - descent - pad), isLastPage: true, attrStr: attributed,
                        suppressedRanges: suppressed, hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
                        lineIndices: IndexSet(integer: index), underline: nil, in: context)
                }
                // No ink: a rule, a blank line, or nothing the reader sees as text.
                guard let painted else { continue }
                let unstretched = inkExtent(in: strip) { context in
                    context.textPosition = CGPoint(x: start, y: descent + pad)
                    CTLineDraw(natural, context)
                }
                if let unstretched, naturalWidth > 0, abs(painted.upperBound - unstretched.upperBound) > 1.5 {
                    drawnWidth = max(1, naturalWidth + painted.upperBound - unstretched.upperBound)
                }
            }
            appendRuns(of: natural, stringOffset: range.location, inlineStart: origin.x + start,
                       scale: naturalWidth > 0 ? drawnWidth / naturalWidth : 1,
                       baseline: origin.y + chunk.height - lineOrigin.y, to: &fragments)
        }
    }

    /// A note set small inside a vertical column: one placeholder in the chapter
    /// string, whose own text the legacy painter stacks down the column from that
    /// point (`CoreTextPageView.drawInlineAnnotations`).
    private struct LegacyNote {
        /// Of the placeholder, in the chapter string.
        let location: Int
        let text: NSAttributedString
        /// Where it is painted, in document coordinates.
        let rect: CGRect
    }

    private static func legacyNotes(in chunk: CoreTextChunk, origin: CGPoint) throws -> [LegacyNote] {
        guard chunk.writingMode.isVertical, let frame = chunk.frame else { return [] }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var locations: [Int] = []
        for line in CTFrameGetLines(frame) as! [CTLine] {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
                guard attributes[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] != nil,
                      let delegate = attributes[delegateKey] else { continue }
                let info = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(delegate as! CTRunDelegate))
                    .takeUnretainedValue()
                guard info is InlineAnnotationRunInfo else { continue }
                locations.append(CTRunGetStringRange(run).location)
            }
        }
        // The chunk lists the same runs in the same order (`CoreTextChunkSlicer
        // .extractInlineAnnotations`), each with the rectangle it is painted in.
        guard locations.count == chunk.inlineAnnotations.count else {
            throw FidelityError.message("inline annotations: \(locations.count) placeholders in the frame, "
                                        + "\(chunk.inlineAnnotations.count) painted")
        }
        return zip(locations, chunk.inlineAnnotations).map { location, painted in
            LegacyNote(location: location, text: painted.attributedString,
                       rect: painted.uiRect.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    /// The chapter string with every note in place of its placeholder, and the
    /// way from an offset in the chapter string to the same place in that text.
    private struct LegacyText {
        let composed: String
        let notes: [LegacyNote]
        /// Where each note's text starts in `composed`.
        let starts: [Int]
        /// For each placeholder, in order: its location and how much longer the
        /// text has become once it is replaced.
        private let growth: [(location: Int, total: Int)]

        init(chapter: String, notes unordered: [LegacyNote]) {
            let source = chapter as NSString
            let ordered = unordered.sorted { $0.location < $1.location }
            let text = NSMutableString()
            var placed: [LegacyNote] = [], starts: [Int] = [], growth: [(location: Int, total: Int)] = []
            var cursor = 0, total = 0
            for note in ordered where note.location >= cursor && note.location < source.length {
                text.append(source.substring(with: NSRange(location: cursor, length: note.location - cursor)))
                placed.append(note)
                starts.append(text.length)
                text.append(note.text.string)
                cursor = note.location + 1
                total += note.text.length - 1
                growth.append((note.location, total))
            }
            text.append(source.substring(from: cursor))
            composed = text as String
            notes = placed
            self.starts = starts
            self.growth = growth
        }

        func moved(_ offset: Int) -> Int {
            var low = 0, high = growth.count
            while low < high {
                let middle = (low + high) / 2
                if growth[middle].location < offset { low = middle + 1 } else { high = middle }
            }
            return offset + (low > 0 ? growth[low - 1].total : 0)
        }
    }

    /// What the painter draws for one note: pictures and characters down one
    /// column, each advancing by its own measure, until the note's extent is
    /// used up (`CoreTextPageView.drawInlineAnnotationColumn`). Characters that
    /// share a font become one fragment.
    private static func noteContent(_ note: LegacyNote, start: Int, fragments: inout [[String: Any]],
                                    images: inout [[String: Any]]) {
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let string = note.text.string as NSString
        let center = note.rect.midX
        var cursor = note.rect.minY
        var pending: (start: Int, end: Int, top: CGFloat, bottom: CGFloat, font: CTFont,
                      attributes: [NSAttributedString.Key: Any])?

        func flush() {
            guard let run = pending else { return }
            pending = nil
            let across = CTFontGetAscent(run.font) + CTFontGetDescent(run.font)
            let color = run.attributes[.foregroundColor] as? UIColor ?? .black
            let style = traits(of: run.font, attributes: run.attributes)
            fragments.append(["s": start + run.start, "e": start + run.end,
                              "x": FidelityOutput.number(center - across / 2), "y": FidelityOutput.number(run.top),
                              "w": FidelityOutput.number(across), "h": FidelityOutput.number(run.bottom - run.top),
                              "fs": FidelityOutput.number(CTFontGetSize(run.font)), "fw": style.bold ? 700 : 400,
                              "it": style.italic, "c": FidelityOutput.hex(color).0,
                              "ff": CTFontCopyPostScriptName(run.font) as String])
        }

        var index = 0
        while index < note.text.length, cursor < note.rect.maxY {
            var effective = NSRange(location: index, length: 1)
            if let delegate = note.text.attribute(delegateKey, at: index, effectiveRange: &effective) {
                flush()
                let info = Unmanaged<ImageRunInfo>.fromOpaque(CTRunDelegateGetRefCon(delegate as! CTRunDelegate))
                    .takeUnretainedValue()
                if info.image != nil {
                    let advance = max(1, info.width)
                    images.append(["x": FidelityOutput.number(center - info.drawWidth / 2),
                                   "y": FidelityOutput.number(cursor + max(0, (advance - info.drawHeight) / 2)),
                                   "w": FidelityOutput.number(info.drawWidth), "h": FidelityOutput.number(info.drawHeight),
                                   "src": info.source, "at": start + index, "page": false])
                    cursor += advance
                }
                index = max(index + 1, NSMaxRange(effective))
                continue
            }
            let range = string.rangeOfComposedCharacterSequence(at: index)
            let character = note.text.attributedSubstring(from: range)
            if !character.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let advance = RunDelegateProvider.inlineAnnotationTextAdvance(for: character)
                let attributes = note.text.attributes(at: range.location, effectiveRange: nil)
                if let value = attributes[.font] {
                    let font = value as! CTFont
                    if let run = pending, CFEqual(run.font, font), run.end == range.location, run.bottom == cursor {
                        pending = (run.start, NSMaxRange(range), run.top, cursor + advance, run.font, run.attributes)
                    } else {
                        flush()
                        pending = (range.location, NSMaxRange(range), cursor, cursor + advance, font, attributes)
                    }
                }
                cursor += advance
            }
            index = NSMaxRange(range)
        }
        flush()
    }

    /// The horizontal extent of what `draw` paints into a transparent strip, in
    /// the strip's own bottom-up coordinates — Core Text's, as the drawer expects.
    private static func inkExtent(in size: CGSize, draw: (CGContext) -> Void) -> ClosedRange<CGFloat>? {
        let width = max(1, Int(size.width.rounded(.up))), height = max(1, Int(size.height.rounded(.up)))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        var extent: ClosedRange<CGFloat>?
        data.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.textMatrix = .identity
            UIGraphicsPushContext(context)
            draw(context)
            UIGraphicsPopContext()
            let pixels = raw.bindMemory(to: UInt8.self)
            var low = width, high = -1
            for y in 0..<height {
                let row = y * width * 4
                var x = 0
                while x < low {
                    if pixels[row + x * 4 + 3] > 40 { low = x; break }
                    x += 1
                }
                x = width - 1
                while x > high {
                    if pixels[row + x * 4 + 3] > 40 { high = x; break }
                    x -= 1
                }
            }
            if high >= low { extent = CGFloat(low)...CGFloat(high + 1) }
        }
        return extent
    }

    /// One fragment per glyph run of a vertical line, placed by the line's own
    /// offsets for the run's first and last characters: glyph positions inside a
    /// vertical run are not distances down the line.
    private static func appendVerticalRuns(of line: CTLine, top: CGFloat, baseline: CGFloat,
                                           to fragments: inout [[String: Any]]) {
        let lineRange = CTLineGetStringRange(line)
        let lineEnd = lineRange.location + lineRange.length
        let length = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            guard range.length > 0, CTRunGetGlyphCount(run) > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            // A placeholder (a picture, a spacer, a note) is not text.
            if attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] != nil { continue }
            guard let value = attributes[.font] else { continue }
            let font = value as! CTFont
            let after = range.location + range.length
            let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let end = after >= lineEnd ? length : CTLineGetOffsetForStringIndex(line, after, nil)
            let color: UIColor
            if let foreground = attributes[.foregroundColor] as? UIColor {
                color = foreground
            } else if let foreground = attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] {
                color = UIColor(cgColor: foreground as! CGColor)
            } else {
                color = .black
            }
            let style = traits(of: font, attributes: attributes)
            fragments.append(fragment(start: range.location, end: after, inlineStart: top + min(start, end),
                                      advance: abs(end - start), baseline: baseline, font: font, color: color,
                                      bold: style.bold, italic: style.italic, vertical: true))
        }
    }

    /// One fragment per glyph run of a horizontal line. `scale` spreads the runs
    /// over the width the line is painted at; `stringOffset` locates a line built
    /// from a substring.
    private static func appendRuns(of line: CTLine, stringOffset: Int, inlineStart: CGFloat, scale: CGFloat,
                                   baseline: CGFloat, to fragments: inout [[String: Any]]) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            let glyphs = CTRunGetGlyphCount(run)
            guard range.length > 0, glyphs > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            // An attachment's placeholder character is not text.
            if attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] != nil { continue }
            guard let value = attributes[.font] else { continue }
            let font = value as! CTFont
            var positions = [CGPoint](repeating: .zero, count: glyphs)
            CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
            let advance = CGFloat(CTRunGetTypographicBounds(run, CFRangeMake(0, 0), nil, nil, nil))
            let runStart = positions.map(\.x).min() ?? 0
            let color: UIColor
            if let foreground = attributes[.foregroundColor] as? UIColor {
                color = foreground
            } else if let foreground = attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] {
                color = UIColor(cgColor: foreground as! CGColor)
            } else {
                color = .black
            }
            let style = traits(of: font, attributes: attributes)
            fragments.append(fragment(start: stringOffset + range.location,
                                      end: stringOffset + range.location + range.length,
                                      inlineStart: inlineStart + runStart * scale, advance: advance * scale,
                                      baseline: baseline, font: font, color: color, bold: style.bold,
                                      italic: style.italic, vertical: false))
        }
    }
}

// MARK: - WebKit side

/// Lets the first of an answer and its deadline through, once.
@MainActor
private final class FidelityOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

@MainActor
private final class FidelityWebReference: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let viewport: CGSize
    /// Fails whichever request is waiting on the web view, if any.
    private var failInFlight: (@MainActor (Error) -> Void)?
    private var navigationFinished: (@MainActor (Result<Bool, Error>) -> Void)?

    init(viewport: CGSize) {
        self.viewport = viewport
        let configuration = WKWebViewConfiguration()
        // A reading system does not run publication scripts in reflowable content;
        // injected scripts are unaffected by this preference.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bootstrapSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isOpaque = true
        webView.backgroundColor = .white
        // WebKit paints and runs animation frames only for a view in a window.
        // Below the status bar, so no safe-area inset enters the layout viewport.
        if let window = Self.keyWindow {
            webView.frame.origin = CGPoint(x: 0, y: window.safeAreaInsets.top)
            window.addSubview(webView)
        }
    }

    func discard() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    func capture(file: URL, root: URL, identity: (book: String, spine: Int, href: String),
                 directory: URL, saveTiles: Int) async throws {
        guard webView.window != nil else { throw FidelityError.message("no window to host the reference web view") }
        let start = Date()
        try await load(file: file, root: root)
        guard let prepared = try await evaluate(Self.prepareSource, what: "readiness", seconds: 45),
              prepared.hasPrefix("ready") else { throw FidelityError.message("reference document did not become ready") }
        guard let json = try await evaluate(Self.extractorSource, what: "extraction", seconds: 240),
              var dump = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw FidelityError.message("reference extraction returned no data")
        }
        guard let width = dump["contentWidth"] as? Double, let height = dump["contentHeight"] as? Double,
              let mode = dump["writingMode"] as? String, let maxScrollX = dump["maxScrollX"] as? Double,
              let originRight = dump["originRight"] as? Bool else {
            throw FidelityError.message("reference extraction is missing its geometry header")
        }
        // WebKit takes its language from the host process; a reference rendered
        // in another one would be a reference for a different reader.
        let spoken = (dump["language"] as? String ?? "").split(separator: "-").first.map(String.init) ?? ""
        let wanted = FidelityProfile.language.split(separator: "-").first.map(String.init) ?? ""
        guard spoken == wanted else {
            throw FidelityError.message("the reference rendered in '\(dump["language"] ?? "")', the reader in "
                                        + "'\(FidelityProfile.language)'")
        }
        let vertical = mode.hasPrefix("vertical")
        let size = CGSize(width: width, height: height)
        var grid = FidelityGrid(documentSize: size)
        var tiles: [Data] = []
        var frameTimeouts = 0
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(origin: .zero, size: viewport)
        snapshot.afterScreenUpdates = true
        for origin in FidelityGrid.tileOrigins(documentSize: size, viewport: viewport, vertical: vertical) {
            // Script scroll positions run negative from a right-hand origin.
            let scrollX = originRight ? Double(origin.x) - maxScrollX : Double(origin.x)
            let signal = try await evaluate(Self.scrollSource, arguments: ["x": scrollX, "y": Double(origin.y)],
                                            what: "scroll", seconds: 15)
            if signal != "frame" { frameTimeouts += 1 }
            let image: UIImage = try await bounded("snapshot", seconds: 30) { finish in
                webView.takeSnapshot(with: snapshot) { image, error in
                    if let image {
                        finish(.success(image))
                    } else {
                        finish(.failure(error ?? FidelityError.message("snapshot returned no image")))
                    }
                }
            }
            let bitmap = try FidelityBitmap.make(pointSize: viewport, scale: FidelityProfile.bitmapScale) { _ in
                image.draw(in: CGRect(origin: .zero, size: viewport))
            }
            grid.accumulate(bitmap, origin: origin)
            if tiles.count < saveTiles, let data = bitmap.jpeg() { tiles.append(data) }
        }
        dump["schema"] = 1
        dump["side"] = "webkit"
        dump["route"] = "webkit"
        dump["routeDetail"] = "WKWebView \(UIDevice.current.systemVersion)"
        dump["book"] = identity.book
        dump["spine"] = identity.spine
        dump["href"] = identity.href
        dump["frameTimeouts"] = frameTimeouts
        // Fonts or images the document was still waiting for when it was measured.
        dump["late"] = String(prepared.dropFirst("ready".count).drop(while: { $0 == ":" }))
        dump["ms"] = Date().timeIntervalSince(start) * 1000
        try FidelityOutput.write(dump: dump, grid: grid, tiles: tiles, directory: directory)
    }

    /// One request to the web view, never open-ended: the process behind it can
    /// stall or exit without answering, and one chapter must not hold the run.
    private func bounded<Value: Sendable>(
        _ what: String, seconds: TimeInterval,
        start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let once = FidelityOnce()
            let finish: @MainActor (Result<Value, Error>) -> Void = { [weak self] result in
                guard once.claim() else { return }
                self?.failInFlight = nil
                continuation.resume(with: result)
            }
            failInFlight = { error in finish(.failure(error)) }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    finish(.failure(FidelityError.message("\(what) did not answer within \(Int(seconds))s")))
                }
            }
        }
    }

    private func evaluate(_ source: String, arguments: [String: Any] = [:], what: String,
                          seconds: TimeInterval) async throws -> String? {
        try await bounded(what, seconds: seconds) { finish in
            webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .defaultClient) { result in
                finish(result.map { $0 as? String })
            }
        }
    }

    private func load(file: URL, root: URL) async throws {
        let _: Bool = try await bounded("load", seconds: 40) { finish in
            navigationFinished = finish
            webView.loadFileURL(file, allowingReadAccessTo: root)
        }
    }

    private func navigation(_ result: Result<Bool, Error>) {
        let finish = navigationFinished
        navigationFinished = nil
        finish?(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { self.navigation(.success(true)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.navigation(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failInFlight?(FidelityError.message("web content process terminated"))
    }

    /// Lays the document out at the view's width (a page without a viewport
    /// declaration is otherwise laid out 980px wide and scaled), and gives it the
    /// reader's defaults ahead of every publication rule.
    static let bootstrapSource = #"""
    (function () {
      var NS = 'http://www.w3.org/1999/xhtml';
      var CSS = '\#(FidelityProfile.referenceCSS.replacingOccurrences(of: "'", with: "\\'"))';
      function inject() {
        var root = document.documentElement;
        if (!root) return false;
        var head = document.head || root.getElementsByTagNameNS(NS, 'head')[0];
        if (!head) {
          if (document.readyState === 'loading') return false;
          head = document.createElementNS(NS, 'head');
          root.insertBefore(head, root.firstChild);
        }
        if (!document.getElementById('__yf_viewport')) {
          var meta = document.createElementNS(NS, 'meta');
          meta.setAttribute('id', '__yf_viewport');
          meta.setAttribute('name', 'viewport');
          meta.setAttribute('content', 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, shrink-to-fit=no');
          head.insertBefore(meta, head.firstChild);
        }
        if (!document.getElementById('__yf_profile')) {
          var style = document.createElementNS(NS, 'style');
          style.setAttribute('id', '__yf_profile');
          style.textContent = CSS;
          head.insertBefore(style, head.firstChild);
        }
        return true;
      }
      if (!inject()) {
        var observer = new MutationObserver(function () { if (inject()) observer.disconnect(); });
        observer.observe(document, { childList: true, subtree: true });
        document.addEventListener('DOMContentLoaded', function () { observer.disconnect(); inject(); });
      }
    })();
    """#

    /// Resolves once fonts and images are in and the viewport declaration is ours
    /// alone. A face that can never load (publications name fonts by device paths
    /// that do not exist here) leaves `document.fonts.ready` pending for good, so
    /// each wait is bounded and the answer names what was still outstanding.
    /// A change here that alters when a document counts as ready needs a new
    /// `extractorVersion`: this script is not part of the reference key.
    static let prepareSource = #"""
    var others = Array.prototype.slice.call(document.querySelectorAll('meta[name="viewport"]'));
    others.forEach(function (meta) { if (meta.id !== '__yf_viewport' && meta.parentNode) meta.parentNode.removeChild(meta); });
    var mine = document.getElementById('__yf_viewport');
    if (mine && others.length > 1) {
      mine.setAttribute('content', 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, shrink-to-fit=no, viewport-fit=auto');
    }
    function within(promise, milliseconds, label) {
      return Promise.race([
        promise.then(function () { return ''; }, function () { return ''; }),
        new Promise(function (resolve) { setTimeout(function () { resolve(label); }, milliseconds); })
      ]);
    }
    var late = [];
    function note(label) { if (label && late.indexOf(label) < 0) late.push(label); }
    if (document.fonts && document.fonts.ready) { note(await within(document.fonts.ready, 8000, 'fonts')); }
    var waits = [];
    Array.prototype.forEach.call(document.images, function (image) {
      if (!image.complete) {
        waits.push(new Promise(function (resolve) {
          image.addEventListener('load', resolve, { once: true });
          image.addEventListener('error', resolve, { once: true });
        }));
      }
    });
    note(await within(Promise.all(waits), 15000, 'images'));
    void document.documentElement.offsetHeight;
    if (document.fonts && document.fonts.ready && late.indexOf('fonts') < 0) {
      note(await within(document.fonts.ready, 8000, 'fonts'));
    }
    return late.length ? 'ready:' + late.join(',') : 'ready';
    """#

    /// Two animation frames after the scroll are two rendering updates of the new
    /// position. A view that is not being displayed gets no frames, so the wait is bounded.
    static let scrollSource = #"""
    window.scrollTo(x, y);
    return await new Promise(function (resolve) {
      var done = false;
      function finish(signal) { if (!done) { done = true; resolve(signal); } }
      requestAnimationFrame(function () { requestAnimationFrame(function () { finish('frame'); }); });
      setTimeout(function () { finish('timeout'); }, 2000);
    });
    """#

    static let extractorSource = #"""
    var scroller = document.scrollingElement || document.documentElement;
    var body = document.body || document.documentElement;
    var rootStyle = getComputedStyle(document.documentElement);
    var bodyStyle = getComputedStyle(body);
    var writingMode = bodyStyle.writingMode || 'horizontal-tb';
    if (writingMode === 'horizontal-tb' && rootStyle.writingMode) writingMode = rootStyle.writingMode;
    var vertical = writingMode.indexOf('vertical') === 0;
    var direction = bodyStyle.direction || 'ltr';
    var maxScrollX = Math.max(0, scroller.scrollWidth - scroller.clientWidth);
    var originRight = (vertical && writingMode.indexOf('-lr') < 0) || (!vertical && direction === 'rtl');
    var offsetX = (originRight ? maxScrollX : 0) + window.scrollX;
    var offsetY = window.scrollY;
    function round(value) { return Math.round(value * 100) / 100; }
    function color(value) {
      var match = /rgba?\(([^)]+)\)/.exec(value || '');
      if (!match) return { hex: '', alpha: 0 };
      var parts = match[1].split(/[\s,\/]+/).filter(function (p) { return p.length; }).map(parseFloat);
      function two(v) { v = Math.max(0, Math.min(255, Math.round(v))); return (v < 16 ? '0' : '') + v.toString(16); }
      return { hex: two(parts[0]) + two(parts[1]) + two(parts[2]), alpha: parts.length > 3 ? parts[3] : 1 };
    }
    var styles = new Map();
    function styleOf(element) {
      var style = styles.get(element);
      if (!style) { style = getComputedStyle(element); styles.set(element, style); }
      return style;
    }
    function name(element) { return (element.localName || '').toLowerCase(); }
    function isInline(display) {
      return display === 'inline' || display === 'contents' || display.indexOf('ruby') === 0;
    }
    var INHERITED = ['float', 'abspos', 'relpos', 'sticky', 'table', 'flex', 'grid', 'inline-block', 'list',
                     'columns', 'transform', 'flexitem', 'griditem'];
    var blocks = [], blockIndex = new Map();
    function generated(element, pseudo) {
      var content = getComputedStyle(element, pseudo).content;
      return content && content !== 'none' && content !== 'normal' && content !== '""';
    }
    function blockOf(element) {
      var current = element;
      while (current && current !== document.documentElement && isInline(styleOf(current).display)) {
        current = current.parentElement;
      }
      current = current || document.documentElement;
      var known = blockIndex.get(current);
      if (known !== undefined) return known;
      var parent = -1;
      if (current !== document.documentElement && current.parentElement) parent = blockOf(current.parentElement);
      var style = styleOf(current), rect = current.getBoundingClientRect(), display = style.display, own = [];
      if (style.cssFloat && style.cssFloat !== 'none') own.push('float');
      if (style.position === 'absolute' || style.position === 'fixed') own.push('abspos');
      else if (style.position === 'sticky') own.push('sticky');
      else if (style.position === 'relative' && (style.top !== 'auto' || style.left !== 'auto'
               || style.right !== 'auto' || style.bottom !== 'auto')) own.push('relpos');
      if (/^(inline-)?table$|^table-/.test(display)) own.push('table');
      if (/flex/.test(display)) own.push('flex');
      if (/grid/.test(display)) own.push('grid');
      if (display === 'inline-block') own.push('inline-block');
      if (display === 'list-item') own.push('list');
      if ((style.columnCount && style.columnCount !== 'auto') || (style.columnWidth && style.columnWidth !== 'auto')) own.push('columns');
      if (style.transform && style.transform !== 'none') own.push('transform');
      if (current.parentElement) {
        var parentDisplay = styleOf(current.parentElement).display;
        if (/flex/.test(parentDisplay)) own.push('flexitem');
        if (/grid/.test(parentDisplay)) own.push('griditem');
      }
      if (generated(current, '::before') || generated(current, '::after')) own.push('generated');
      if (parseFloat(style.textIndent) < 0) own.push('negindent');
      if (style.backgroundImage && style.backgroundImage !== 'none') own.push('bgimage');
      if (parseFloat(style.borderTopLeftRadius) > 0) own.push('radius');
      if (style.writingMode !== writingMode) own.push('mixed-writing-mode');
      if (style.direction !== direction) own.push('mixed-direction');
      var context = parent >= 0 ? blocks[parent].ctx.slice() : [];
      own.forEach(function (flag) { if (INHERITED.indexOf(flag) >= 0 && context.indexOf(flag) < 0) context.push(flag); });
      var index = blocks.length;
      blockIndex.set(current, index);
      blocks.push({
        i: index, p: parent, tag: name(current), cls: (current.getAttribute('class') || '').slice(0, 48),
        x: round(rect.left + offsetX), y: round(rect.top + offsetY), w: round(rect.width), h: round(rect.height),
        d: display, ta: style.textAlign, ti: round(parseFloat(style.textIndent) || 0), lh: style.lineHeight,
        fs: round(parseFloat(style.fontSize) || 0), ff: (style.fontFamily || '').slice(0, 60),
        mt: round(parseFloat(style.marginTop) || 0), mb: round(parseFloat(style.marginBottom) || 0),
        ml: round(parseFloat(style.marginLeft) || 0), mr: round(parseFloat(style.marginRight) || 0),
        pt: round(parseFloat(style.paddingTop) || 0), pb: round(parseFloat(style.paddingBottom) || 0),
        pl: round(parseFloat(style.paddingLeft) || 0), pr: round(parseFloat(style.paddingRight) || 0),
        own: own, ctx: context
      });
      return index;
    }

    var text = '', fragments = [], ruby = [], images = [], boxes = [];
    var SKIPPED = { script: 1, style: 1, head: 1, title: 1, meta: 1, link: 1, template: 1, noscript: 1 };
    var REPLACED = { img: 1, svg: 1, video: 1, audio: 1, canvas: 1, object: 1, iframe: 1, embed: 1, math: 1 };
    function isSpace(code) {
      return code <= 0x20 || code === 0xA0 || code === 0x1680 || (code >= 0x2000 && code <= 0x200F)
        || code === 0x2028 || code === 0x2029 || code === 0x202F || code === 0x205F || code === 0x2060
        || code === 0x3000 || code === 0xFEFF || code === 0xAD;
    }
    function paint(element, style) {
      var background = color(style.backgroundColor);
      var widths = [style.borderTopWidth, style.borderRightWidth, style.borderBottomWidth, style.borderLeftWidth]
        .map(function (w) { return parseFloat(w) || 0; });
      var kinds = [style.borderTopStyle, style.borderRightStyle, style.borderBottomStyle, style.borderLeftStyle];
      widths = widths.map(function (w, i) { return kinds[i] === 'none' || kinds[i] === 'hidden' ? 0 : round(w); });
      var image = style.backgroundImage && style.backgroundImage !== 'none';
      if (background.alpha <= 0 && !image && widths[0] + widths[1] + widths[2] + widths[3] === 0) return;
      if (boxes.length >= 4000) return;
      var rects = element.getClientRects();
      for (var i = 0; i < rects.length && boxes.length < 4000; i++) {
        var rect = rects[i];
        if (rect.width <= 0 || rect.height <= 0) continue;
        boxes.push({ x: round(rect.left + offsetX), y: round(rect.top + offsetY), w: round(rect.width), h: round(rect.height),
                     bg: background.alpha > 0 ? background.hex : '', image: !!image, bw: widths,
                     rad: round(parseFloat(style.borderTopLeftRadius) || 0),
                     page: element === body || element === document.documentElement });
      }
    }
    function textNode(node) {
      var parent = node.parentElement;
      if (!parent) return;
      var style = styleOf(parent);
      if (style.visibility === 'hidden' || style.visibility === 'collapse') return;
      var annotation = !!parent.closest('rt, rp');
      var data = node.data, range = document.createRange(), base = text.length;
      var current = null, produced = [];
      for (var i = 0; i < data.length;) {
        var code = data.charCodeAt(i);
        var length = (code >= 0xD800 && code <= 0xDBFF && i + 1 < data.length) ? 2 : 1;
        if (isSpace(code)) { i += length; continue; }
        range.setStart(node, i);
        range.setEnd(node, i + length);
        var rects = range.getClientRects(), rect = null;
        for (var r = 0; r < rects.length; r++) {
          if (rects[r].width > 0 || rects[r].height > 0) { rect = rects[r]; break; }
        }
        if (!rect) { i += length; continue; }
        var sameLine = current && (vertical
          ? Math.abs(rect.left - current.left) <= 0.75 && Math.abs(rect.width - current.width) <= 0.75
          : Math.abs(rect.top - current.top) <= 0.75 && Math.abs(rect.height - current.height) <= 0.75);
        if (sameLine) {
          current.e = i + length;
          current.minX = Math.min(current.minX, rect.left); current.maxX = Math.max(current.maxX, rect.right);
          current.minY = Math.min(current.minY, rect.top); current.maxY = Math.max(current.maxY, rect.bottom);
        } else {
          current = { s: i, e: i + length, left: rect.left, top: rect.top, width: rect.width, height: rect.height,
                      minX: rect.left, maxX: rect.right, minY: rect.top, maxY: rect.bottom };
          produced.push(current);
        }
        i += length;
      }
      if (!produced.length) return;
      var foreground = color(style.color);
      var weight = parseInt(style.fontWeight, 10) || (style.fontWeight === 'bold' ? 700 : 400);
      var italic = style.fontStyle === 'italic' || style.fontStyle.indexOf('oblique') === 0;
      var block = blockOf(parent), size = round(parseFloat(style.fontSize) || 0);
      produced.forEach(function (piece) {
        var entry = { x: round(piece.minX + offsetX), y: round(piece.minY + offsetY),
                      w: round(piece.maxX - piece.minX), h: round(piece.maxY - piece.minY),
                      fs: size, fw: weight, it: italic, c: foreground.hex, b: block };
        if (annotation) { entry.n = piece.e - piece.s; ruby.push(entry); }
        else { entry.s = base + piece.s; entry.e = base + piece.e; fragments.push(entry); }
      });
      // Annotation text owns no characters of the stream the engines share.
      if (!annotation) text += data;
    }
    function element(node) {
      var tag = name(node);
      if (SKIPPED[tag]) return false;
      var style = styleOf(node);
      if (style.display === 'none') return false;
      paint(node, style);
      if (REPLACED[tag]) {
        var rect = node.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden') {
          var source = node.getAttribute('src') || '';
          if (tag === 'svg') {
            var inner = node.querySelector('image');
            if (inner) source = inner.getAttribute('xlink:href') || inner.getAttribute('href') || '';
          }
          images.push({ x: round(rect.left + offsetX), y: round(rect.top + offsetY), w: round(rect.width), h: round(rect.height),
                        src: source, at: text.length, kind: tag, b: blockOf(node.parentElement || node) });
        }
        return false;
      }
      return true;
    }
    (function walk(node) {
      for (var child = node.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === 3) textNode(child);
        else if (child.nodeType === 1 && element(child)) walk(child);
      }
    })(body);
    paint(document.documentElement, rootStyle);
    paint(body, bodyStyle);
    return JSON.stringify({
      writingMode: vertical ? (writingMode.indexOf('-lr') < 0 ? 'vertical-rl' : 'vertical-lr') : 'horizontal-tb',
      direction: direction, originRight: originRight, maxScrollX: maxScrollX,
      viewportWidth: scroller.clientWidth, viewportHeight: scroller.clientHeight,
      contentWidth: Math.max(scroller.scrollWidth, scroller.clientWidth),
      contentHeight: Math.max(scroller.scrollHeight, scroller.clientHeight),
      parseError: !!document.getElementsByTagName('parsererror').length,
      language: navigator.language,
      text: text, fragments: fragments, ruby: ruby, images: images, boxes: boxes, blocks: blocks
    });
    """#
}
