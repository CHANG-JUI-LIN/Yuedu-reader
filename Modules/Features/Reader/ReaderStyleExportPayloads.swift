import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The `.yuedustyle` archives handed to `ShareLink` for 匯出正則高亮 and
/// 匯出閱讀設定 — AirDrop, 訊息 and 儲存到「檔案」 all come out of the one share sheet.
///
/// `ShareLink` rather than `.fileExporter` for the reason recorded in
/// `Technotes/iOS17MenuModalPresentation.md`. These links stay as direct Form rows
/// on pages pushed inside 閱讀設定. Moving them into a `Menu` would make the share
/// sheet race that menu's dismissal on iOS 17; replacing them with `.fileExporter`
/// would also add a document-picker presentation under the settings sheet.
///
/// Each payload carries only the cheap value snapshot; the archive — which reads
/// image assets off disk and zips them — is built inside the transfer closure.
/// SwiftUI can rebuild the visible export row repeatedly, so building megabytes
/// eagerly would run on every layout pass.
enum ReaderStyleExportFilename {
    /// Turns a label into a safe `.yuedustyle` filename. Rule and preset names
    /// are user-entered and can arrive from an imported file, so they can carry
    /// path separators and newlines that would produce an unwritable URL.
    static func make(_ label: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = label
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "style" : String(cleaned.prefix(60))
        return "\(base).yuedustyle"
    }
}

struct ChapterTitleStyleExportPayload: Transferable {
    let filename: String
    let style: ChapterTitleStyle

    init(style: ChapterTitleStyle) {
        self.filename = ReaderStyleExportFilename.make(localized("章節標題樣式"))
        self.style = style
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .yueduReaderStyle) { payload in
            let stylePayload = try ReaderStylePackagePayload.encode(
                payload.style,
                kind: .chapterTitle,
                assetIDs: ReaderStyleAssetReferences.assetIDs(in: payload.style)
            )
            let data = try await ReaderStylePackage.export(stylePayload, assetStore: .shared)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct RegexHighlightExportPayload: Transferable {
    let filename: String
    let configuration: RegexHighlightConfiguration

    init(configuration: RegexHighlightConfiguration) {
        self.filename = ReaderStyleExportFilename.make(localized("正則高亮"))
        self.configuration = configuration
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .yueduReaderStyle) { payload in
            let stylePayload = try ReaderStylePackagePayload.encode(
                payload.configuration,
                kind: .regexHighlights,
                assetIDs: ReaderStyleAssetReferences.assetIDs(in: payload.configuration)
            )
            let data = try await ReaderStylePackage.export(stylePayload, assetStore: .shared)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct ReaderSettingsExportPayload: Transferable {
    let filename: String
    let inputs: ReaderSettingsExportInputs

    init(inputs: ReaderSettingsExportInputs) {
        self.filename = ReaderStyleExportFilename.make(localized("閱讀設定"))
        self.inputs = inputs
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .yueduReaderStyle) { payload in
            let bundle = try payload.inputs.makeBundle()
            let stylePayload = try ReaderStylePackagePayload.encode(
                bundle,
                kind: .readerSettings,
                assetIDs: bundle.assetIDs
            )
            let data = try await ReaderStylePackage.export(stylePayload, assetStore: .shared)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
