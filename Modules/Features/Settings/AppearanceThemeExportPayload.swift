import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The `.json` theme package handed to `ShareLink` for 匯出主題 — AirDrop,
/// 訊息, and 儲存到「檔案」 all come out of the one share sheet.
///
/// `ShareLink` rather than `.fileExporter` for the reason recorded in
/// `Technotes/iOS17MenuModalPresentation.md`: a document picker opened from a
/// `Menu` / `contextMenu` action hits the iOS 17 menu-dismissal race, and
/// per-theme export lives in exactly such a menu. UIKit owns the share sheet's
/// presentation, so there is no second presentation to sequence.
///
/// Carries the cheap value snapshot (colors plus background *file names*) and
/// reads the image bytes only inside the transfer closure. Menu content is
/// built with its row, and a theme with page backgrounds base64s to megabytes —
/// building that eagerly would run on every layout pass.
struct AppearanceThemeExportPayload: Transferable {
    /// Filename including the `.json` extension. Build it with `filename(for:)`.
    let filename: String
    let themes: [AppearanceCustomTheme]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { payload in
            let files = payload.themes.map(AppearanceThemeExportFile.init(customTheme:))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // A lone theme stays a plain theme file so it opens in any build;
            // several become the collection envelope.
            let data: Data
            if files.count == 1, let single = files.first {
                data = try encoder.encode(single)
            } else {
                data = try encoder.encode(AppearanceThemeCollectionFile(themes: files))
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// Turns a theme name into a safe `.json` filename. Names are user-entered
    /// and can arrive from an imported file, so they can carry path separators
    /// and newlines that would otherwise produce an unwritable URL.
    static func filename(for label: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = label
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "theme" : String(cleaned.prefix(60))
        return "yuedu-theme-\(base).json"
    }
}
