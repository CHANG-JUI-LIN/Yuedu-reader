import Foundation

/// One chapter as a module's site lists it under a record: what `comments.chapters` reads.
struct ModuleCommentChapter: Codable, Hashable, Sendable {
    /// The site's own id of the chapter: the comments request's `{{chapterId}}`.
    var id: String
    var title: String
}

/// A record's chapters on the site, as the module's cache keeps them.
struct RuleModuleCommentChapterPage: Codable, Equatable, Sendable {
    var chapters: [ModuleCommentChapter]
    var fetchedAt: Date
    /// The module version whose rules read it, as `RuleModulePage.version`.
    var version: String?
}

/// One page of a chapter's comments, as the module's cache keeps it.
struct RuleModuleCommentPage: Codable, Equatable, Sendable {
    var comments: [WorkReview]
    /// How many comments the site says there are in all (`total`), nil without the rule.
    var total: Int?
    var fetchedAt: Date
    var version: String?
}

/// Which paragraph of the site's chapter an item is about, as the site said it.
struct ModuleParagraphReference: Codable, Hashable, Sendable {
    /// The paragraph's text, or its first words, folded for comparing; empty without a `quote` rule.
    var quote: String
    /// Its number in the site's chapter, from 1; nil without an `index` rule.
    var index: Int?
    /// The site's id of it, `{{paragraphId}}`: its `id`, else its `index`.
    var id: String
}

/// 段評: a paragraph and how many comments it has.
struct ModuleParagraphCount: Codable, Hashable, Sendable {
    var paragraph: ModuleParagraphReference
    var count: Int
}

/// 熱評: a picked comment and the paragraph it is under.
struct ModuleHotComment: Codable, Hashable, Sendable {
    var paragraph: ModuleParagraphReference
    var comment: WorkReview
}

/// 作者說: the author's note on a chapter.
struct ModuleAuthorSay: Codable, Hashable, Sendable {
    var text: String
    var author: String?
}

/// What a module's site holds about one chapter beside its comments, as the cache keeps it.
struct RuleModuleChapterNotes: Codable, Equatable, Sendable {
    var counts: [ModuleParagraphCount] = []
    /// How many paragraphs the site's chapter has, where `counts` or `hot` says.
    var paragraphCount: Int?
    var hot: [ModuleHotComment] = []
    var authorSay: ModuleAuthorSay?
    var fetchedAt: Date
    var version: String?
}

// 本章說 (format 3.0.2, `comments`): the site's chapters of a record, then one chapter's comments.
// Each is a request of the module's (`perform`): its templates, its script, its hosts.
extension RuleModuleClient {
    static let commentChaptersCacheName = "~commentChapters"
    static let commentsCacheName = "~comments"
    /// Chapters kept per record: past the longest serial's.
    nonisolated static let commentChapterLimit = 20_000

    /// Whether `item` has every record key the block's requests name.
    nonisolated static func canAskComments(of item: RuleListItem, by comments: RuleModule.Comments) -> Bool {
        let requests = [comments.chapters.request, comments.chapter.request] + [
            comments.paragraph?.request, comments.counts?.request, comments.hot?.request, comments.authorSay?.request,
        ].compactMap { $0 }
        let names = Set(requests.flatMap { request in
            RuleModuleValidator.templateNames(in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined())
        })
        func has(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!names.contains("id") || has(item.id)) && (!names.contains("url") || has(item.bookUrl))
    }

    /// The record's chapters as the site lists them, from the cache within the block's
    /// `cacheDuration`. A chapter without an id or a title is left out: it could not be asked
    /// about, or told from another.
    func commentChapters(of item: RuleListItem, by comments: RuleModule.Comments,
                         in module: RuleModule) async throws -> [ModuleCommentChapter] {
        let values = module.withGlobalValues(["id": item.id ?? "", "url": item.bookUrl], language: nil)
        let file = cacheFile(module: module.id, entry: Self.commentChaptersCacheName, values: values)
        let duration = TimeInterval(max(comments.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(RuleModuleCommentChapterPage.self, at: file), cached.version == module.version,
           now().timeIntervalSince(cached.fetchedAt) < duration {
            return cached.chapters
        }
        let started = SourcePerfTrace.now
        let page = try await perform(comments.chapters.request, values: values, ofRecord: true, in: module)
        let scripts = module.scripts, rules = comments.chapters.list
        let chapters = await Self.readCommentChapters(page.text, baseURL: page.baseURL, by: rules, scripts: scripts)
        SourcePerfTrace.record("module.comments.chapters", "module=\(module.id) chapters=\(chapters.count)", since: started, thresholdMs: 0)
        if duration > 0 {
            save(RuleModuleCommentChapterPage(chapters: chapters, fetchedAt: now(), version: module.version), to: file)
        }
        return chapters
    }

    /// Off the caller's actor: a serial's list is thousands of items.
    @concurrent
    nonisolated static func readCommentChapters(_ text: String, baseURL: String, by rules: RuleModule.CommentChapterRules,
                                                scripts: RuleModuleScriptRuntime? = nil) async -> [ModuleCommentChapter] {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        engine.setContent(text, baseUrl: baseURL)
        var chapters: [ModuleCommentChapter] = []
        for element in engine.getElements(ruleStr: rules.items) {
            guard chapters.count < commentChapterLimit else { break }
            engine.setContent(element, baseUrl: baseURL)
            let id = engine.getString(ruleStr: rules.id).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = OPDSClient.plainMetadata(engine.getString(ruleStr: rules.title), limit: 200)
            guard !id.isEmpty, !title.isEmpty else { continue }
            chapters.append(ModuleCommentChapter(id: id, title: title))
        }
        return chapters
    }

    /// One page of a chapter's comments, in the order `sort` names (a `sorts` option's `value`),
    /// and the site's count of them all. `page` counts from 1. With `paragraphID`, that
    /// paragraph's comments (`comments.paragraph`).
    func chapterComments(chapterID: String, paragraphID: String? = nil, of item: RuleListItem, sort: String?, page: Int,
                         by comments: RuleModule.Comments, in module: RuleModule) async throws -> (comments: [WorkReview], total: Int?) {
        guard let block = paragraphID == nil ? comments.chapter : comments.paragraph else { return ([], nil) }
        let values = module.withGlobalValues([
            "id": item.id ?? "", "url": item.bookUrl, "chapterId": chapterID, "paragraphId": paragraphID ?? "",
            "page": String(page), "sort": sort ?? block.sorts?.first?.value ?? "",
        ], language: nil)
        let file = cacheFile(module: module.id, entry: Self.commentsCacheName, values: values)
        let duration = TimeInterval(max(comments.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(RuleModuleCommentPage.self, at: file), cached.version == module.version,
           now().timeIntervalSince(cached.fetchedAt) < duration {
            return (cached.comments, cached.total)
        }
        let started = SourcePerfTrace.now
        let answer = try await perform(block.request, values: values, in: module)
        let scripts = module.scripts
        let read = await Self.readComments(answer.text, baseURL: answer.baseURL, by: block.list, total: block.total, scripts: scripts)
        SourcePerfTrace.record("module.comments.page", "module=\(module.id) page=\(page) comments=\(read.comments.count)",
                               since: started, thresholdMs: 0)
        if duration > 0 {
            save(RuleModuleCommentPage(comments: read.comments, total: read.total, fetchedAt: now(), version: module.version), to: file)
        }
        return read
    }

    /// Off the caller's actor, as a page of reviews is read.
    @concurrent
    nonisolated static func readComments(_ text: String, baseURL: String, by rules: RuleModule.ReviewRules, total: String? = nil,
                                         scripts: RuleModuleScriptRuntime? = nil) async -> (comments: [WorkReview], total: Int?) {
        // A comment has no rating of the book: the rule is not read.
        var rules = rules
        rules.rating = nil
        let engine = RuleModuleScriptRuntime.engine(scripts)
        let found = readList(rules, in: text, baseURL: baseURL, scale: Double(WorkRating.stars), engine: engine)
        engine.setContent(text, baseUrl: baseURL)
        let count = total.flatMap { Self.number(engine.getString(ruleStr: $0)) }
        return (found, count)
    }

    /// A count as a site writes one: `12`, `12条`, `1,204`.
    nonisolated static func number(_ text: String) -> Int? {
        let digits = text.unicodeScalars.filter { ("0"..."9").contains($0) }
        return digits.isEmpty ? nil : Int(String(String.UnicodeScalarView(digits)))
    }

    // MARK: - 段評, 熱評, 作者說

    static let chapterNotesCacheName = "~chapterNotes"
    /// Paragraphs kept per chapter.
    nonisolated static let paragraphLimit = 2_000

    /// The chapter's 段評 counts, 熱評 and 作者說, each asked when the module has its block. One
    /// that fails is left out and said in the log: the others are still the chapter's. Nothing
    /// is retried, and an answer with a part missing is not kept.
    func chapterNotes(chapterID: String, of item: RuleListItem, by comments: RuleModule.Comments,
                      in module: RuleModule) async -> RuleModuleChapterNotes {
        let values = module.withGlobalValues(["id": item.id ?? "", "url": item.bookUrl, "chapterId": chapterID], language: nil)
        let file = cacheFile(module: module.id, entry: Self.chapterNotesCacheName, values: values)
        let duration = TimeInterval(max(comments.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(RuleModuleChapterNotes.self, at: file), cached.version == module.version,
           now().timeIntervalSince(cached.fetchedAt) < duration {
            return cached
        }
        let started = SourcePerfTrace.now
        var notes = RuleModuleChapterNotes(fetchedAt: now(), version: module.version)
        var isWhole = true
        let scripts = module.scripts
        func page(_ request: RuleModule.Request, _ part: String) async -> (text: String, baseURL: String)? {
            do {
                return try await perform(request, values: values, in: module)
            } catch {
                isWhole = false
                AppLogger.network("⟐ module comments: a part of the chapter failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id, "part": part])
                return nil
            }
        }
        if let block = comments.counts, let answer = await page(block.request, "counts") {
            let read = await Self.readCounts(answer.text, baseURL: answer.baseURL, by: block, scripts: scripts)
            notes.counts = read.counts
            notes.paragraphCount = read.paragraphCount
        }
        if let block = comments.hot, let answer = await page(block.request, "hot") {
            let read = await Self.readHot(answer.text, baseURL: answer.baseURL, by: block, scripts: scripts)
            notes.hot = read.hot
            if notes.paragraphCount == nil { notes.paragraphCount = read.paragraphCount }
        }
        if let block = comments.authorSay, let answer = await page(block.request, "authorSay") {
            notes.authorSay = await Self.readAuthorSay(answer.text, baseURL: answer.baseURL, by: block, scripts: scripts)
        }
        SourcePerfTrace.record("module.comments.notes",
                               "module=\(module.id) counts=\(notes.counts.count) hot=\(notes.hot.count) say=\(notes.authorSay != nil)",
                               since: started, thresholdMs: 0)
        if duration > 0, isWhole { save(notes, to: file) }
        return notes
    }

    /// The paragraph an item names, nil when it names none.
    nonisolated private static func paragraph(_ rules: RuleModule.ParagraphRules, engine: ModernRuleEngine) -> ModuleParagraphReference? {
        func value(_ rule: String?) -> String {
            guard let rule, !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
            return engine.getString(ruleStr: rule)
        }
        let quote = ChapterParagraphMatch.fold(OPDSClient.plainMetadata(value(rules.quote), limit: 400))
        let index = Int(value(rules.index).trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
        let id = value(rules.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty || index != nil else { return nil }
        return ModuleParagraphReference(quote: quote, index: index, id: id.isEmpty ? index.map(String.init) ?? "" : id)
    }

    @concurrent
    nonisolated static func readCounts(_ text: String, baseURL: String, by block: RuleModule.ParagraphCounts,
                                       scripts: RuleModuleScriptRuntime? = nil) async -> (counts: [ModuleParagraphCount], paragraphCount: Int?) {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        engine.setContent(text, baseUrl: baseURL)
        let total = block.paragraphCount.flatMap { number(engine.getString(ruleStr: $0)) }
        var counts: [ModuleParagraphCount] = []
        for element in engine.getElements(ruleStr: block.list.items) {
            guard counts.count < paragraphLimit else { break }
            engine.setContent(element, baseUrl: baseURL)
            guard let count = number(engine.getString(ruleStr: block.list.count)), count > 0,
                  let paragraph = paragraph(block.list.paragraph, engine: engine) else { continue }
            counts.append(ModuleParagraphCount(paragraph: paragraph, count: count))
        }
        return (counts, total)
    }

    @concurrent
    nonisolated static func readHot(_ text: String, baseURL: String, by block: RuleModule.HotComments,
                                    scripts: RuleModuleScriptRuntime? = nil) async -> (hot: [ModuleHotComment], paragraphCount: Int?) {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        engine.setContent(text, baseUrl: baseURL)
        let total = block.paragraphCount.flatMap { number(engine.getString(ruleStr: $0)) }
        var hot: [ModuleHotComment] = []
        for element in engine.getElements(ruleStr: block.list.items) {
            guard hot.count < paragraphLimit else { break }
            engine.setContent(element, baseUrl: baseURL)
            let body = plainText(engine.getString(ruleStr: block.list.text), limit: WorkReview.textLimit)
            guard !body.isEmpty, let paragraph = paragraph(block.list.paragraph, engine: engine) else { continue }
            func line(_ rule: String?, limit: Int) -> String? {
                guard let rule, !rule.isEmpty else { return nil }
                let value = OPDSClient.plainMetadata(engine.getString(ruleStr: rule), limit: limit)
                return value.isEmpty ? nil : value
            }
            hot.append(ModuleHotComment(paragraph: paragraph, comment: WorkReview(
                title: nil, text: body, author: line(block.list.author, limit: WorkReview.authorLimit), date: nil, rating: nil,
                likes: line(block.list.likes, limit: 20).flatMap(number).flatMap { $0 > 0 ? $0 : nil })))
        }
        return (hot, total)
    }

    @concurrent
    nonisolated static func readAuthorSay(_ text: String, baseURL: String, by block: RuleModule.AuthorSay,
                                          scripts: RuleModuleScriptRuntime? = nil) async -> ModuleAuthorSay? {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        engine.setContent(text, baseUrl: baseURL)
        let body = plainText(engine.getString(ruleStr: block.text), limit: WorkReview.textLimit)
        guard !body.isEmpty else { return nil }
        let author = block.author.map { OPDSClient.plainMetadata(engine.getString(ruleStr: $0), limit: WorkReview.authorLimit) }
        return ModuleAuthorSay(text: body, author: author.flatMap { $0.isEmpty ? nil : $0 })
    }
}
