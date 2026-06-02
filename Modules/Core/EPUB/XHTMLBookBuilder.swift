import Foundation

enum XHTMLBookBuilder {
    struct XHTMLChapterInput {
        let title: String
        let html: String
        let href: String?
    }

    struct ConvertedBook {
        let title: String
        let chapters: [EPUBChapterRaw]
        let basePath: URL
        let tocEntries: [EPUBTocEntry]
    }

    static func convert(
        xhtmlChapters: [XHTMLChapterInput],
        title: String,
        basePathPrefix: String = "reader_xhtml",
        reuseBasePath: URL? = nil
    ) throws -> ConvertedBook {
        let normalizedInputs = xhtmlChapters.isEmpty
            ? [XHTMLChapterInput(
                title: title,
                html: ReaderHTMLUtilities.normalizedChapterHTML(
                    title: title,
                    paragraphs: ["Loading chapter..."]
                ),
                href: "chapter_0.xhtml"
            )]
            : xhtmlChapters

        let basePath: URL
        if let reuseBasePath {
            basePath = reuseBasePath
        } else {
            basePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(basePathPrefix)_\(UUID().uuidString)")
        }
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)

        var epubChapters: [EPUBChapterRaw] = []
        var tocEntries: [EPUBTocEntry] = []

        for (index, chapter) in normalizedInputs.enumerated() {
            let href = chapter.href ?? "chapter_\(index).xhtml"
            let fileURL = basePath.appendingPathComponent(href)
            try chapter.html.write(to: fileURL, atomically: true, encoding: .utf8)

            epubChapters.append(
                EPUBChapterRaw(
                    href: href,
                    title: chapter.title,
                    html: chapter.html,
                    cssEntries: [],
                    baseURL: basePath
                )
            )
            tocEntries.append(
                EPUBTocEntry(
                    href: href,
                    title: chapter.title,
                    level: 0
                )
            )
        }

        return ConvertedBook(
            title: title,
            chapters: epubChapters,
            basePath: basePath,
            tocEntries: tocEntries
        )
    }

    static func package(
        from converted: ConvertedBook,
        title: String,
        author: String,
        pipelineKind: BookPipelineKind,
        originalSourceURL: URL?
    ) -> BookPackage {
        let parsed = EPUBParsedBook(
            title: title,
            author: author,
            chapters: converted.chapters,
            basePath: converted.basePath,
            coverImageURL: nil,
            tocEntries: converted.tocEntries
        )
        return parsed.makePackage(pipelineKind: pipelineKind, originalSourceURL: originalSourceURL)
    }
}
