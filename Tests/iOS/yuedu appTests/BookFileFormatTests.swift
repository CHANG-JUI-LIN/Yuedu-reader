import Foundation
import Testing
import UniformTypeIdentifiers
@testable import yuedu_app

/// Every gate that decides whether a file is a readable book, read from one table
/// (MOBI plan, step 4): pinned before the gates moved onto it, then with MOBI and AZW3.
@Suite("Book file formats")
struct BookFileFormatTests {
    /// In reading preference, as Calibre's wireless device is offered them.
    static let documents = ["epub", "azw3", "mobi", "prc", "azw", "pdf", "txt", "md", "markdown"]
    /// What is sent to a remote library: nothing here writes a Kindle file to a server.
    static let uploadable = ["epub", "pdf", "txt", "md", "markdown"]
    static let localOnly = ["json", "cbz", "zip", "mp3", "m4a", "m4b", "aac", "flac", "wav"]
    static let unreadable = ["docx", "html", "kfx"]

    @Test("local import reads documents, the JSON book, comics and audio")
    func localImport() {
        #expect(LocalBookImportService.supportedExtensions == Set(Self.documents + Self.localOnly))
    }

    @Test("Calibre's wireless device is offered documents only, EPUB first")
    func calibreWireless() {
        #expect(CalibreWirelessHandshake.supportedExtensions == Self.documents)
    }

    @Test("a remote library item and a WebDAV file are readable as documents only")
    func remoteAndWebDAV() throws {
        for ext in Self.documents + Self.localOnly + Self.unreadable {
            let url = try #require(URL(string: "https://example.com/book." + ext.uppercased()))
            let readable = Self.documents.contains(ext)
            #expect(RemoteLibraryFormat(url: url, fileExtension: ext.uppercased(), mimeType: "").isSupported == readable,
                    "\(ext)")
            #expect(WebDAVBrowseClient.Entry(url: url, name: "book", isDirectory: false, size: 1).isImportableBook
                    == readable, "\(ext)")
        }
    }

    @Test("an OPDS acquisition is named by its media type, or by its file name when that is generic",
          arguments: [
            ("application/epub+zip", "book", "epub"),
            ("application/epub+zip;profile=opds-catalog", "book", "epub"),
            ("application/pdf", "book", "pdf"),
            ("text/markdown", "book", "md"),
            ("text/x-markdown", "book", "md"),
            ("text/plain", "book", "txt"),
            ("text/plain; charset=utf-8", "book", "txt"),
            ("TEXT/PLAIN", "book", "txt"),
            ("text/html", "book.epub", nil),
            ("application/x-mobipocket-ebook", "book.mobi", "mobi"),
            ("application/vnd.amazon.ebook", "book", "mobi"),
            ("application/x-mobi8-ebook", "book.azw3", "azw3"),
            ("application/vnd.amazon.mobi8-ebook", "book", "azw3"),
            // Project Gutenberg's KF8 file: the kind is read from the file at import.
            ("application/x-mobipocket-ebook", "1342.kf8.images", "mobi"),
            ("", "book.MARKDOWN", "md"),
            ("application/octet-stream", "book.txt", "txt"),
            ("application/octet-stream", "book.epub", "epub"),
            ("application/octet-stream", "book.mobi", "mobi"),
            ("application/octet-stream", "book.prc", "mobi"),
            ("application/octet-stream", "book.azw3", "azw3"),
            ("", "book.zip", nil),
          ] as [(String, String, String?)])
    func opdsMediaType(type: String, file: String, expected: String?) throws {
        let acquisition = OPDSAcquisition(url: try #require(URL(string: "https://example.com/" + file)), type: type,
                                          rel: "http://opds-spec.org/acquisition")
        #expect(acquisition.importExtension == expected)
        #expect(acquisition.isSupported == (expected != nil))
    }

    @Test("an OPDS acquisition's preference: EPUB 3, EPUB, AZW3, MOBI, PDF, text, Markdown, then anything else")
    func opdsPreference() throws {
        func preference(_ file: String, _ type: String) throws -> Int {
            OPDSAcquisition(url: try #require(URL(string: "https://example.com/" + file)), type: type, rel: "").preference
        }
        #expect(try preference("1342.epub3.images", "application/epub+zip") == 0)
        #expect(try preference("1342.epub.images", "application/epub+zip") == 1)
        #expect(try preference("book.azw3", "application/x-mobi8-ebook") == 2)
        #expect(try preference("book.mobi", "application/x-mobipocket-ebook") == 3)
        #expect(try preference("book.pdf", "application/pdf") == 4)
        #expect(try preference("book.txt", "text/plain") == 5)
        #expect(try preference("book.md", "text/markdown") == 6)
        #expect(try preference("book.zip", "application/zip") == 9)
    }

    @Test("a remote file's media type comes from its extension")
    func remoteMediaType() {
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "EPUB") == "application/epub+zip")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "pdf") == "application/pdf")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "txt") == "text/plain")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "md") == "text/markdown")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "markdown") == "text/markdown")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "AZW3") == "application/x-mobi8-ebook")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "mobi") == "application/x-mobipocket-ebook")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "prc") == "application/x-mobipocket-ebook")
        #expect(RemoteLibraryBrowsePresentation.mimeType(for: "cbz") == "application/octet-stream")
    }

    @Test("a remote library is sent documents other than Kindle files")
    func upload() {
        #expect(BookFileFormat.uploadExtensions == Set(Self.uploadable))
    }

    /// The Files picker and "Open in" match a file by these types. Without the app's own
    /// declaration, a Kindle extension is only a `dyn.` type that nothing else declares.
    @Test("every Kindle extension has a declared type", arguments: ["mobi", "prc", "azw", "azw3"])
    func declaredType(ext: String) throws {
        let type = try #require(UTType(filenameExtension: ext))
        #expect(!type.isDynamic, "\(type.identifier)")
        #expect(type.conforms(to: .data))
    }

    @Test("a remote item opens in its most readable format, else its first")
    func remotePreferredFormat() throws {
        func preferred(_ extensions: [String]) throws -> String? {
            let formats = try extensions.map { ext in
                RemoteLibraryFormat(url: try #require(URL(string: "https://example.com/book." + ext)),
                                    fileExtension: ext, mimeType: "")
            }
            return RemoteLibraryBrowsePresentation.preferredFormat(
                in: RemoteLibraryItem(id: "book", connectionID: "library", title: "Book", formats: formats))?.fileExtension
        }
        #expect(try preferred(["md", "txt", "pdf", "mobi", "azw3", "epub"]) == "epub")
        #expect(try preferred(["md", "txt", "pdf", "mobi", "azw3"]) == "azw3")
        #expect(try preferred(["md", "txt", "pdf", "mobi"]) == "mobi")
        #expect(try preferred(["md", "txt", "pdf"]) == "pdf")
        #expect(try preferred(["md", "txt"]) == "txt")
        #expect(try preferred(["cbz", "markdown"]) == "markdown")
        #expect(try preferred(["cbz", "zip"]) == "cbz")
        #expect(try preferred([]) == nil)
    }
}
