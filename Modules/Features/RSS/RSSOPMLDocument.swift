import SwiftUI
import UniformTypeIdentifiers

struct RSSOPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(tag: "opml", tagClass: .filenameExtension, conformingTo: .xml), .xml, .data].compactMap { $0 } }
    /// The type the export is written as. The importer reads `org.opml.opml` (declared in
    /// Info.plist, conforming to `public.xml`), so the file must be saved as that — `.xml` would
    /// hand the save panel a generic type for a file named `.opml`.
    static let exportContentType = UTType(importedAs: "org.opml.opml")
    static var writableContentTypes: [UTType] { [exportContentType] }

    var text: String

    init(sources: [RSSSource]) {
        text = RSSOPMLExporter.export(sources: sources)
    }

    // Required by `FileDocument`, but never called: this document is only handed to
    // `.fileExporter`, which writes and never reads. OPML is imported through `fileImporter`,
    // a URL or `RSSOPMLParser`. If a reader is ever added, throw
    // `CocoaError(.fileReadCorruptFile)` here instead of turning unreadable data into "".
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
