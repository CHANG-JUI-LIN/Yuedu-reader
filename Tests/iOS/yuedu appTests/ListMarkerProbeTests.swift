import CoreText
import Foundation
import Testing
import UIKit
import WebKit

/// Opt-in probe for where WebKit draws list markers, the reference the browser engine's markers
/// have to match (docs/superpowers/specs/2026-11-03-browser-list-markers-design.md §12). The
/// render-fidelity oracle sees a marker only as paint; this measures each one's box.
///
/// For every list item of every chapter of each fixture folder in the plan, in a web view set up
/// as the oracle's reference (`RenderFidelityOracleTests`, frozen, whose profile is copied here):
/// - **Marker ink:** all markers are drawn transparent, then one at a time in its own colour;
///   the two snapshots differ only by that marker's ink. Its bounding box at two thresholds and
///   its weighted centre, so antialiasing does not eat into a half-point tolerance.
/// - **First line:** the first non-white-space character's box, and the baseline, read off a
///   0×0 inline-block inserted there (its centre: in vertical writing the dominant baseline is
///   central). Items with no text get neither — an inserted box would make the line it measures.
/// - **Layout effect:** every box again with `list-style-type: none`, so what a marker adds to a
///   line or an empty item shows as a difference.
/// - **Font metrics:** Core Text's numbers for the characters markers are made of, at every
///   item font size, to rebuild a text marker's box from its ink.
///
/// A fixture whose `fixture.json` sets `"elements": true` (S001e–g, design step 8f) also gets
/// every `[data-m]` element's computed style, boxes, first character and baseline, and the ink
/// of the decoration or text of each one marked `data-ink` (`measureElements`).
///
/// Ordinary test runs do nothing — `scripts/fidelity/list_probe.sh` passes the plan through
/// the environment. Nothing here is scored.
@Suite(.serialized)
@MainActor
struct ListMarkerProbeTests {
    @Test func probeListMarkers() async throws {
        guard let planPath = ProcessInfo.processInfo.environment["YUEDU_LIST_PROBE"] else { return }
        let plan = try JSONDecoder().decode(ListProbePlan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        let language = Locale.preferredLanguages.first ?? ""
        guard language.hasPrefix(plan.language) else {
            throw ListProbeError("the test process runs in '\(language)'; the plan asks for '\(plan.language)'")
        }
        let out = URL(fileURLWithPath: plan.out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var written: [String] = []
        for path in plan.fixtures {
            let folder = URL(fileURLWithPath: path)
            let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("fixture.json")))
            let vertical = (meta as? [String: Any])?["vertical"] as? Bool ?? false
            let chapters = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "xhtml" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let target = out.appendingPathComponent(folder.lastPathComponent)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let probe = ListMarkerWebProbe(viewport: ListProbeProfile.viewport(vertical: vertical))
            defer { probe.discard() }
            for chapter in chapters {
                let name = chapter.deletingPathExtension().lastPathComponent
                var dump = try await probe.measure(file: chapter, root: folder,
                                                   crops: target.appendingPathComponent(name + "-crops"))
                // Fixtures for UA rules other than markers mark what they measure with `data-m`.
                if (meta as? [String: Any])?["elements"] as? Bool == true {
                    dump["elements"] = try await probe.measureElements(crops: target.appendingPathComponent(name + "-crops"))
                }
                dump["fixture"] = folder.lastPathComponent
                dump["chapter"] = chapter.lastPathComponent
                dump["vertical"] = vertical
                let file = target.appendingPathComponent(name + ".json")
                try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]).write(to: file)
                written.append(file.path)
                print("LISTPROBE wrote \(file.path) items=\((dump["items"] as? [Any])?.count ?? 0)")
            }
        }
        try JSONSerialization.data(withJSONObject: ["files": written], options: [.prettyPrinted])
            .write(to: out.appendingPathComponent("index.json"))
    }
}

private struct ListProbePlan: Decodable {
    let out: String
    let language: String
    let fixtures: [String]
}

/// A computed `font-family` and `font-size` some list item uses.
private struct ListProbeFace: Hashable {
    let family: String
    let size: Double

    var firstFamily: String {
        let first = family.split(separator: ",").first.map(String.init) ?? family
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}

private struct ListProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Copied from `FidelityProfile` in RenderFidelityOracleTests.swift, which is frozen and private:
/// the probe has to see the page the oracle's reference sees.
private enum ListProbeProfile {
    static let screen = CGSize(width: 390, height: 800)
    static let margin: CGFloat = 12

    static func viewport(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: screen.width, height: screen.height - 2 * margin)
                 : CGSize(width: screen.width - 2 * margin, height: screen.height)
    }

    static let referenceCSS = "html{font-size:17px;line-height:1.5;text-align:justify;font-family:\"PingFang SC\";"
        + "-webkit-text-size-adjust:100%;text-size-adjust:100%}img{max-width:100%;height:auto}svg,video{max-width:100%}"

    /// The characters marker text is made of: digits, the Latin letters of alphabetic and roman
    /// markers, the suffixes, and the CJK numerals.
    static let markerCharacters = Array("0123456789.- 、abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ〇零一二三四五六七八九十百千")
}

/// RGBA pixels of a snapshot at its own scale.
private struct ListProbeBitmap {
    let width: Int
    let height: Int
    let scale: CGFloat
    var data: [UInt8]

    init(image: UIImage, size: CGSize) throws {
        let scale = image.scale
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        var data = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(origin: .zero, size: size))
            UIGraphicsPopContext()
            return true
        }
        guard drawn else { throw ListProbeError("bitmap context unavailable for \(size)") }
        self.scale = scale
        self.width = width
        self.height = height
        self.data = data
    }

    func png(crop: CGRect) -> Data? {
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isNull, let provider = CGDataProvider(data: Data(data) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let cropped = image.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped).pngData()
    }

    /// Where `other` differs from this one, in points of the snapshot: the box of every pixel
    /// whose largest channel difference reaches each threshold, and the difference-weighted centre.
    func ink(against other: ListProbeBitmap) -> [String: Any]? {
        guard other.width == width, other.height == height else { return nil }
        let thresholds = [8, 64]
        var boxes = thresholds.map { _ in (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min, count: 0) }
        var weight = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let d = max(abs(Int(data[i]) - Int(other.data[i])), abs(Int(data[i + 1]) - Int(other.data[i + 1])),
                            abs(Int(data[i + 2]) - Int(other.data[i + 2])))
                guard d > 0 else { continue }
                weight += Double(d)
                sumX += Double(d) * (Double(x) + 0.5)
                sumY += Double(d) * (Double(y) + 0.5)
                for (n, threshold) in thresholds.enumerated() where d >= threshold {
                    boxes[n].minX = min(boxes[n].minX, x); boxes[n].maxX = max(boxes[n].maxX, x)
                    boxes[n].minY = min(boxes[n].minY, y); boxes[n].maxY = max(boxes[n].maxY, y)
                    boxes[n].count += 1
                }
            }
        }
        guard weight > 0 else { return nil }
        let s = Double(scale)
        var result: [String: Any] = ["centre": [sumX / weight / s, sumY / weight / s], "weight": weight / 255 / s / s]
        for (n, threshold) in thresholds.enumerated() where boxes[n].count > 0 {
            let box = boxes[n]
            result["box\(threshold)"] = [Double(box.minX) / s, Double(box.minY) / s,
                                         Double(box.maxX - box.minX + 1) / s, Double(box.maxY - box.minY + 1) / s]
            result["clipped\(threshold)"] = box.minX == 0 || box.minY == 0 || box.maxX == width - 1 || box.maxY == height - 1
        }
        return result
    }
}

@MainActor
private final class ListProbeOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

@MainActor
private final class ListMarkerWebProbe: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let viewport: CGSize
    private var failInFlight: (@MainActor (Error) -> Void)?
    private var navigationFinished: (@MainActor (Result<Bool, Error>) -> Void)?

    /// The oracle reference's configuration (`FidelityWebReference.init`).
    init(viewport: CGSize) {
        self.viewport = viewport
        let configuration = WKWebViewConfiguration()
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

    func measure(file: URL, root: URL, crops: URL) async throws -> [String: Any] {
        guard webView.window != nil else { throw ListProbeError("no window to host the web view") }
        try await load(file: file, root: root)
        guard let prepared = try await evaluate(Self.prepareSource, what: "readiness", seconds: 45),
              prepared.hasPrefix("ready") else { throw ListProbeError("document did not become ready") }
        guard let json = try await evaluate(Self.itemsSource, what: "items", seconds: 60),
              var dump = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              var items = dump["items"] as? [[String: Any]] else { throw ListProbeError("item extraction returned no data") }
        try? FileManager.default.removeItem(at: crops)
        try FileManager.default.createDirectory(at: crops, withIntermediateDirectories: true)

        for (n, item) in items.enumerated() where item["display"] as? String == "list-item" {
            guard let index = item["index"] as? Int else { continue }
            let focus = try await state(Self.focusSource, index: index, what: "focus")
            let hidden = try await snapshot()
            let shown = try await state(Self.showSource, index: index, what: "show")
            let lit = try await snapshot()
            let restored = try await state(Self.hideSource, index: index, what: "hide")
            var marker: [String: Any] = ["scroll": focus["scroll"] ?? NSNull()]
            // Showing a marker changes its colour only; a box that moved would make the
            // difference more than the marker.
            marker["layoutMoved"] = !Self.same(focus, shown) || !Self.same(focus, restored)
            if let ink = lit.ink(against: hidden) {
                let scroll = focus["scroll"] as? [Double] ?? [0, 0]
                func document(_ rect: [Double]) -> [Double] { [rect[0] + scroll[0], rect[1] + scroll[1], rect[2], rect[3]] }
                for key in ["box8", "box64"] { if let box = ink[key] as? [Double] { marker[key] = document(box) } }
                if let centre = ink["centre"] as? [Double] { marker["centre"] = [centre[0] + scroll[0], centre[1] + scroll[1]] }
                marker["weight"] = ink["weight"]
                marker["clipped"] = (ink["clipped8"] as? Bool ?? false) || (ink["clipped64"] as? Bool ?? false)
                if let box = ink["box8"] as? [Double] {
                    var crop = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                    if let viewRect = focus["rect"] as? [Double] {
                        crop = crop.union(CGRect(x: viewRect[0], y: viewRect[1], width: min(viewRect[2], 80), height: min(viewRect[3], 80)))
                    }
                    if let data = lit.png(crop: crop.insetBy(dx: -12, dy: -12)) {
                        try data.write(to: crops.appendingPathComponent(String(format: "%03d.png", index)))
                    }
                }
            } else {
                marker["ink"] = "none"
            }
            items[n]["marker"] = marker
        }

        guard let noneJSON = try await evaluate(Self.noneSource, what: "list-style none", seconds: 30),
              let none = try JSONSerialization.jsonObject(with: Data(noneJSON.utf8)) as? [[String: Any]] else {
            throw ListProbeError("list-style none extraction returned no data")
        }
        for (n, item) in items.enumerated() {
            if let match = none.first(where: { ($0["index"] as? Int) == (item["index"] as? Int) }) { items[n]["none"] = match }
        }
        dump["items"] = items
        dump["fonts"] = Self.fontMetrics(faces: Set(items.compactMap { item -> ListProbeFace? in
            guard let size = item["fontSize"] as? Double, let family = item["fontFamily"] as? String else { return nil }
            return ListProbeFace(family: family, size: size)
        }), language: dump["documentLanguage"] as? String ?? "")
        dump["webkit"] = "WKWebView \(UIDevice.current.systemVersion)"
        dump["viewport"] = [viewport.width, viewport.height]
        dump["late"] = String(prepared.dropFirst("ready".count).drop(while: { $0 == ":" }))
        return dump
    }

    /// Every `[data-m]` element: its computed style, boxes, first character and baseline. An
    /// element with `data-ink="decoration"` also gets the ink of its text decoration alone (its
    /// `text-decoration-color` made transparent, against as drawn); `data-ink="emphasis"` the ink
    /// of its emphasis marks alone (`text-emphasis-color`); `data-ink="text"` the ink of
    /// its text and decoration together. Called after `measure`, on the page it left.
    func measureElements(crops: URL) async throws -> [[String: Any]] {
        guard let json = try await evaluate(Self.elementsSource, what: "elements", seconds: 60),
              var elements = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw ListProbeError("element extraction returned no data")
        }
        for (n, element) in elements.enumerated() {
            guard let ink = element["ink"] as? String, let index = element["index"] as? Int else { continue }
            let focus = try await state(Self.elementFocusSource, index: index, what: "element focus")
            let drawn = try await snapshot()
            _ = try await state(Self.elementHideSource, index: index, what: "element hide")
            let hidden = try await snapshot()
            _ = try await state(Self.elementShowSource, index: index, what: "element show")
            let scroll = focus["scroll"] as? [Double] ?? [0, 0]
            if let rect = focus["rect"] as? [Double],
               let data = drawn.png(crop: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]).insetBy(dx: -8, dy: -8)) {
                try data.write(to: crops.appendingPathComponent(String(format: "m%03d.png", index)))
            }
            if let diff = drawn.ink(against: hidden) {
                var found: [String: Any] = ["of": ink]
                for key in ["box8", "box64"] {
                    if let box = diff[key] as? [Double] { found[key] = [box[0] + scroll[0], box[1] + scroll[1], box[2], box[3]] }
                }
                found["weight"] = diff["weight"]
                elements[n]["inked"] = found
            } else {
                elements[n]["inked"] = ["of": ink, "none": true]
            }
        }
        return elements
    }

    private static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        for key in ["rect", "first"] {
            let x = a[key] as? [Double], y = b[key] as? [Double]
            if (x == nil) != (y == nil) { return false }
            if let x, let y, zip(x, y).contains(where: { abs($0 - $1) > 0.01 }) { return false }
        }
        return true
    }

    private func state(_ source: String, index: Int, what: String) async throws -> [String: Any] {
        guard let json = try await evaluate(source, arguments: ["index": index], what: what, seconds: 15),
              let state = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ListProbeError("\(what) returned no data for item \(index)")
        }
        return state
    }

    private func snapshot() async throws -> ListProbeBitmap {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: viewport)
        configuration.afterScreenUpdates = true
        let image: UIImage = try await bounded("snapshot", seconds: 30) { finish in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    finish(.success(image))
                } else {
                    finish(.failure(error ?? ListProbeError("snapshot returned no image")))
                }
            }
        }
        return try ListProbeBitmap(image: image, size: viewport)
    }

    /// Core Text's numbers for the marker characters in each item face: the first family of the
    /// item's computed `font-family`, at its size, shaped in the document's language (a zh-Hant
    /// 、 is the centred form). Advances are given proportional and tabular
    /// (the UA `::marker` sets `tabular-nums`); `verticalForm` is the glyph a vertical line
    /// substitutes, with its vertical advance and the translation Core Text applies to set it upright.
    private static func fontMetrics(faces: Set<ListProbeFace>, language: String) -> [[String: Any]] {
        faces.sorted { ($0.family, $0.size) < ($1.family, $1.size) }.map { face in
            let size = face.size
            let family = [kCTFontFamilyNameAttribute as String: face.firstFamily] as CFDictionary
            let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(family), CGFloat(size), nil)
            let tabular = CTFontCreateCopyWithAttributes(font, CGFloat(size), nil, CTFontDescriptorCreateWithAttributes([
                kCTFontFeatureSettingsAttribute as String: [[kCTFontOpenTypeFeatureTag as String: "tnum",
                                                             kCTFontOpenTypeFeatureValue as String: 1]]
            ] as CFDictionary))
            var characters: [String: Any] = [:]
            for character in ListProbeProfile.markerCharacters {
                let text = String(character)
                var entry: [String: Any] = [:]
                for (key, face) in [("proportional", font), ("tabular", tabular)] {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                        .font: face, NSAttributedString.Key(kCTLanguageAttributeName as String): language]))
                    entry[key] = ["advance": CTLineGetTypographicBounds(line, nil, nil, nil),
                                  "ink": rect(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))]
                }
                let upright = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: font, .verticalGlyphForm: true, NSAttributedString.Key(kCTLanguageAttributeName as String): language]))
                if let run = (CTLineGetGlyphRuns(upright) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 {
                    var glyph = CGGlyph()
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
                    var bounds = CGRect.zero, advance = CGSize.zero, translation = CGSize.zero
                    _ = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
                    _ = CTFontGetAdvancesForGlyphs(font, .vertical, &glyph, &advance, 1)
                    CTFontGetVerticalTranslationsForGlyphs(font, &glyph, &translation, 1)
                    entry["verticalForm"] = ["glyph": Int(glyph), "ink": rect(bounds),
                                             "advance": [advance.width, advance.height],
                                             "translation": [translation.width, translation.height]]
                }
                characters[text] = entry
            }
            return ["size": size, "family": face.family, "postScriptName": CTFontCopyPostScriptName(font) as String,
                    "ascent": CTFontGetAscent(font), "descent": CTFontGetDescent(font), "leading": CTFontGetLeading(font),
                    "capHeight": CTFontGetCapHeight(font), "xHeight": CTFontGetXHeight(font),
                    "unitsPerEm": CTFontGetUnitsPerEm(font), "characters": characters]
        }
    }

    private static func rect(_ rect: CGRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].map { Double($0) }
    }

    private func bounded<Value: Sendable>(
        _ what: String, seconds: TimeInterval,
        start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let once = ListProbeOnce()
            let finish: @MainActor (Result<Value, Error>) -> Void = { [weak self] result in
                guard once.claim() else { return }
                self?.failInFlight = nil
                continuation.resume(with: result)
            }
            failInFlight = { error in finish(.failure(error)) }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    finish(.failure(ListProbeError("\(what) did not answer within \(Int(seconds))s")))
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
        failInFlight?(ListProbeError("web content process terminated"))
    }

    /// The oracle reference's bootstrap (`FidelityWebReference.bootstrapSource`) with the
    /// probe's own rule added: every marker transparent unless its item is the one shown.
    /// Colour changes no layout, so the hidden page is laid out exactly as the real one.
    static let bootstrapSource = #"""
    (function () {
      var NS = 'http://www.w3.org/1999/xhtml';
      var CSS = '\#(ListProbeProfile.referenceCSS.replacingOccurrences(of: "'", with: "\\'"))';
      var PROBE = '*::marker{color:transparent!important}[data-yf-show]::marker{color:inherit!important}';
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
        if (!document.getElementById('__yf_probe')) {
          var probe = document.createElementNS(NS, 'style');
          probe.setAttribute('id', '__yf_probe');
          probe.textContent = PROBE;
          head.appendChild(probe);
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

    /// The oracle reference's readiness wait (`FidelityWebReference.prepareSource`).
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

    /// Shared by the item scripts: rects in document coordinates (the viewport's plus the
    /// scroll offset, which runs negative from the right in vertical-rl), and the first
    /// rendered non-white-space character or replaced element of an item in tree order.
    static let helpers = #"""
    function viewRect(r) { return [r.left, r.top, r.width, r.height]; }
    function docRect(r) { return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height]; }
    function rendered(node) {
      for (var e = node.nodeType === 1 ? node : node.parentElement; e; e = e.parentElement) {
        if (getComputedStyle(e).display === 'none') return false;
      }
      return true;
    }
    function firstContent(item) {
      var walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
      for (var node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeType === 1) {
          if (/^(img|svg|video|object|canvas)$/i.test(node.localName) && rendered(node)) return { image: node };
          continue;
        }
        var match = /\S/.exec(node.data);
        if (match && rendered(node)) return { text: node, offset: match.index };
      }
      return null;
    }
    function charRange(found) {
      var range = document.createRange();
      range.setStart(found.text, found.offset);
      range.setEnd(found.text, found.offset + 1);
      return range;
    }
    function item(index) { return document.querySelector('[data-yf-index="' + index + '"]'); }
    function geometry(element, rect) {
      var found = firstContent(element);
      var first = null;
      if (found && found.text) first = rect(charRange(found).getBoundingClientRect());
      else if (found && found.image) first = rect(found.image.getBoundingClientRect());
      return { rect: rect(element.getBoundingClientRect()), first: first };
    }
    function frames() {
      return new Promise(function (resolve) {
        var done = false;
        function finish(signal) { if (!done) { done = true; resolve(signal); } }
        requestAnimationFrame(function () { requestAnimationFrame(function () { finish('frame'); }); });
        setTimeout(function () { finish('timeout'); }, 2000);
      });
    }
    """#

    /// Every list item and every `li`, numbered, with the style that decides its marker,
    /// its border box, its first line and baseline.
    static let itemsSource = helpers + #"""
    var NS = 'http://www.w3.org/1999/xhtml';
    var root = getComputedStyle(document.body || document.documentElement);
    var elements = Array.prototype.filter.call(document.querySelectorAll('body *'), function (element) {
      return element.localName === 'li' || getComputedStyle(element).display === 'list-item';
    });
    function px(value) { return parseFloat(value) || 0; }
    function sides(style, name) {
      return ['top', 'right', 'bottom', 'left'].map(function (side) {
        return px(style.getPropertyValue(name.replace('*', side)));
      });
    }
    var items = elements.map(function (element, index) {
      element.setAttribute('data-yf-index', String(index));
      var style = getComputedStyle(element);
      var owner = element.closest('[data-case]');
      var entry = {
        index: index, tag: element.localName, case: owner ? owner.getAttribute('data-case') : '',
        text: (element.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 16),
        display: style.display, listStyleType: style.listStyleType, listStylePosition: style.listStylePosition,
        fontSize: px(style.fontSize), fontFamily: style.fontFamily, fontWeight: style.fontWeight,
        lineHeight: style.lineHeight, color: style.color, writingMode: style.writingMode,
        direction: style.direction, textAlign: style.textAlign, textIndent: style.textIndent,
        textOrientation: style.textOrientation || style.webkitTextOrientation || '',
        padding: sides(style, 'padding-*'), border: sides(style, 'border-*-width'), margin: sides(style, 'margin-*')
      };
      var before = geometry(element, docRect);
      entry.box = before.rect;
      entry.first = before.first;
      var found = firstContent(element);
      entry.firstKind = found ? (found.text ? 'text' : 'image') : 'none';
      if (found && found.text) {
        var firstStyle = getComputedStyle(found.text.parentElement);
        entry.firstFontSize = px(firstStyle.fontSize);
        entry.firstLineHeight = firstStyle.lineHeight;
        var probe = document.createElementNS(NS, 'span');
        probe.setAttribute('style', 'display:inline-block;width:0;height:0;margin:0;padding:0;border:0;vertical-align:baseline');
        var at = document.createRange();
        at.setStart(found.text, found.offset);
        at.collapse(true);
        at.insertNode(probe);
        var r = probe.getBoundingClientRect();
        entry.baseline = [r.left + r.width / 2 + window.scrollX, r.top + r.height / 2 + window.scrollY];
        var during = geometry(element, docRect);
        var parent = probe.parentNode;
        parent.removeChild(probe);
        parent.normalize();
        var after = geometry(element, docRect);
        function moved(a, b) {
          if (!a || !b) return a !== b;
          return a.some(function (v, i) { return Math.abs(v - b[i]) > 0.01; });
        }
        entry.baselineDisturbed = moved(before.rect, during.rect) || moved(before.first, during.first);
        entry.baselineNotRestored = moved(before.rect, after.rect) || moved(before.first, after.first);
      }
      return entry;
    });
    return JSON.stringify({
      writingMode: root.writingMode, scrollWidth: document.scrollingElement.scrollWidth,
      scrollHeight: document.scrollingElement.scrollHeight, devicePixelRatio: window.devicePixelRatio,
      language: navigator.language, documentLanguage: document.documentElement.lang || '', items: items
    });
    """#

    /// Brings an item to the middle of the viewport, then answers its rects in viewport
    /// coordinates and the scroll offset that turns them into document ones.
    static let focusSource = helpers + #"""
    var element = item(index);
    element.scrollIntoView({ block: 'center', inline: 'center' });
    await frames();
    var state = geometry(element, viewRect);
    state.scroll = [window.scrollX, window.scrollY];
    return JSON.stringify(state);
    """#

    static let showSource = helpers + #"""
    var element = item(index);
    element.setAttribute('data-yf-show', '');
    await frames();
    return JSON.stringify(geometry(element, viewRect));
    """#

    static let hideSource = helpers + #"""
    var element = item(index);
    element.removeAttribute('data-yf-show');
    await frames();
    return JSON.stringify(geometry(element, viewRect));
    """#

    /// Every `[data-m]` element, numbered: what it computes to and where it lies.
    static let elementsSource = helpers + #"""
    var NS = 'http://www.w3.org/1999/xhtml';
    function px(value) { return parseFloat(value) || 0; }
    function sides(style, name) {
      return ['top', 'right', 'bottom', 'left'].map(function (side) {
        return style.getPropertyValue(name.replace('*', side));
      });
    }
    var elements = Array.prototype.slice.call(document.querySelectorAll('[data-m]'));
    var result = elements.map(function (element, index) {
      element.setAttribute('data-yf-m', String(index));
      var style = getComputedStyle(element);
      var before = getComputedStyle(element, '::before'), after = getComputedStyle(element, '::after');
      var entry = {
        index: index, m: element.getAttribute('data-m'), tag: element.localName,
        text: (element.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 24),
        display: style.display, fontSize: px(style.fontSize), fontFamily: style.fontFamily,
        fontStyle: style.fontStyle, fontWeight: style.fontWeight, color: style.color,
        decorationLine: style.textDecorationLine || style.webkitTextDecorationLine || '',
        decorationStyle: style.textDecorationStyle || '', decorationColor: style.textDecorationColor || '',
        decorationThickness: style.textDecorationThickness || '', underlineOffset: style.textUnderlineOffset || '',
        emphasisStyle: style.textEmphasisStyle || style.webkitTextEmphasisStyle || '',
        emphasisPosition: style.textEmphasisPosition || style.webkitTextEmphasisPosition || '',
        verticalAlign: style.verticalAlign, whiteSpace: style.whiteSpace, textAlign: style.textAlign,
        lineHeight: style.lineHeight, quotes: style.quotes || '', before: before.content, after: after.content,
        writingMode: style.writingMode, backgroundColor: style.backgroundColor,
        borderColor: sides(style, 'border-*-color'), borderStyle: sides(style, 'border-*-style'),
        borderWidth: sides(style, 'border-*-width'), margin: sides(style, 'margin-*'), padding: sides(style, 'padding-*'),
        box: docRect(element.getBoundingClientRect()),
        rects: Array.prototype.map.call(element.getClientRects(), docRect)
      };
      if (element.hasAttribute('data-ink')) entry.ink = element.getAttribute('data-ink');
      var found = firstContent(element);
      if (found && found.text) {
        entry.first = docRect(charRange(found).getBoundingClientRect());
        var probe = document.createElementNS(NS, 'span');
        probe.setAttribute('style', 'display:inline-block;width:0;height:0;margin:0;padding:0;border:0;vertical-align:baseline');
        var at = document.createRange();
        at.setStart(found.text, found.offset);
        at.collapse(true);
        at.insertNode(probe);
        var r = probe.getBoundingClientRect();
        entry.baseline = [r.left + r.width / 2 + window.scrollX, r.top + r.height / 2 + window.scrollY];
        var parent = probe.parentNode;
        parent.removeChild(probe);
        parent.normalize();
      }
      return entry;
    });
    return JSON.stringify(result);
    """#

    static let elementFocusSource = helpers + #"""
    var element = document.querySelector('[data-yf-m="' + index + '"]');
    element.scrollIntoView({ block: 'center', inline: 'center' });
    await frames();
    return JSON.stringify({ rect: viewRect(element.getBoundingClientRect()), scroll: [window.scrollX, window.scrollY] });
    """#

    /// Hides what the element's `data-ink` names, without moving anything.
    static let elementHideSource = helpers + #"""
    var element = document.querySelector('[data-yf-m="' + index + '"]');
    if (element.getAttribute('data-ink') === 'decoration') element.style.setProperty('text-decoration-color', 'transparent', 'important');
    else if (element.getAttribute('data-ink') === 'emphasis') {
      // On the parent too: in vertical writing WebKit repaints only the element's own box, and
      // its marks sit outside it (iOS 27.2). The parent's line box holds them.
      [element, element.parentElement].forEach(function (box) {
        box.style.setProperty('-webkit-text-emphasis-color', 'transparent', 'important');
        box.style.setProperty('text-emphasis-color', 'transparent', 'important');
      });
    }
    else element.style.setProperty('color', 'transparent', 'important');
    await frames();
    return JSON.stringify({ rect: viewRect(element.getBoundingClientRect()) });
    """#

    static let elementShowSource = helpers + #"""
    var element = document.querySelector('[data-yf-m="' + index + '"]');
    element.style.removeProperty('text-decoration-color');
    [element, element.parentElement].forEach(function (box) {
      box.style.removeProperty('-webkit-text-emphasis-color');
      box.style.removeProperty('text-emphasis-color');
    });
    element.style.removeProperty('color');
    await frames();
    return JSON.stringify({ rect: viewRect(element.getBoundingClientRect()) });
    """#

    /// Every item's geometry with no marker at all, then the page as it was.
    static let noneSource = helpers + #"""
    var NS = 'http://www.w3.org/1999/xhtml';
    var style = document.createElementNS(NS, 'style');
    style.textContent = '*{list-style-type:none!important;list-style-image:none!important}';
    document.head.appendChild(style);
    void document.documentElement.offsetHeight;
    var result = Array.prototype.map.call(document.querySelectorAll('[data-yf-index]'), function (element) {
      var state = geometry(element, docRect);
      state.index = parseInt(element.getAttribute('data-yf-index'), 10);
      return state;
    });
    style.parentNode.removeChild(style);
    void document.documentElement.offsetHeight;
    return JSON.stringify(result);
    """#
}
