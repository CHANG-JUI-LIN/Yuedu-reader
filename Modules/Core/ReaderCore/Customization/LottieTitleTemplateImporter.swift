import CoreGraphics
import Foundation
import UIKit

/// Converts a Lottie (Bodymovin 5.x) chapter-title template — the format the
/// xTitleEditor tool chain exports, carrying its own `xTitleEditor` metadata —
/// into the `ChapterTitleDesign` the reader already renders.
///
/// Deliberately a *static poster* importer, not an animation player: every
/// property in the file must be a constant (`"a": 0`). An animated template is
/// rejected instead of being flattened to frame 0, because a silently frozen
/// animation is not the thing the file promised.
///
/// Geometry is converted against ``referenceColumnWidth`` rather than the real
/// column. `ChapterTitleDesignRenderer.compile` always builds a
/// `renderWidth × canvasHeight` canvas, so layer frames are column-relative
/// (normalized) while font sizes are absolute points; one reference width is
/// what ties those two together. A wider column stretches an imported design
/// horizontally exactly as it stretches a hand-authored one.
enum LottieTitleTemplateImporter {
    /// The iPhone reading column these templates are mapped onto (≈375pt screen
    /// minus the default 2×18pt margins). Templates are authored full-bleed, so
    /// their canvas width is what lands on this.
    static let referenceColumnWidth: Double = 340

    /// Fallback ascent, as a percentage of the font size, for a font the file
    /// does not describe. Bodymovin writes `ascent` per font; it is the only
    /// baseline information in the file, and text layers are point text whose
    /// position *is* a baseline.
    private static let fallbackAscentPercent: Double = 80

    // MARK: - Detection

    /// True when `data` is a Bodymovin document. Kept strict — `w`/`h`/`layers`
    /// alone would also match unrelated JSON, and every import route in the app
    /// funnels through one file picker, so a loose probe steals other formats.
    static func looksLikeTitleTemplate(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return looksLikeTitleTemplate(root: root)
    }

    private static func looksLikeTitleTemplate(root: [String: Any]) -> Bool {
        guard root["layers"] is [Any],
              root["v"] is String,
              number(root["fr"]) != nil,
              let width = number(root["w"]),
              let height = number(root["h"]),
              width > 0, height > 0 else {
            return false
        }
        return true
    }

    // MARK: - Import

    static func `import`(
        _ data: Data,
        assetStore: ReaderStyleAssetStore
    ) async throws -> LottieTitleTemplateImport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              looksLikeTitleTemplate(root: root),
              let canvasWidth = number(root["w"]),
              let canvasHeight = number(root["h"]) else {
            throw LottieTitleTemplateImportError.notATitleTemplate
        }
        guard !containsAnimatedProperty(root) else {
            throw LottieTitleTemplateImportError.animatedTemplate
        }

        let rawLayers = root["layers"] as? [[String: Any]] ?? []
        let fonts = fontTable(root)
        let images = imageAssetTable(root)
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let pointsPerPixel = referenceColumnWidth / canvasWidth

        var notes = NoteCollector()
        var storedAssets: [String: UUID] = [:]
        var layers: [ChapterTitleLayer] = []

        for raw in paintOrdered(rawLayers) {
            if raw["parent"] != nil {
                notes.add(localized("模板圖層使用了父子連結，位置可能與原設計不同。"))
            }
            if raw["tt"] != nil || raw["hasMask"] as? Bool == true {
                notes.add(localized("模板圖層使用了遮罩或軌道遮罩，匯入後不會保留。"))
            }

            let transform = Transform(raw["ks"] as? [String: Any] ?? [:])
            let isVisible = (raw["hd"] as? Bool) != true
            let name = (raw["nm"] as? String) ?? ""

            switch number(raw["ty"]).map(Int.init) {
            case 2:
                guard let refID = raw["refId"] as? String,
                      let image = images[refID] else {
                    notes.add(localized("模板引用了找不到的圖片，該圖層已略過。"))
                    continue
                }
                guard let payload = decodeDataURI(image.source) else {
                    notes.add(localized("模板的圖片不是內嵌資料，該圖層已略過。"))
                    continue
                }
                let assetID: UUID
                if let existing = storedAssets[refID] {
                    assetID = existing
                } else {
                    do {
                        let asset = try await assetStore.importImage(
                            data: payload,
                            suggestedName: (root["nm"] as? String) ?? name
                        )
                        assetID = asset.id
                        storedAssets[refID] = asset.id
                    } catch {
                        AppLogger.render(
                            "lottie title import: asset store rejected image error=\(error)"
                        )
                        throw LottieTitleTemplateImportError.imageDecodingFailed
                    }
                }
                layers.append(
                    imageLayer(
                        name: name,
                        assetID: assetID,
                        pixelSize: CGSize(width: image.width, height: image.height),
                        transform: transform,
                        canvas: canvas,
                        isVisible: isVisible
                    )
                )

            case 5:
                guard let document = try textDocument(raw) else {
                    notes.add(localized("模板的文字圖層無法解析，已略過。"))
                    continue
                }
                if backgroundIsEnabled(raw) {
                    notes.add(localized("模板文字的背景框尚未支援，已略過。"))
                }
                layers.append(
                    textLayer(
                        name: name,
                        document: document,
                        fonts: fonts,
                        transform: transform,
                        canvas: canvas,
                        pointsPerPixel: pointsPerPixel,
                        isVisible: isVisible,
                        notes: &notes
                    )
                )

            case 1:
                guard let size = solidSize(raw) else {
                    notes.add(localized("模板含有不支援的圖層，已略過。"))
                    continue
                }
                layers.append(
                    solidLayer(
                        name: name,
                        colorHex: hex(fromCSS: raw["sc"] as? String),
                        pixelSize: size,
                        transform: transform,
                        canvas: canvas,
                        isVisible: isVisible
                    )
                )

            default:
                notes.add(localized("模板含有不支援的圖層，已略過。"))
            }
        }

        guard !layers.isEmpty else {
            throw LottieTitleTemplateImportError.noSupportedLayers
        }

        notes.add(localized("模板只有一組配色，深色模式沿用同一份。"))

        let design = ChapterTitleDesign(
            canvasAspectRatio: canvasWidth / canvasHeight,
            canvasHeight: canvasHeight * pointsPerPixel,
            layers: layers
        )
        var style = ChapterTitleStyle.default
        style.visible = true
        style.advancedCSSEnabled = true
        style.design = design

        return LottieTitleTemplateImport(
            style: style.sanitized(),
            templateName: (root["nm"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.values,
            importedAssetIDs: Array(storedAssets.values)
        )
    }

    /// Bottom-to-top paint order, which is what our renderer consumes (it draws
    /// `design.layers` in array order).
    ///
    /// Lottie's z-order lives in `ind`: the *lower* the index, the higher the
    /// layer sits, so painting from the highest `ind` down puts layer 1 in
    /// front. A stock Bodymovin export lists `ind` ascending (first entry on
    /// top) while the xTitleEditor exports list it descending, so sorting on
    /// `ind` is the one rule that reads both correctly — reversing the array
    /// would put the background image over the title in the xTitleEditor files.
    /// Only a file that omits `ind` falls back to plain Lottie array semantics.
    private static func paintOrdered(_ layers: [[String: Any]]) -> [[String: Any]] {
        let indices = layers.map { number($0["ind"]) }
        guard indices.allSatisfy({ $0 != nil }) else { return layers.reversed() }
        return zip(layers, indices.map { $0! })
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.1 == rhs.element.1
                    ? lhs.offset > rhs.offset
                    : lhs.element.1 > rhs.element.1
            }
            .map(\.element.0)
    }

    // MARK: - Layers

    private static func imageLayer(
        name: String,
        assetID: UUID,
        pixelSize: CGSize,
        transform: Transform,
        canvas: CGRect,
        isVisible: Bool
    ) -> ChapterTitleLayer {
        let rect = transform.rect(forLayerSize: pixelSize)
        return ChapterTitleLayer(
            id: UUID(),
            name: name.isEmpty ? localized("圖片") : name,
            kind: .image,
            frame: ReaderStyleNormalizedRect(rect: rect, in: canvas),
            rotation: ReaderStyleRotation(degrees: transform.rotation),
            isVisible: isVisible,
            isLocked: false,
            content: .image(assetID),
            // `.fill` and not `.stretch`: a template routinely oversizes its art
            // past the canvas and lets the canvas crop it (星环 scales a
            // 1200×690 image to 210%, bleeding 110px off each side). Our frame
            // is clamped to the canvas, so aspect-fill reproduces exactly that
            // crop, while a frame that fits keeps its authored size either way.
            lightStyle: imageStyle(assetID: assetID, opacity: transform.opacity),
            darkStyle: imageStyle(assetID: assetID, opacity: transform.opacity)
        )
    }

    private static func imageStyle(assetID: UUID, opacity: Double) -> ChapterTitleLayerStyle {
        ChapterTitleLayerStyle(
            ruleStyle: ReaderStyleRuleStyle(),
            textAlignment: .center,
            writingDirection: .horizontal,
            imagePresentation: ReaderStyleImagePresentation(
                assetID: assetID,
                contentMode: .fill,
                opacity: opacity
            )
        )
    }

    private static func solidLayer(
        name: String,
        colorHex: UInt32?,
        pixelSize: CGSize,
        transform: Transform,
        canvas: CGRect,
        isVisible: Bool
    ) -> ChapterTitleLayer {
        let style = ChapterTitleLayerStyle(
            ruleStyle: ReaderStyleRuleStyle(
                decoration: ReaderStyleDecorationStyle(
                    backgroundColorHex: colorHex,
                    opacity: transform.opacity
                )
            )
        )
        return ChapterTitleLayer(
            id: UUID(),
            name: name.isEmpty ? localized("色塊") : name,
            kind: .colorBlock,
            frame: ReaderStyleNormalizedRect(
                rect: transform.rect(forLayerSize: pixelSize),
                in: canvas
            ),
            rotation: ReaderStyleRotation(degrees: transform.rotation),
            isVisible: isVisible,
            isLocked: false,
            content: .none,
            lightStyle: style,
            darkStyle: style
        )
    }

    private static func textLayer(
        name: String,
        document: TextDocument,
        fonts: [String: FontEntry],
        transform: Transform,
        canvas: CGRect,
        pointsPerPixel: Double,
        isVisible: Bool,
        notes: inout NoteCollector
    ) -> ChapterTitleLayer {
        // Point text: the layer position is a *baseline*, not a box. Bodymovin's
        // per-font `ascent` is the only metric in the file that turns one into
        // the other.
        let font = document.fontName.flatMap { fonts[$0] }
        let ascentPercent = font?.ascent ?? fallbackAscentPercent
        let pixelFontSize = document.fontSize * transform.scaleY
        let pixelLineHeight = (document.lineHeight ?? document.fontSize * 1.2) * transform.scaleY
        let baselineY = transform.position.y - transform.anchor.y * transform.scaleY
        let anchorX = transform.position.x - transform.anchor.x * transform.scaleX
        let top = baselineY - pixelFontSize * ascentPercent / 100

        let alignment = document.alignment
        let rect = CGRect(
            x: horizontalOrigin(anchorX: anchorX, alignment: alignment, canvas: canvas),
            y: top,
            width: horizontalWidth(anchorX: anchorX, alignment: alignment, canvas: canvas),
            height: pixelLineHeight
        )

        let fontSize = pixelFontSize * pointsPerPixel
        let postScriptName = resolvedFontName(font, notes: &notes)
        let (kind, content) = role(for: document.text, notes: &notes)
        let style = ChapterTitleLayerStyle(
            ruleStyle: ReaderStyleRuleStyle(
                text: ReaderStyleTextStyle(
                    colorHex: document.fillColorHex,
                    fontPostScriptName: postScriptName,
                    fontSize: fontSize,
                    fontWeight: font?.cssWeight ?? 400,
                    italic: font?.isItalic ?? false,
                    // Bodymovin tracking is 1/1000 em.
                    letterSpacing: document.tracking / 1_000 * fontSize,
                    lineHeight: pixelLineHeight * pointsPerPixel
                ),
                decoration: ReaderStyleDecorationStyle(opacity: transform.opacity)
            ),
            textAlignment: alignment,
            writingDirection: .horizontal,
            imagePresentation: nil
        )

        return ChapterTitleLayer(
            id: UUID(),
            name: name.isEmpty ? localized("文字") : name,
            kind: kind,
            frame: ReaderStyleNormalizedRect(rect: rect, in: canvas),
            rotation: ReaderStyleRotation(degrees: transform.rotation),
            isVisible: isVisible,
            isLocked: false,
            content: content,
            lightStyle: style,
            darkStyle: style
        )
    }

    /// The box keeps the template's own anchor: a centred layer stays centred on
    /// its anchor (so a title longer than the preview grows symmetrically), and a
    /// left/right aligned one keeps its edge and takes the rest of the canvas.
    private static func horizontalOrigin(
        anchorX: Double,
        alignment: ChapterTitleAlignment,
        canvas: CGRect
    ) -> Double {
        switch alignment {
        case .left: return anchorX
        case .right: return canvas.minX
        case .center: return anchorX - horizontalWidth(
            anchorX: anchorX,
            alignment: .center,
            canvas: canvas
        ) / 2
        }
    }

    private static func horizontalWidth(
        anchorX: Double,
        alignment: ChapterTitleAlignment,
        canvas: CGRect
    ) -> Double {
        switch alignment {
        case .left: return max(0, canvas.maxX - anchorX)
        case .right: return max(0, anchorX - canvas.minX)
        case .center: return max(0, 2 * min(anchorX - canvas.minX, canvas.maxX - anchorX))
        }
    }

    /// `${s1}` / `${s2}` are the editor's own slot names for the two title lines
    /// (its previews fill them with 第十章 / the chapter name). Anything else —
    /// a different token, or a token wrapped in literal text — becomes fixed
    /// text so the user can see and fix it, rather than being guessed into a
    /// dynamic field that silently drops the literal part.
    private static func role(
        for text: String,
        notes: inout NoteCollector
    ) -> (ChapterTitleLayerKind, ChapterTitleLayerContent) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "${s1}":
            return (.chapterNumber, .dynamic(.number))
        case "${s2}":
            return (.chapterName, .dynamic(.name))
        default:
            if text.contains("${") {
                notes.add(localized("模板文字不是單純的變數，已轉成固定文字。"))
            }
            return (.customText, .text(text))
        }
    }

    private static func resolvedFontName(
        _ font: FontEntry?,
        notes: inout NoteCollector
    ) -> String? {
        guard let family = font?.family, !family.isEmpty else { return nil }
        guard UIFont(name: family, size: 12) == nil else { return family }
        notes.add(
            String(format: localized("模板字型「%@」不在系統中，已改用閱讀字型。"), family)
        )
        return nil
    }

    // MARK: - Lottie primitives

    private struct Transform {
        var position = CGPoint.zero
        var anchor = CGPoint.zero
        var scaleX: Double = 1
        var scaleY: Double = 1
        var rotation: Double = 0
        var opacity: Double = 1

        init(_ ks: [String: Any]) {
            position = point(ks["p"]) ?? .zero
            anchor = point(ks["a"]) ?? .zero
            if let scale = point(ks["s"]) {
                scaleX = Double(scale.x) / 100
                scaleY = Double(scale.y) / 100
            }
            rotation = constant(ks["r"]) ?? 0
            opacity = (constant(ks["o"]) ?? 100) / 100
        }

        /// Bodymovin maps a point `q` in layer space to `position + (q - anchor) * scale`,
        /// so the layer's own origin lands at `position - anchor * scale`.
        func rect(forLayerSize size: CGSize) -> CGRect {
            CGRect(
                x: position.x - anchor.x * scaleX,
                y: position.y - anchor.y * scaleY,
                width: size.width * scaleX,
                height: size.height * scaleY
            )
        }
    }

    private struct TextDocument {
        var text: String
        var fontName: String?
        var fontSize: Double
        var lineHeight: Double?
        var tracking: Double
        var alignment: ChapterTitleAlignment
        var fillColorHex: UInt32?
    }

    private struct FontEntry {
        var family: String?
        var style: String
        var ascent: Double?

        var isItalic: Bool { style.lowercased().contains("italic") }

        var cssWeight: Int {
            switch style.lowercased().replacingOccurrences(of: " ", with: "") {
            case let value where value.contains("thin"): return 100
            case let value where value.contains("extralight"): return 200
            case let value where value.contains("light"): return 300
            case let value where value.contains("medium"): return 500
            case let value where value.contains("semibold"): return 600
            case let value where value.contains("extrabold"): return 800
            case let value where value.contains("black"): return 900
            case let value where value.contains("bold"): return 700
            default: return 400
            }
        }
    }

    private struct ImageAsset {
        var width: Double
        var height: Double
        var source: String
    }

    private static func textDocument(_ raw: [String: Any]) throws -> TextDocument? {
        guard let text = raw["t"] as? [String: Any],
              let document = text["d"] as? [String: Any],
              let keyframes = document["k"] as? [[String: Any]] else {
            return nil
        }
        guard keyframes.count <= 1 else {
            throw LottieTitleTemplateImportError.animatedTemplate
        }
        guard let values = keyframes.first?["s"] as? [String: Any],
              let content = values["t"] as? String,
              let size = number(values["s"]), size > 0 else {
            return nil
        }
        return TextDocument(
            text: content,
            fontName: values["f"] as? String,
            fontSize: size,
            lineHeight: number(values["lh"]),
            tracking: number(values["tr"]) ?? 0,
            alignment: alignment(fromJustification: number(values["j"]).map(Int.init)),
            fillColorHex: hex(fromComponents: values["fc"] as? [Any])
        )
    }

    private static func alignment(fromJustification value: Int?) -> ChapterTitleAlignment {
        switch value {
        case 1: return .right
        case 2: return .center
        default: return .left
        }
    }

    private static func solidSize(_ raw: [String: Any]) -> CGSize? {
        guard let width = number(raw["sw"]), let height = number(raw["sh"]),
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func backgroundIsEnabled(_ raw: [String: Any]) -> Bool {
        let editor = raw["xTitleEditor"] as? [String: Any]
        let background = editor?["background"] as? [String: Any]
        return background?["enabled"] as? Bool == true
    }

    private static func fontTable(_ root: [String: Any]) -> [String: FontEntry] {
        let fonts = root["fonts"] as? [String: Any]
        let list = fonts?["list"] as? [[String: Any]] ?? []
        var table: [String: FontEntry] = [:]
        for entry in list {
            guard let name = entry["fName"] as? String else { continue }
            table[name] = FontEntry(
                family: entry["fFamily"] as? String,
                style: (entry["fStyle"] as? String) ?? "",
                ascent: number(entry["ascent"])
            )
        }
        return table
    }

    private static func imageAssetTable(_ root: [String: Any]) -> [String: ImageAsset] {
        let assets = root["assets"] as? [[String: Any]] ?? []
        var table: [String: ImageAsset] = [:]
        for asset in assets {
            guard let id = asset["id"] as? String,
                  let path = asset["p"] as? String,
                  let width = number(asset["w"]),
                  let height = number(asset["h"]),
                  width > 0, height > 0 else {
                continue
            }
            table[id] = ImageAsset(
                width: width,
                height: height,
                source: ((asset["u"] as? String) ?? "") + path
            )
        }
        return table
    }

    /// Any property still keyed `"a": 1` carries keyframes. Scanned across the
    /// whole document rather than the handful of fields we read, so a template
    /// whose animation lives somewhere we do not look is refused instead of
    /// importing as a still that does not match its preview.
    private static func containsAnimatedProperty(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if number(dictionary["a"]) == 1, dictionary["k"] != nil {
                return true
            }
            return dictionary.values.contains(where: containsAnimatedProperty)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsAnimatedProperty)
        }
        return false
    }

    // MARK: - Value helpers

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func constant(_ value: Any?) -> Double? {
        guard let property = value as? [String: Any] else { return nil }
        if let scalar = number(property["k"]) { return scalar }
        if let values = property["k"] as? [Any] { return number(values.first) }
        return nil
    }

    private static func point(_ value: Any?) -> CGPoint? {
        guard let property = value as? [String: Any] else { return nil }
        if let values = property["k"] as? [Any],
           let x = number(values.first),
           values.count > 1,
           let y = number(values[1]) {
            return CGPoint(x: x, y: y)
        }
        // Split position: `{"s": true, "x": {...}, "y": {...}}`.
        if property["s"] as? Bool == true,
           let x = constant(property["x"]),
           let y = constant(property["y"]) {
            return CGPoint(x: x, y: y)
        }
        if let scalar = number(property["k"]) {
            return CGPoint(x: scalar, y: scalar)
        }
        return nil
    }

    private static func hex(fromComponents components: [Any]?) -> UInt32? {
        guard let components, components.count >= 3,
              let red = number(components[0]),
              let green = number(components[1]),
              let blue = number(components[2]) else {
            return nil
        }
        func channel(_ value: Double) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    private static func hex(fromCSS value: String?) -> UInt32? {
        guard var text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }

    private static func decodeDataURI(_ source: String) -> Data? {
        guard source.hasPrefix("data:"),
              let separator = source.range(of: ";base64,") else {
            return nil
        }
        return Data(
            base64Encoded: String(source[separator.upperBound...]),
            options: .ignoreUnknownCharacters
        )
    }

    /// Notes are user-facing and repeat per layer; collected in first-seen order
    /// without duplicates.
    private struct NoteCollector {
        private(set) var values: [String] = []
        private var seen: Set<String> = []

        mutating func add(_ note: String) {
            guard seen.insert(note).inserted else { return }
            values.append(note)
        }
    }
}

struct LottieTitleTemplateImport: Equatable, Sendable {
    var style: ChapterTitleStyle
    var templateName: String?
    /// What could not be reproduced exactly, in the user's language.
    var notes: [String]
    var importedAssetIDs: [UUID]
}

enum LottieTitleTemplateImportError: LocalizedError, Equatable {
    case notATitleTemplate
    case animatedTemplate
    case noSupportedLayers
    case imageDecodingFailed

    var errorDescription: String? {
        switch self {
        case .notATitleTemplate:
            return localized("這不是可辨識的標題模板檔。")
        case .animatedTemplate:
            return localized("這個模板含有動畫，目前只支援靜態標題模板。")
        case .noSupportedLayers:
            return localized("這個模板沒有可轉換的圖層。")
        case .imageDecodingFailed:
            return localized("模板裡的圖片無法解碼。")
        }
    }
}
