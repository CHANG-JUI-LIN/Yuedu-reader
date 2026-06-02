import SwiftUI
import UniformTypeIdentifiers

struct RSSOPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(tag: "opml", tagClass: .filenameExtension, conformingTo: .xml), .xml, .data].compactMap { $0 } }
    static var writableContentTypes: [UTType] { [.xml] }

    var text: String

    init(sources: [RSSSource]) {
        text = RSSOPMLExporter.export(sources: sources)
    }

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
