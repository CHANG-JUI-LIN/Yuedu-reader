import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Reads a 段評氣泡 style or a card template file into 氣泡設定's library and wears it — the
/// one route behind every 匯入樣式 on those pages, run by `readerStyleImportPresentation`.
@MainActor
enum ReaderCommentStyleImporter {
    enum Target: Equatable, Sendable {
        case bubble
        case card(ReaderCommentCardKind)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let contentTypes: [UTType] = [.svg, .json, .plainText, .data]

    static func importFile(at url: URL, into target: Target) throws -> String {
        let data = try Data(contentsOf: url)
        let fileName = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .bubble:
            return try importBubble(data, fileName: fileName)
        case .card(let kind):
            return try importCard(data, fileName: fileName, kind: kind)
        }
    }

    // MARK: - 段評氣泡

    /// A `bubble.json` keeps its colours and size; a bare SVG is taken as it is.
    static func importBubble(_ data: Data, fileName: String) throws -> String {
        let settings = GlobalSettings.shared
        if let style = ReaderCommentBubbleCustomStyle.fromBubblePackage(data) {
            if let message = bubbleValidationMessage(for: style.svg) { throw Failure(message: message) }
            settings.upsertCommentBubbleCustomStyle(style)
            if let scale = style.sizeScale {
                settings.commentBubbleScale = GlobalSettings.sanitizedCommentBubbleScale(scale)
            }
            settings.commentBubbleFollowsSourceSVG = false
            return localized("已套用自訂段評氣泡 SVG。")
        }
        guard let svg = String(data: data, encoding: .utf8) else {
            throw Failure(message: localized("檔案不是可讀取的 SVG。"))
        }
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = bubbleValidationMessage(for: trimmed) { throw Failure(message: message) }
        settings.upsertCommentBubbleCustomStyle(
            ReaderCommentBubbleCustomStyle(name: fileName.isEmpty ? localized("自訂 SVG") : fileName, svg: trimmed)
        )
        settings.commentBubbleFollowsSourceSVG = false
        return localized("已套用自訂段評氣泡 SVG。")
    }

    /// Why `svg` cannot be a 段評 bubble, or nil when it can.
    static func bubbleValidationMessage(for svg: String) -> String? {
        if svg.utf8.count > CommentBubbleSVGRecognizer.maximumUserTemplateSVGByteCount {
            return String(
                format: localized("SVG 檔案過大，請使用小於 %d KB 的氣泡樣式。"),
                CommentBubbleSVGRecognizer.maximumUserTemplateSVGByteCount / 1024
            )
        }
        guard svg.lowercased().contains("<svg") else {
            return localized("檔案不是可讀取的 SVG。")
        }
        guard CommentBubbleSVGRecognizer.recognizeUserTemplate(svg) != nil else {
            return localized("這個 SVG 沒有可繪製的內容，無法作為段評氣泡。")
        }
        return nil
    }

    // MARK: - Cards

    /// A package names its own kind and lands there, wherever it was imported from; a bare
    /// SVG becomes a template of `kind`.
    static func importCard(_ data: Data, fileName: String, kind: ReaderCommentCardKind) throws -> String {
        let style: ReaderCommentCardCustomStyle
        if let package = ReaderCommentCardPackageFile.decode(data) {
            style = package.makeStyle()
        } else {
            guard let svg = String(data: data, encoding: .utf8) else {
                throw Failure(message: localized("檔案不是可讀取的 SVG。"))
            }
            style = ReaderCommentCardCustomStyle(
                kind: kind,
                name: fileName.isEmpty ? localized("自訂模板") : fileName,
                svg: svg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        do {
            _ = try ReviewCardTemplate(source: style.svg)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        GlobalSettings.shared.upsertCommentCardStyle(style)
        return appliedMessage(for: style.kind)
    }

    static func appliedMessage(for kind: ReaderCommentCardKind) -> String {
        switch kind {
        case .chapterSay: return localized("已套用自訂本章說模板。")
        case .authorSay: return localized("已套用自訂作者說模板。")
        case .hotComment: return localized("已套用自訂神評論模板。")
        }
    }
}

// MARK: - Export

/// 匯出目前樣式 as a bare `.svg`: the built-in styles, and custom ones with nothing else to carry.
///
/// `ShareLink` rather than `.fileExporter`, as a direct Form row, for the reason recorded in
/// `Technotes/iOS17MenuModalPresentation.md`.
struct CommentStyleSVGExport: Transferable {
    let filename: String
    let svg: String

    init(name: String, svg: String) {
        filename = ReaderStyleExportFilename.make(name, pathExtension: "svg")
        self.svg = svg
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .svg) { payload in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(payload.filename)
            try Data(payload.svg.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// 匯出目前樣式 as JSON: a 段評 bubble's `bubble.json`, or a card template's package — the
/// forms that keep colours a bare `.svg` would lose.
struct CommentStyleJSONExport: Transferable {
    let filename: String
    let data: Data

    init(bubble style: ReaderCommentBubbleCustomStyle) throws {
        filename = ReaderStyleExportFilename.make(style.name, pathExtension: "json")
        data = try Self.encoder.encode(BubblePackageFile(style: style))
    }

    init(card style: ReaderCommentCardCustomStyle) throws {
        filename = ReaderStyleExportFilename.make(style.name, pathExtension: "json")
        data = try Self.encoder.encode(ReaderCommentCardPackageFile(style: style))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { payload in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(payload.filename)
            try payload.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
