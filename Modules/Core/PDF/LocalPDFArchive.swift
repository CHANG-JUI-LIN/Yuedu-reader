import Foundation
import PDFKit
import UIKit

// MARK: - Local PDF document model
//
// Reads a user-imported PDF with PDFKit: metadata, page count, and the document's
// own bookmarks (outline) turned into a flat table of contents.
//
// A PDF book is a `.fixedPage` pipeline book with a *single* chapter holding every
// page, so page numbers stay absolute (「第 137 / 500 頁」) and the reader never
// reloads at a section boundary. The outline sections are carried separately and
// used purely as jump targets by `FixedPageReaderViewController`.

struct LocalPDFImportInfo: Equatable {
    let title: String
    let author: String
    let pageCount: Int
    let sections: [FixedPageDocumentSection]
}

enum LocalPDFArchiveError: LocalizedError {
    case invalidFileType
    case cannotReadDocument
    case passwordProtected
    case noPagesFound

    var errorDescription: String? {
        switch self {
        case .invalidFileType:
            return localized("不支援的 PDF 格式")
        case .cannotReadDocument:
            return localized("無法讀取 PDF 檔案")
        case .passwordProtected:
            return localized("這個 PDF 有密碼保護，目前無法開啟")
        case .noPagesFound:
            return localized("PDF 中未找到頁面")
        }
    }
}

enum LocalPDFArchive {
    static let allowedExtensions = Set(["pdf"])

    static func supports(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    /// The user's own PDF file, so it stays in Documents alongside EPUB/CBZ imports.
    static func archiveURL(for filename: String) -> URL {
        StorageLocations.bookFile(filename)
    }

    static func openDocument(at url: URL) throws -> PDFDocument {
        guard supports(url) else { throw LocalPDFArchiveError.invalidFileType }
        guard let document = PDFDocument(url: url) else {
            throw LocalPDFArchiveError.cannotReadDocument
        }
        // An encrypted PDF opens but every page renders blank; surface it at import
        // time instead of shipping the user a book of empty pages.
        guard !document.isLocked else { throw LocalPDFArchiveError.passwordProtected }
        guard document.pageCount > 0 else { throw LocalPDFArchiveError.noPagesFound }
        return document
    }

    static func inspect(url: URL) throws -> LocalPDFImportInfo {
        let document = try openDocument(at: url)
        let attributes = document.documentAttributes ?? [:]

        // The filename wins over the PDF's own /Title, unlike EPUB or ComicInfo
        // metadata: a PDF's /Title is whatever produced it ("Microsoft Word -
        // Document1", "untitled", a print template), while the filename is the name
        // the user gave the file. Same rule Books and Preview follow.
        let filenameTitle = cleanTitle(url.deletingPathExtension().lastPathComponent)
        let embeddedTitle = string(attributes[PDFDocumentAttribute.titleAttribute])
        let embeddedAuthor = string(attributes[PDFDocumentAttribute.authorAttribute])

        return LocalPDFImportInfo(
            title: filenameTitle.isEmpty ? embeddedTitle : filenameTitle,
            author: embeddedAuthor.isEmpty ? localized("未知作者") : embeddedAuthor,
            pageCount: document.pageCount,
            sections: sections(in: document)
        )
    }

    /// Flatten the PDF's bookmark tree, depth-first, into page jump targets.
    ///
    /// Nested levels are indented with figure spaces so the flat chapter list still
    /// reads as a hierarchy. Entries whose destination can't be resolved to a page
    /// are dropped — they'd be dead rows in the table of contents.
    static func sections(in document: PDFDocument) -> [FixedPageDocumentSection] {
        guard let root = document.outlineRoot else { return [] }

        var result: [FixedPageDocumentSection] = []
        var stack: [(node: PDFOutline, depth: Int)] = []
        for index in stride(from: root.numberOfChildren - 1, through: 0, by: -1) {
            if let child = root.child(at: index) { stack.append((child, 0)) }
        }

        while let (node, depth) = stack.popLast() {
            if let pageIndex = pageIndex(of: node, in: document) {
                let label = (node.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    let indent = String(repeating: "\u{2007}\u{2007}", count: min(depth, 4))
                    result.append(FixedPageDocumentSection(title: indent + label, startPage: pageIndex))
                }
            }
            for index in stride(from: node.numberOfChildren - 1, through: 0, by: -1) {
                if let child = node.child(at: index) { stack.append((child, depth + 1)) }
            }
        }
        return result
    }

    /// A PDF book's single chapter: every page, in document order.
    static func chapterRef(for info: LocalPDFImportInfo, filename: String, bookTitle: String) -> OnlineChapterRef {
        OnlineChapterRef(
            index: 0,
            title: bookTitle,
            url: filename,
            pdfPageCount: info.pageCount
        )
    }

    static func coverImageData(from url: URL) -> Data? {
        guard let document = try? openDocument(at: url),
              let page = document.page(at: 0),
              let image = PDFPageRasterizer.renderPage(page, targetWidth: 360, scale: 2)
        else { return nil }
        return image.jpegData(compressionQuality: 0.9)
    }

    private static func pageIndex(of outline: PDFOutline, in document: PDFDocument) -> Int? {
        // Most bookmarks carry a destination; some carry an equivalent GoTo action instead.
        let page = outline.destination?.page
            ?? (outline.action as? PDFActionGoTo)?.destination.page
        guard let page else { return nil }
        let index = document.index(for: page)
        return document.pageCount > index && index >= 0 ? index : nil
    }

    private static func string(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ title: String) -> String {
        // A payload shared without any filename is staged under a generated one; a
        // bare UUID is not a title, so let the embedded metadata answer instead.
        guard UUID(uuidString: title) == nil else { return "" }
        return title
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n-,"))
    }
}
