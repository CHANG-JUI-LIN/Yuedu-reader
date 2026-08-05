import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The whole customised look as one `.json` for `ShareLink`: themes, page
/// backgrounds, bottom-tab icons, launch images and the reading background,
/// every image embedded — see `AppearanceCustomizationBundle`.
///
/// Holds only the cheap snapshot (values and file names). Every disk read and
/// base64 happens inside the transfer closure, because this backs a visible row
/// and the finished bundle can run to tens of megabytes.
struct AppearanceCustomizationExportPayload: Transferable {
    /// Filename including the `.json` extension. Build it with `filename(for:)`.
    let filename: String
    let snapshot: AppearanceCustomizationSnapshot

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { payload in
            let bundle = AppearanceCustomizationBundle(snapshot: payload.snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(bundle)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(payload.filename)
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    static func filename(for label: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = label
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "appearance" : String(cleaned.prefix(60))
        return "yuedu-appearance-\(base).json"
    }
}
