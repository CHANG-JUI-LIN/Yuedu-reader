import Foundation
import JavaScriptCore

/// Reads the *settings* out of a script-based 對話氣泡 file (the
/// `{ name, script, order, timeoutMillisecond … }` documents whose `script` is a
/// `function process(ctx)` that rewrites a chapter's dialogue into SVG images)
/// and converts them into our native ``ReaderDialogueBubbleStyle``.
///
/// Deliberately *not* a runtime for those scripts. Running one would turn every
/// line of dialogue into a bitmap: no selection, no search, no TTS, no dark
/// mode, and a font size frozen to the script's 1080px canvas. The file's
/// `CONFIG` block — colors, margins, radii, tails, nine-slice skins — is the
/// part worth keeping, and it maps cleanly onto a native bubble that keeps the
/// text as text.
enum DialogueBubbleScriptImporter {
    /// The canvas these scripts lay out on, used when a file omits its own.
    private static let defaultCanvasWidth: Double = 1_080
    /// The dialogue font size they lay out with. Every skin measurement in the
    /// file is relative to this, which is what makes an em-based conversion
    /// exact rather than a guess.
    private static let defaultFontSize: Double = 66

    // MARK: - Detection

    static func looksLikeBubbleScript(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = root["script"] as? String else {
            return false
        }
        return script.contains("function process") && script.contains("CONFIG")
    }

    // MARK: - Import

    static func `import`(
        _ data: Data,
        assetStore: ReaderStyleAssetStore
    ) async throws -> DialogueBubbleScriptImport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = root["script"] as? String else {
            throw DialogueBubbleScriptImportError.notABubbleScript
        }
        guard let literal = configLiteral(in: script) else {
            throw DialogueBubbleScriptImportError.configNotFound
        }
        guard let config = evaluateObjectLiteral(literal) else {
            throw DialogueBubbleScriptImportError.configEvaluationFailed
        }

        var notes = NoteCollector()
        let layout = config["layout"] as? [String: Any] ?? [:]
        let text = config["text"] as? [String: Any] ?? [:]
        let colors = config["colors"] as? [String: Any] ?? [:]
        let behavior = config["behavior"] as? [String: Any] ?? [:]
        let bubbleType = config["bubbleType"] as? [String: Any] ?? [:]
        let nativeBubble = config["nativeBubble"] as? [String: Any] ?? [:]
        let imageSkin = config["imageSkin"] as? [String: Any] ?? [:]

        let canvasWidth = number(layout["canvasWidth"]) ?? defaultCanvasWidth
        let fontSize = dialogueFontSize(in: text)
        notes.add(localized("氣泡文字改用閱讀字級，腳本裡的字級、行高與字距不會沿用。"))

        var importedAssetIDs: [UUID] = []
        var sides: [ReaderDialogueBubbleSide: ReaderDialogueBubbleSideStyle] = [:]
        for side in ReaderDialogueBubbleSide.allCases {
            let prefix = side.rawValue
            let native = nativeBubble[prefix] as? [String: Any] ?? [:]
            let skinConfig = imageSkin[prefix] as? [String: Any] ?? [:]
            let usesImage = (bubbleType[prefix] as? String) == "image"

            var skin: ReaderDialogueBubbleSkin?
            if usesImage, let source = skinConfig["dataUri"] as? String {
                let asset = try await storeImage(
                    source: source,
                    name: (root["name"] as? String) ?? prefix,
                    assetStore: assetStore
                )
                importedAssetIDs.append(asset)
                skin = makeSkin(assetID: asset, config: skinConfig, notes: &notes)
            } else if usesImage {
                notes.add(localized("氣泡皮膚圖不是內嵌資料，改用純色氣泡。"))
            }

            var avatar: ReaderDialogueBubbleAvatar?
            let avatarConfig = (config["avatar"] as? [String: Any])?[prefix] as? [String: Any]
            if let avatarConfig,
               avatarConfig["enabled"] as? Bool == true,
               let source = avatarConfig["dataUri"] as? String {
                let asset = try await storeImage(
                    source: source,
                    name: (root["name"] as? String) ?? prefix,
                    assetStore: assetStore
                )
                importedAssetIDs.append(asset)
                avatar = ReaderDialogueBubbleAvatar(
                    assetID: asset,
                    sizeEm: (number(avatarConfig["size"]) ?? fontSize * 2) / fontSize,
                    gapEm: (number(avatarConfig["gap"]) ?? 0) / fontSize,
                    offsetXEm: (number(avatarConfig["offsetX"]) ?? 0) / fontSize,
                    offsetYEm: (number(avatarConfig["offsetY"]) ?? 0) / fontSize,
                    backgroundHex: hex(avatarConfig["backgroundColor"]),
                    borderHex: hex(avatarConfig["borderColor"]),
                    borderWidthEm: (number(avatarConfig["borderWidth"]) ?? 0) / fontSize
                )
            }

            sides[side] = ReaderDialogueBubbleSideStyle(
                fillHex: hex(colors["\(prefix)Bubble"]) ?? defaultFill(for: side),
                textHex: hex(colors["\(prefix)Text"]),
                borderHex: hex(colors["\(prefix)Border"]),
                borderWidthEm: (number(native["borderWidth"]) ?? 0) / fontSize,
                cornerRadiusEm: (number(native["radius"]) ?? 0) / fontSize,
                tail: tail(from: native, fontSize: fontSize),
                skin: skin,
                // Typography is deliberately not imported: the script lays out
                // on a fixed 1080px canvas, so its size/line-height/tracking are
                // canvas units, not reading units. Bubble text follows 字級 and
                // stays adjustable in 對話氣泡 settings.
                letterSpacingEm: 0,
                textAlignment: alignment(
                    (text[prefix] as? [String: Any])?["textAlign"] as? String
                ),
                decoration: decoration(
                    (config["decorations"] as? [String: Any])?[prefix] as? [String: Any],
                    fontSize: fontSize
                ),
                variants: variants(
                    (config["variants"] as? [String: Any])?[prefix] as? [String: Any]
                ),
                avatar: avatar
            )
        }

        let style = ReaderDialogueBubbleStyle(
            isEnabled: true,
            startSide: (behavior["startSide"] as? String) == "left" ? .left : .right,
            alternatesSides: true,
            maxWidthRatio: widestSide(layout, suffix: "BubbleMaxWidth", notes: &notes)
                / canvasWidth,
            sideInsetRatio: widestSide(layout, suffix: "ScreenMargin", notes: &notes)
                / canvasWidth,
            horizontalPaddingEm: widestSide(layout, suffix: "BubblePaddingX", notes: &notes)
                / fontSize,
            verticalPaddingEm: widestSide(layout, suffix: "BubblePaddingY", notes: &notes)
                / fontSize,
            spacingEm: (number(layout["canvasPaddingY"]) ?? 0) * 2 / fontSize,
            removesQuotes: behavior["removeOuterQuotes"] as? Bool ?? true,
            mergesAdjacent: behavior["mergeAdjacentDialogues"] as? Bool ?? true,
            left: sides[.left] ?? .defaultLeft,
            right: sides[.right] ?? .defaultRight
        )

        return DialogueBubbleScriptImport(
            style: style.sanitized(),
            name: (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.values,
            importedAssetIDs: importedAssetIDs
        )
    }

    // MARK: - CONFIG extraction

    /// Pulls the `var CONFIG = { … }` object literal out of the script text.
    ///
    /// `CONFIG` is a local inside `process`, so it cannot be read by calling the
    /// function; the literal has to be lifted out of the source. Brace matching
    /// is string- and comment-aware because the skins are base64 data URIs and
    /// the hand-edited files carry comment blocks between the fields.
    static func configLiteral(in script: String) -> String? {
        guard let declaration = script.range(of: "var CONFIG") else { return nil }
        guard let open = script[declaration.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = open
        var quote: Character?
        var isEscaped = false
        var comment: Comment = .none

        while index < script.endIndex {
            let character = script[index]
            let next = script.index(after: index)

            switch comment {
            case .line:
                if character == "\n" { comment = .none }
            case .block:
                if character == "*", next < script.endIndex, script[next] == "/" {
                    comment = .none
                    index = next
                }
            case .none:
                if let active = quote {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == active {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "/", next < script.endIndex {
                    if script[next] == "/" {
                        comment = .line
                        index = next
                    } else if script[next] == "*" {
                        comment = .block
                        index = next
                    }
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(script[open...index])
                    }
                }
            }
            index = script.index(after: index)
        }
        return nil
    }

    private enum Comment {
        case none
        case line
        case block
    }

    /// The literal is JavaScript, not JSON — these files write bare keys — so it
    /// is evaluated rather than parsed. Runs through the same sandboxed context
    /// the rule engine uses; the value is an object literal, and nothing in it
    /// is invoked.
    private static func evaluateObjectLiteral(_ literal: String) -> [String: Any]? {
        guard let context = JSContext() else { return nil }
        JSSandbox.configure(context)
        let value = JSSandbox.evaluateWithTimeout(
            context,
            script: "(\(literal))",
            timeout: 5
        )
        guard let value, !value.isUndefined, !value.isNull else {
            AppLogger.render("dialogue bubble import: CONFIG literal did not evaluate")
            return nil
        }
        return value.toDictionary() as? [String: Any]
    }

    // MARK: - Mapping helpers

    /// The sticker config, in em so it tracks the reading size.
    private static func decoration(
        _ config: [String: Any]?,
        fontSize: Double
    ) -> ReaderDialogueBubbleDecoration? {
        guard let config, config["enabled"] as? Bool == true else { return nil }
        return ReaderDialogueBubbleDecoration(
            kind: ReaderDialogueBubbleDecorationKind(
                rawValue: (config["kind"] as? String) ?? "star"
            ) ?? .star,
            anchor: ReaderDialogueBubbleAnchor(
                rawValue: (config["anchor"] as? String) ?? "top-right"
            ) ?? .topRight,
            sizeEm: max(8, number(config["size"]) ?? 54) / fontSize,
            offsetXEm: (number(config["offsetX"]) ?? 0) / fontSize,
            offsetYEm: (number(config["offsetY"]) ?? 0) / fontSize,
            rotationDegrees: number(config["rotation"]) ?? 0,
            colorHex: hex(config["color"]) ?? 0xFFC857,
            opacity: number(config["opacity"]) ?? 1,
            isOutside: config["outside"] as? Bool ?? true,
            variation: ReaderDialogueBubbleVariation(
                rawValue: (config["variation"] as? String) ?? "fixed"
            ) ?? .fixed
        )
    }

    private static func variants(_ config: [String: Any]?) -> ReaderDialogueBubbleVariants? {
        guard let config, config["enabled"] as? Bool == true,
              let items = config["items"] as? [[String: Any]], !items.isEmpty else {
            return nil
        }
        let resolved = items.compactMap { item -> ReaderDialogueBubbleVariantItem? in
            guard let fill = hex(item["bubbleColor"]) else { return nil }
            return ReaderDialogueBubbleVariantItem(
                fillHex: fill,
                borderHex: hex(item["borderColor"]),
                textHex: hex(item["textColor"]),
                decorationKind: (item["decorationKind"] as? String)
                    .flatMap(ReaderDialogueBubbleDecorationKind.init(rawValue:))
            )
        }
        guard !resolved.isEmpty else { return nil }
        return ReaderDialogueBubbleVariants(
            selection: ReaderDialogueBubbleVariants.Selection(
                rawValue: (config["selection"] as? String) ?? "text"
            ) ?? .text,
            items: resolved
        )
    }

    private static func alignment(_ value: String?) -> ChapterTitleAlignment? {
        switch value {
        case "left": return .left
        case "center": return .center
        case "right": return .right
        default: return nil
        }
    }

    private static func dialogueFontSize(in text: [String: Any]) -> Double {
        let sides = ReaderDialogueBubbleSide.allCases.compactMap { side -> Double? in
            guard let entry = text[side.rawValue] as? [String: Any] else { return nil }
            return number(entry["fontSize"])
        }
        let resolved = sides.max() ?? defaultFontSize
        return resolved > 0 ? resolved : defaultFontSize
    }

    /// These files carry one value per side; our bubble has one shared metric,
    /// so the wider of the two wins and the difference is reported.
    private static func widestSide(
        _ layout: [String: Any],
        suffix: String,
        notes: inout NoteCollector
    ) -> Double {
        let values = ReaderDialogueBubbleSide.allCases.compactMap {
            number(layout["\($0.rawValue)\(suffix)"])
        }
        guard let first = values.first else { return 0 }
        if values.count == 2, abs(values[0] - values[1]) > 0.5 {
            notes.add(localized("腳本的左右氣泡尺寸不同，已統一採用較大的一邊。"))
        }
        return values.max() ?? first
    }

    private static func tail(
        from native: [String: Any],
        fontSize: Double
    ) -> ReaderDialogueBubbleTail? {
        guard native["tailEnabled"] as? Bool ?? false else { return nil }
        return ReaderDialogueBubbleTail(
            widthEm: (number(native["tailWidth"]) ?? 0) / fontSize,
            heightEm: (number(native["tailHeight"]) ?? 0) / fontSize,
            outsideEm: (number(native["tailOutside"]) ?? 0) / fontSize,
            bottomOffsetEm: (number(native["tailBottomOffset"]) ?? 0) / fontSize
        )
    }

    private static func makeSkin(
        assetID: UUID,
        config: [String: Any],
        notes: inout NoteCollector
    ) -> ReaderDialogueBubbleSkin {
        let mode = (config["mode"] as? String) ?? "nineSlice"
        let sourceWidth = number(config["sourceWidth"]) ?? 0
        let sourceHeight = number(config["sourceHeight"]) ?? 0
        let isPercent = (config["sliceUnit"] as? String) == "percent"

        func slice(_ key: String, of extent: Double) -> Double {
            let raw = number(config[key]) ?? 0
            guard mode == "nineSlice" else { return 0 }
            return isPercent ? raw / 100 * extent : raw
        }

        if mode != "nineSlice", mode != "stretch" {
            notes.add(localized("氣泡皮膚圖的縮放方式不支援，已改為拉伸填滿。"))
        }

        return ReaderDialogueBubbleSkin(
            assetID: assetID,
            sliceTop: slice("sliceTop", of: sourceHeight),
            sliceRight: slice("sliceRight", of: sourceWidth),
            sliceBottom: slice("sliceBottom", of: sourceHeight),
            sliceLeft: slice("sliceLeft", of: sourceWidth),
            // Kept as the script's own factors: the skin is scaled against one
            // line of text at draw time, not against a fixed canvas.
            targetHeightScale: (number(config["targetHeightScale"]) ?? 100) / 100,
            cornerScale: (number(config["cornerScale"]) ?? 100) / 100,
            opacity: number(config["opacity"]) ?? 1
        )
    }

    private static func storeImage(
        source: String,
        name: String,
        assetStore: ReaderStyleAssetStore
    ) async throws -> UUID {
        guard source.hasPrefix("data:"),
              let separator = source.range(of: ";base64,"),
              let payload = Data(
                  base64Encoded: String(source[separator.upperBound...]),
                  options: .ignoreUnknownCharacters
              ) else {
            throw DialogueBubbleScriptImportError.skinDecodingFailed
        }
        do {
            return try await assetStore.importImage(data: payload, suggestedName: name).id
        } catch {
            AppLogger.render("dialogue bubble import: asset store rejected skin error=\(error)")
            throw DialogueBubbleScriptImportError.skinDecodingFailed
        }
    }

    private static func defaultFill(for side: ReaderDialogueBubbleSide) -> UInt32 {
        side == .left
            ? ReaderDialogueBubbleSideStyle.defaultLeft.fillHex
            : ReaderDialogueBubbleSideStyle.defaultRight.fillHex
    }

    // MARK: - Value helpers

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func hex(_ value: Any?) -> UInt32? {
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 else { return nil }
        return UInt32(text, radix: 16)
    }

    private struct NoteCollector {
        private(set) var values: [String] = []
        private var seen: Set<String> = []

        mutating func add(_ note: String) {
            guard seen.insert(note).inserted else { return }
            values.append(note)
        }
    }
}

struct DialogueBubbleScriptImport: Equatable, Sendable {
    var style: ReaderDialogueBubbleStyle
    var name: String?
    var notes: [String]
    var importedAssetIDs: [UUID]
}

enum DialogueBubbleScriptImportError: LocalizedError, Equatable {
    case notABubbleScript
    case configNotFound
    case configEvaluationFailed
    case skinDecodingFailed

    var errorDescription: String? {
        switch self {
        case .notABubbleScript:
            return localized("這不是可辨識的對話氣泡腳本檔。")
        case .configNotFound:
            return localized("這個腳本裡找不到可讀的設定區塊。")
        case .configEvaluationFailed:
            return localized("這個腳本的設定區塊無法解析。")
        case .skinDecodingFailed:
            return localized("氣泡皮膚圖無法解碼。")
        }
    }
}
