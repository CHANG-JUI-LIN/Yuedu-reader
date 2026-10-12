import CoreGraphics
import Foundation
import ImageIO
import UIKit

enum HighlightPackImportError: LocalizedError, Equatable {
    case unreadable

    var errorDescription: String? {
        localized("這不是可讀取的高亮規則包。")
    }
}

/// What a highlight-rule pack from another reader turned into.
struct HighlightPackImport {
    var name: String?
    var rules: [RegexHighlightRule]
    var notes: [String]
}

/// Standalone highlight-rule packs exported by other readers, imported on their own —
/// from 正則高亮's 匯入規則 or shared in from Files:
///
/// - Reeden `.red`: `RED` 0x01, then a gzip member holding
///   `{ "type": "highlightRule", "data": [rule…] }`. Rules are the same objects a theme
///   binds, so they go through `ReedenThemeImporter.highlightRules`.
/// - QiReader `.qihighlight`: a ZIP of `<name>/manifest.json` plus `assets/` images.
enum HighlightPackImporter {
    enum Format: Equatable {
        case reeden
        case qiReader
    }

    private static let reedenHighlightVersion: UInt8 = 0x01

    /// A `.red` is a theme or a highlight pack; only the header tells them apart.
    static func format(fileExtension: String, data: Data) -> Format? {
        switch fileExtension.lowercased() {
        case "qihighlight":
            return .qiReader
        case "red":
            return isReedenHighlightPack(data) ? .reeden : nil
        default:
            return nil
        }
    }

    static func isReedenHighlightPack(_ data: Data) -> Bool {
        ReedenThemeImporter.isReedenContainer(data)
            && data[data.startIndex + 3] == reedenHighlightVersion
    }

    /// The colours a pack's `{primaryColor}` placeholder stands for, and the body size its
    /// `em` lengths refer to — a standalone pack has no reading schema of its own, so the
    /// caller supplies the user's.
    struct Context {
        var lightPrimaryHex: UInt32?
        var darkPrimaryHex: UInt32?
        var bodySize: Double
    }

    static func parse(
        _ data: Data,
        format: Format,
        context: Context,
        assetStore: ReaderStyleAssetStore
    ) async throws -> HighlightPackImport {
        switch format {
        case .reeden:
            return try await parseReeden(data, context: context, assetStore: assetStore)
        case .qiReader:
            return try await parseQiReader(data, assetStore: assetStore)
        }
    }

    /// A pack is imported to be worn (decided 2026-10-12): its rules come in switched on.
    /// Packs that offer several looks for the same text — 夏以昼's twelve dialogue bubbles,
    /// all one pattern — would stack them all, so per pattern only the first rule the file
    /// had on (else its first) is on.
    static func worn(_ rules: [RegexHighlightRule]) -> [RegexHighlightRule] {
        var chosen: [String: String] = [:] // pattern → id of the rule worn for it
        for rule in rules where chosen[rule.pattern] == nil {
            chosen[rule.pattern] = (rules.first { $0.pattern == rule.pattern && $0.isEnabled } ?? rule).id
        }
        return rules.map { rule in
            var rule = rule
            rule.isEnabled = chosen[rule.pattern] == rule.id
            return rule
        }
    }

    // MARK: - Reeden

    private struct ReedenPackFile: Decodable {
        var version: Int?
        var type: String?
        var data: [ReedenHighlightRule]?
    }

    private static func parseReeden(
        _ data: Data,
        context: Context,
        assetStore: ReaderStyleAssetStore
    ) async throws -> HighlightPackImport {
        guard isReedenHighlightPack(data) else { throw HighlightPackImportError.unreadable }
        let file: ReedenPackFile
        do {
            let json = try GzipDecoder.decompress(
                Data(data.dropFirst(4)),
                maximumBytes: QiThemeImporter.maximumExpandedBytes
            )
            file = try JSONDecoder().decode(ReedenPackFile.self, from: json)
        } catch {
            AppLogger.parse("⟐ red highlight pack unreadable", error: error)
            throw HighlightPackImportError.unreadable
        }
        guard file.type == "highlightRule", let source = file.data else {
            AppLogger.parse("⟐ red highlight pack has no rules", context: ["type": file.type ?? "nil"])
            throw HighlightPackImportError.unreadable
        }
        func schema(_ hex: UInt32?) -> ReedenReaderSchema {
            ReedenReaderSchema(primaryColor: hex.map { String(format: "#%06X", $0) })
        }
        var notes: [String] = []
        let rules = await ReedenThemeImporter.highlightRules(
            source,
            light: schema(context.lightPrimaryHex),
            dark: schema(context.darkPrimaryHex ?? context.lightPrimaryHex),
            bodySize: context.bodySize,
            assetStore: assetStore,
            notes: &notes
        )
        let groups = Set(source.compactMap { $0.groupName?.trimmedNonEmpty })
        return HighlightPackImport(name: groups.count == 1 ? groups.first : nil, rules: rules, notes: notes)
    }

    // MARK: - QiReader

    private struct QiPackFile: Decodable {
        var version: Int?
        var assetFiles: [String: String]?
        var rules: [QiPackRule]?
    }

    private struct QiPackRule: Decodable {
        var name: String?
        var regex: String?
        var enabled: Bool?
        var noCrossParagraph: Bool?
        var fontFamily: String?
        var fontSize: Double?
        var lightColorHex: String?
        var darkColorHex: String?
        var lightStyleCSS: String?
        var darkStyleCSS: String?
        var lightBackgroundImageURL: String?
        var darkBackgroundImageURL: String?
        var lightBackgroundImageLayout: QiImageLayout?
        var darkBackgroundImageLayout: QiImageLayout?
        // `crossPageQuotes` needs no mapping: rules match the chapter text before it
        // is paginated, so a quote that runs onto the next page is already one match.
    }

    private struct QiImageLayout: Decodable {
        var contentInsets: QiThemeInsets?
        var sliceInsets: QiThemeInsets?
        var horizontalOffset: Double?
        var verticalOffset: Double?
        var horizontalScale: Double?
        var verticalScale: Double?
        var opacity: Double?
    }

    private static func parseQiReader(
        _ data: Data,
        assetStore: ReaderStyleAssetStore
    ) async throws -> HighlightPackImport {
        guard data.count <= QiThemeImporter.maximumExpandedBytes,
              data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw HighlightPackImportError.unreadable
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("qihighlight-import-\(UUID().uuidString)", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                AppLogger.parse("⟐ qihighlight staging not removed", error: error)
            }
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archiveURL = staging.appendingPathComponent("source.zip", isDirectory: false)
        try data.write(to: archiveURL, options: .atomic)
        let root = staging.appendingPathComponent("contents", isDirectory: true)
        let paths = try await QiThemeImporter.extractArchive(at: archiveURL, into: root)

        // `<pack name>/manifest.json`; the shallowest one is the pack's.
        guard let manifestPath = paths
            .filter({ ($0 as NSString).lastPathComponent == "manifest.json" })
            .min(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) else {
            AppLogger.parse("⟐ qihighlight has no manifest", context: ["entries": "\(paths.count)"])
            throw HighlightPackImportError.unreadable
        }
        let manifestURL = root.appendingPathComponent(manifestPath, isDirectory: false)
        let file: QiPackFile
        do {
            file = try JSONDecoder().decode(QiPackFile.self, from: Data(contentsOf: manifestURL))
        } catch {
            AppLogger.parse("⟐ qihighlight manifest unreadable", error: error)
            throw HighlightPackImportError.unreadable
        }
        guard let source = file.rules, !source.isEmpty else { throw HighlightPackImportError.unreadable }
        let assetsDirectory = manifestURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)

        var rules: [RegexHighlightRule] = []
        var notes: [String] = []
        var skipped: [String] = []
        var unreadableArtwork: [String] = []
        var missingFonts: Set<String> = []
        var dropped: Set<String> = []
        var scaled = false
        for rule in source {
            let name = rule.name?.trimmedNonEmpty ?? localized("高亮規則")
            guard let pattern = rule.regex, !pattern.isEmpty else {
                skipped.append(name)
                continue
            }
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                AppLogger.parse("⟐ qihighlight pattern invalid", error: error, context: ["rule": name])
                skipped.append(name)
                continue
            }
            func image(_ url: String?) async throws -> (asset: ReaderStyleAsset, size: CGSize)? {
                guard let url = url?.trimmedNonEmpty else { return nil }
                guard let fileName = file.assetFiles?[url] else { throw HighlightPackImportError.unreadable }
                let data = try Data(contentsOf: assetsDirectory.appendingPathComponent(fileName))
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    throw HighlightPackImportError.unreadable
                }
                let asset = try await assetStore.importImage(data: data, suggestedName: name)
                return (asset, CGSize(width: width, height: height))
            }
            let lightImage: (asset: ReaderStyleAsset, size: CGSize)?
            let darkImage: (asset: ReaderStyleAsset, size: CGSize)?
            do {
                lightImage = try await image(rule.lightBackgroundImageURL)
                darkImage = try await image(rule.darkBackgroundImageURL)
            } catch {
                AppLogger.parse("⟐ qihighlight artwork unreadable", error: error, context: ["rule": name])
                unreadableArtwork.append(name)
                continue
            }
            var font: String?
            if let family = rule.fontFamily?.trimmedNonEmpty {
                if UIFont(name: family, size: 12) != nil {
                    font = family
                } else {
                    missingFonts.insert(family)
                }
            }
            func style(
                css: String?, colorHex: String?, image: (asset: ReaderStyleAsset, size: CGSize)?,
                layout: QiImageLayout?
            ) -> ReaderStyleRuleStyle {
                var style = ReaderStyleCSSCodec.decodeLeniently(
                    qiDeclarations(css ?? ""), context: .regexHighlight, dropped: &dropped
                )
                if let color = QiThemeValue.hex(colorHex) { style.text.colorHex = color }
                if let font { style.text.fontPostScriptName = font }
                if let size = rule.fontSize, size > 0 { style.text.fontSize = size }
                // Imageless rules carry default layouts too; they only mean something
                // with a picture to place.
                if let image {
                    let slices = layout?.sliceInsets.flatMap { insets in
                        ReaderStyleImageSlices(
                            pixelsTop: insets.top ?? 0, right: insets.right ?? 0,
                            bottom: insets.bottom ?? 0, left: insets.left ?? 0,
                            of: image.size
                        )
                    }
                    style.decoration.backgroundImage = ReaderStyleImagePresentation(
                        assetID: image.asset.id,
                        contentMode: .stretch,
                        opacity: layout?.opacity ?? 1,
                        nineSlice: slices
                    )
                    style.decoration.backgroundGradient = nil
                    if let insets = layout?.contentInsets {
                        style.decoration.padding = ReaderStyleEdges(
                            top: insets.top ?? 0, leading: insets.left ?? 0,
                            bottom: insets.bottom ?? 0, trailing: insets.right ?? 0
                        )
                    }
                    let range = ReaderStyleDecorationStyle.imageOffsetRange
                    if let x = layout?.horizontalOffset, x != 0 {
                        style.decoration.backgroundImageOffsetX = min(max(x, range.lowerBound), range.upperBound)
                    }
                    if let y = layout?.verticalOffset, y != 0 {
                        style.decoration.backgroundImageOffsetY = min(max(y, range.lowerBound), range.upperBound)
                    }
                    if (layout?.horizontalScale ?? 1) != 1 || (layout?.verticalScale ?? 1) != 1 {
                        scaled = true
                    }
                }
                return style
            }
            rules.append(RegexHighlightRule(
                id: UUID().uuidString,
                name: name,
                pattern: pattern,
                isEnabled: rule.enabled ?? true,
                isBuiltIn: false,
                options: rule.noCrossParagraph == true ? [.doesNotCrossParagraph] : [],
                lightStyle: style(
                    css: rule.lightStyleCSS, colorHex: rule.lightColorHex,
                    image: lightImage, layout: rule.lightBackgroundImageLayout
                ),
                darkStyle: style(
                    css: rule.darkStyleCSS, colorHex: rule.darkColorHex,
                    image: darkImage, layout: rule.darkBackgroundImageLayout
                )
            ))
        }
        if !skipped.isEmpty {
            notes.append(String(
                format: localized("下列高亮規則的正則無法使用，已略過：%@"),
                skipped.joined(separator: localized("、"))
            ))
        }
        if !unreadableArtwork.isEmpty {
            notes.append(String(
                format: localized("下列高亮規則的背景圖片無法讀取，已略過：%@"),
                unreadableArtwork.joined(separator: localized("、"))
            ))
        }
        if !missingFonts.isEmpty {
            notes.append(String(
                format: localized("高亮規則使用的字型未安裝：%@，已改用閱讀字型顯示。"),
                missingFonts.sorted().joined(separator: localized("、"))
            ))
        }
        if scaled {
            notes.append(localized("高亮背景圖的縮放比例沒有對應設定，已依文字高度縮放。"))
        }
        if !dropped.isEmpty {
            notes.append(String(
                format: localized("高亮規則的下列樣式沒有對應設定，已略過：%@"),
                dropped.sorted().joined(separator: localized("、"))
            ))
        }
        let packName = (manifestPath.split(separator: "/").dropLast().last).map(String.init)
        return HighlightPackImport(
            name: packName?.trimmedNonEmpty ?? (rules.count == 1 ? rules.first?.name : nil),
            rules: rules,
            notes: notes
        )
    }

    /// QiReader's CSS uses the `background` shorthand, which this codec has no property
    /// for; a gradient or a colour is what it carries in every pack seen.
    static func qiDeclarations(_ css: String) -> [(name: String, value: String)] {
        css.split(separator: ";").compactMap { raw in
            guard let colon = raw.firstIndex(of: ":") else { return nil }
            var name = raw[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = raw[raw.index(after: colon)...]
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { return nil }
            if name == "background" {
                name = value.lowercased().contains("gradient(") ? "background-image" : "background-color"
            }
            return (name, value)
        }
    }
}
