import Foundation

/// A chapter of a module's book, as its table of contents lists it.
struct ModuleChapter: Hashable, Sendable {
    var title: String
    /// Absolute; empty for a volume heading.
    var url: String
    var isVolume: Bool { url.isEmpty }
}

/// Reading a module's book (module ecosystem M5, format 3.0 `reading`): its table of contents
/// from the book's page, and a chapter's text through `ChapterFetcher.buildChapterPackage`, the
/// path a 來源配置's chapter takes, so the cache, the normalizer and the reader are one.
/// Every page is a request of the module's (`send`): its hosts, its `rateLimit`.
extension RuleModuleClient {
    /// A list longer than this many pages is cut there: 300 pages of なろう's 100 is 30,000
    /// episodes, past its longest work.
    nonisolated static let maxTOCPages = 300

    /// The book's chapters, page after page of its list. One chapter, the page itself, when the
    /// module's `singleChapter` rule matches it.
    func tableOfContents(bookURL: String, title: String, in module: RuleModule) async throws -> [ModuleChapter] {
        guard let reading = module.reading else { return [] }
        let started = SourcePerfTrace.now
        var chapters: [ModuleChapter] = []
        var address = bookURL
        var visited: Set<String> = []
        var pages = 0
        // Ends at a page with no next one, or one already read.
        while visited.insert(address).inserted {
            guard pages < Self.maxTOCPages else {
                AppLogger.network("module table of contents cut at its page limit", context: ["module": module.id, "book": bookURL])
                break
            }
            let page = try await send(address, headers: reading.headers ?? [:], charset: reading.charset, in: module)
            pages += 1
            if pages == 1, Self.isSingleChapter(page.text, baseURL: page.baseURL, toc: reading.toc) {
                chapters = [ModuleChapter(title: title, url: page.baseURL)]
                break
            }
            let read = Self.chapters(in: page.text, baseURL: page.baseURL, toc: reading.toc)
            chapters += read.chapters
            guard let next = read.next else { break }
            address = next
        }
        SourcePerfTrace.record("module.toc", "module=\(module.id) pages=\(pages) chapters=\(chapters.count)",
                               since: started, thresholdMs: 0)
        return chapters
    }

    nonisolated static func isSingleChapter(_ html: String, baseURL: String, toc: RuleModule.TableOfContents) -> Bool {
        guard let rule = toc.singleChapter, !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !ModernRuleEngine().setContent(html, baseUrl: baseURL).getString(ruleStr: rule)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One page of the list, and the next page's address.
    nonisolated static func chapters(in html: String, baseURL: String,
                                     toc: RuleModule.TableOfContents) -> (chapters: [ModuleChapter], next: String?) {
        let engine = ModernRuleEngine()
        engine.setContent(html, baseUrl: baseURL)
        let next = toc.nextPage.map { engine.getOptionalURL(ruleStr: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        var chapters: [ModuleChapter] = []
        for element in engine.getElements(ruleStr: toc.items) {
            engine.setContent(element, baseUrl: baseURL)
            let title = OPDSClient.plainMetadata(engine.getString(ruleStr: toc.title), limit: 200)
            guard !title.isEmpty else { continue }
            chapters.append(ModuleChapter(title: title, url: engine.getOptionalURL(ruleStr: toc.url)))
        }
        return (chapters, next)
    }

    /// A chapter as the reader caches it: its pages fetched and read by the module's content
    /// rules, then normalized as every online chapter is.
    func chapterPackage(bookId: UUID, chapterIndex: Int, chapter: ModuleChapter,
                        in module: RuleModule) async throws -> ChapterBuildResult {
        guard let reading = module.reading else { throw SourceFailure(kind: .unavailable, underlying: FetchError.invalidURL(chapter.url)) }
        let headers = reading.headers ?? [:]
        let content = reading.content
        let first = try await send(chapter.url, headers: headers, charset: reading.charset, in: module)
        guard let firstURL = URL(string: first.baseURL) else { throw FetchError.invalidURL(first.baseURL) }
        let client = self
        return try await ChapterFetcher.shared.buildChapterPackage(
            bookId: bookId, chapterIndex: chapterIndex, sourceURL: chapter.url, tocTitle: chapter.title,
            initialHTML: first.text, initialURL: firstURL, initialBaseURL: first.baseURL,
            parsePage: { html, baseURL in Self.parse(html, baseURL: baseURL, content: content) },
            extractNextURLs: { html, baseURL in Self.nextPages(html, baseURL: baseURL, content: content) },
            fetchNextPageHTML: { url in
                try await client.send(url.absoluteString, headers: headers, charset: reading.charset, in: module).text
            })
    }

    nonisolated static func parse(_ html: String, baseURL: String, content: RuleModule.Content) -> ChapterParsePayload {
        let engine = ModernRuleEngine()
        engine.setContent(html, baseUrl: baseURL)
        let title = content.title.map { engine.getString(ruleStr: $0) } ?? ""
        return ChapterParsePayload(content: engine.getString(ruleStr: content.text), title: title, sourceMatched: true, isPay: false)
    }

    nonisolated static func nextPages(_ html: String, baseURL: String, content: RuleModule.Content) -> [String] {
        guard let rule = content.nextPage else { return [] }
        let next = ModernRuleEngine().setContent(html, baseUrl: baseURL).getOptionalURL(ruleStr: rule)
        return next.isEmpty ? [] : [next]
    }
}
