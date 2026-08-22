import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Legado-format `.json` payload handed to `ShareLink` for 匯出書源（儲存到「檔案」、AirDrop…）.
///
/// Shared through `ShareLink` rather than `.fileExporter` on purpose: a document picker opened
/// from a SwiftUI `Menu` action hits the iOS 17 menu-dismissal race documented in
/// `Technotes/iOS17MenuModalPresentation.md`, and the only workaround already in this repo for
/// that combination is an `asyncAfter` delay, which this project bans. 「儲存到檔案」 is also one
/// tap inside the share sheet.
///
/// `ShareLink` does NOT escape that race, though — this comment used to claim UIKit ownership
/// removed the boundary, and 匯出書源 was reported dead on iOS 17.7 because of it. The share
/// sheet is a second presentation like any other, so the link has to be a direct page or sheet
/// control: `BookSourceExportShareLink` hands this payload to `BookSourceListView`'s
/// first-level `ShareExportSheet` before iOS 18. See `MenuShareLinkPresentationPolicy`.
///
/// Carries the sources as a snapshot and encodes only when a share actually completes: `Menu`
/// content is built eagerly with its parent row, so encoding at construction time would
/// re-serialize every visible source on every layout pass. The snapshot also keeps the encode
/// off `BookSourceStore`, which is main-actor state the transfer closure must not reach into.
struct BookSourceExportFile: Transferable {
    /// Filename including the `.json` extension. Build it with `filename(for:)`.
    let filename: String
    let sources: [BookSource]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            // Pretty-printed because this copy is meant to be opened and read; the
            // clipboard export stays compact for pasting into a chat.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(file.sources)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// Turns a user-facing label (書源名稱, 分組名, 「全部書源」…) into a safe `.json` filename.
    /// Group and source names come from imported JSON, so they can contain path separators and
    /// newlines that would otherwise produce an unwritable URL.
    static func filename(for label: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = label
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "book-sources" : String(cleaned.prefix(60))
        return "\(base).json"
    }
}
