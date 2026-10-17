import Foundation

/// What the RSS export screens do with a `fileExporter` completion.
///
/// The completion is the only place a failed export surfaces: a document whose content cannot
/// be built throws from `fileWrapper`, and a save that the system refuses reports the same way.
/// Both end up here, so the failure is logged once and shown once, whichever way it happened.
enum RSSExportReport {
    enum Format {
        case opml
        case legadoJSON

        fileprivate var logName: String {
            switch self {
            case .opml: "opml"
            case .legadoJSON: "legado-json"
            }
        }
    }

    /// Logs a failed export and returns the text for the alert. `nil` means there is nothing
    /// to say: the file was saved, or the user dismissed the save panel.
    static func failureMessage(for result: Result<URL, Error>, format: Format) -> String? {
        guard case .failure(let error) = result else { return nil }
        // Dismissing the panel reports as an error, but it is the user's choice, not a failure.
        if (error as? CocoaError)?.code == .userCancelled { return nil }

        AppLogger.error("RSS export failed", error: error, context: ["format": format.logName], level: .error)
        let template = switch format {
        case .opml: localized("OPML 匯出失敗：%@")
        case .legadoJSON: localized("Legado JSON 匯出失敗：%@")
        }
        return String(format: template, error.localizedDescription)
    }
}
