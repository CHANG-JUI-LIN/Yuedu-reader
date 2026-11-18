import Foundation

/// Why a module file is refused. Each case names the field, so the import sheet can say what
/// to fix: a JS segment would otherwise just read nothing, silently, at run time.
enum RuleModuleRejection: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    case notJSON
    case missingField(String)
    case malformed(field: String)
    case invalidID(String)
    case invalidVersion(field: String, value: String)
    case requiresNewerApp(required: String, running: String)
    case noEntries
    case tooManyEntries(Int)
    case duplicateEntryID(String)
    case emptyRule(field: String)
    /// `@js:`, `<js>` or a request's `script` in a module that does not declare `javascript`.
    case javaScript(field: String)
    /// `@get` / `@put`: v1 has no variables.
    case variables(field: String)
    /// A `{{…}}` that names no declared parameter (or `page`, `offset`, `keyword` on search).
    case undeclaredTemplate(field: String, name: String)
    case unknownParamType(field: String, type: String)
    case enumerationWithoutOptions(field: String)
    case unsupportedMethod(field: String, method: String)
    case invalidURL(field: String)
    /// Legado's `url,{…}` option tail (`webView`, `js`, …). A module states its method, body,
    /// headers and charset in their own fields.
    case urlOptions(field: String)
    case hostNotAllowed(field: String, host: String)
    /// A field whose value is one of a fixed set (`contentKind`, `bodyEncoding`).
    case unknownValue(field: String, value: String)
    /// The field first read by `minimum`, in a module whose `requiredVersion` is lower or absent.
    case needsRequiredVersion(field: String, minimum: String)
}

/// Checks a module file at import, before anything is stored. What it lets through runs on a
/// rule engine with no JS evaluator, unless the module declares `javascript`
/// (`RuleModuleScriptRuntime`: scripts that compute and never connect).
enum RuleModuleValidator {
    static let maxBytes = 256 * 1024
    static let maxEntries = 50

    /// The template names paging fills, on every entry.
    private static let pagingNames: Set<String> = ["page", "offset"]

    static func validate(_ data: Data, appVersion: String = RuleModuleVersion.app) throws(RuleModuleRejection) -> RuleModule {
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count) }
        let module = try decode(data)
        try validate(module, appVersion: appVersion)
        return module
    }

    /// Whether the module being checked declares `javascript`: what `checkRule` lets a JS step by.
    @TaskLocal private static var allowsJavaScript = false

    static func validate(_ module: RuleModule, appVersion: String) throws(RuleModuleRejection) {
        let outcome: Result<Void, RuleModuleRejection> = $allowsJavaScript.withValue(module.javascript == true) {
            do throws(RuleModuleRejection) {
                try validateFields(module, appVersion: appVersion)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try outcome.get()
    }

    private static func validateFields(_ module: RuleModule, appVersion: String) throws(RuleModuleRejection) {
        guard isFileSafe(module.id) else { throw .invalidID(module.id) }
        try requireText(module.title, "title")
        guard RuleModuleVersion(module.version) != nil else { throw .invalidVersion(field: "version", value: module.version) }
        if let required = module.requiredVersion {
            guard let needed = RuleModuleVersion(required) else { throw .invalidVersion(field: "requiredVersion", value: required) }
            if let running = RuleModuleVersion(appVersion), running < needed {
                throw .requiresNewerApp(required: required, running: appVersion)
            }
        }
        guard !module.modules.isEmpty || module.search != nil || module.lookup != nil else { throw .noEntries }
        guard module.modules.count <= maxEntries else { throw .tooManyEntries(module.modules.count) }

        let hosts = RuleModuleHosts(module.hosts)
        // The first field a 3.0 app is needed for, and the first a 3.0.1 app is.
        var format3: String?
        var format301: String?
        var format302: String?
        func uses302(_ field: String) { if format302 == nil { format302 = field } }
        if let icon = module.icon {
            uses302("icon")
            // A picture is a request too: an address on the module's own hosts, nothing to fill.
            guard templateNames(in: icon).isEmpty else { throw .undeclaredTemplate(field: "icon", name: templateNames(in: icon)[0]) }
            try checkHost(icon, field: "icon", hosts: RuleModuleHosts(module.hosts))
        }
        let globals = module.globalParams ?? []
        if module.globalParams != nil { uses302("globalParams") }
        try validateGlobals(globals, entries: [module.search, module.lookup, module.genre].compactMap { $0 } + module.modules)
        let globalNames = Set(globals.map(\.name))
        if let attribution = module.attribution {
            format3 = "attribution"
            try requireText(attribution.text, "attribution.text")
            if let url = attribution.url {
                let lowered = url.trimmingCharacters(in: .whitespaces).lowercased()
                guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"), safeURL(string: url) != nil else {
                    throw .invalidURL(field: "attribution.url")
                }
            }
        }
        if let localizations = module.localizations {
            if format3 == nil { format3 = "localizations" }
            let entries = Dictionary(module.modules.compactMap { entry in entry.id.map { ($0, entry) } },
                                     uniquingKeysWith: { first, _ in first })
            for (language, text) in localizations {
                guard Self.isLanguageTag(language) else { throw .unknownValue(field: "localizations", value: language) }
                for (id, words) in text.entries ?? [:] {
                    guard let entry = entries[id] else { throw .unknownValue(field: "localizations.\(language).entries", value: id) }
                    // Each parameter it names is the list's, and each option one of that parameter's.
                    for (name, said) in words.params ?? [:] {
                        let field = "localizations.\(language).entries.\(id).params"
                        guard let param = entry.params.first(where: { $0.name == name }) else {
                            throw .unknownValue(field: field, value: name)
                        }
                        let values = Set((param.enumOptions ?? []).map(\.value))
                        for value in (said.options ?? [:]).keys where !values.contains(value) {
                            throw .unknownValue(field: "\(field).\(name).options", value: value)
                        }
                    }
                }
            }
        }
        // A `*.` entry is a domain redirects may follow into: two labels or more, and only as `*.`.
        for host in module.hosts where RuleModuleHosts.isWildcard(host) {
            guard RuleModuleHosts.wildcardDomain(host) != nil else { throw .unknownValue(field: "hosts", value: host) }
            if format3 == nil { format3 = "hosts" }
        }
        var seen: Set<String> = []
        for (index, entry) in module.modules.enumerated() {
            let path = "modules[\(index)]"
            guard let id = entry.id, !id.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingField("\(path).id") }
            guard isFileSafe(id) else { throw .invalidID(id) }
            guard seen.insert(id).inserted else { throw .duplicateEntryID(id) }
            try requireText(entry.title ?? "", "\(path).title")
            try validate(entry, path: path, hosts: hosts, isSearch: false, globals: globalNames, format3: &format3,
                         format301: &format301, format302: &format302)
        }
        try validateShelfLists(module)
        if let search = module.search {
            try validate(search, path: "search", hosts: hosts, isSearch: true, globals: globalNames, format3: &format3,
                         format301: &format301, format302: &format302)
        }
        if let reading = module.reading {
            if format3 == nil { format3 = "reading" }
            try validate(reading)
        }
        if let lookup = module.lookup {
            if format3 == nil { format3 = "lookup" }
            try validate(lookup, path: "lookup", hosts: hosts, isSearch: false, isLookup: true, globals: globalNames,
                         format3: &format3, format301: &format301, format302: &format302)
        }
        let records = [module.search, module.lookup].compactMap { $0 }
        if let detail = module.detail {
            uses302("detail")
            // The book's own address: some list must read one, and the page is that book's alone.
            let listsURL = ([module.search].compactMap { $0 } + module.modules)
                .contains { !($0.list.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let request = detail.request
            guard templateNames(in: request.url + (request.body ?? "")).contains("url") else {
                throw .missingField("detail.request.url {{url}}")
            }
            try validate(detail, of: "", hosts: hosts, isRecord: true, globals: globalNames, hasURLRule: listsURL)
        }
        if let related = module.related {
            uses302("related")
            try validate(related.request, path: "related", keyNames: ["id", "url"], records: records, hosts: hosts,
                         globals: globalNames)
            try validateListRules(related.list, path: "related.list")
        }
        if let genre = module.genre {
            uses302("genre")
            guard genre.detail == nil else { throw .unknownValue(field: "genre.detail", value: "detail") }
            guard templateNames(in: genre.request.url + (genre.request.body ?? "")).contains("tag") else {
                throw .missingField("genre.request.url {{tag}}")
            }
            try validate(genre, path: "genre", hosts: hosts, isSearch: false, globals: globalNames.union(["tag"]),
                         format3: &format3, format301: &format301, format302: &format302)
        }
        if let reviews = module.reviews {
            if format301 == nil { format301 = "reviews" }
            try validate(reviews, records: [module.search, module.lookup].compactMap { $0 }, hosts: hosts, globals: globalNames)
        }
        if module.javascript != nil { uses302("javascript") }
        if let comments = module.comments {
            uses302("comments")
            try validate(comments, records: records, hosts: hosts, globals: globalNames)
        }
        // A request's `script` is JavaScript: the module's to declare, and never blank.
        for (path, request) in requests(of: module) {
            guard let script = request.script else { continue }
            uses302("\(path).request.script")
            guard module.javascript == true else { throw .javaScript(field: "\(path).request.script") }
            try requireText(script, "\(path).request.script")
        }

        // The newest format it uses is the one it must ask for.
        if let field = format302 {
            let declared = module.requiredVersion.flatMap(RuleModuleVersion.init)
            guard let declared, let minimum = RuleModuleVersion(RuleModuleFormat.version3_0_2), declared >= minimum else {
                throw .needsRequiredVersion(field: field, minimum: RuleModuleFormat.version3_0_2)
            }
        }
        if let field = format301 {
            let declared = module.requiredVersion.flatMap(RuleModuleVersion.init)
            guard let declared, let minimum = RuleModuleVersion(RuleModuleFormat.version3_0_1), declared >= minimum else {
                throw .needsRequiredVersion(field: field, minimum: RuleModuleFormat.version3_0_1)
            }
        }
        if let field = format3 {
            let declared = module.requiredVersion.flatMap(RuleModuleVersion.init)
            guard let declared, let minimum = RuleModuleVersion(RuleModuleFormat.version3), declared >= minimum else {
                throw .needsRequiredVersion(field: field, minimum: RuleModuleFormat.version3)
            }
        }
    }

    /// Every request the module has, by the path of what holds it.
    private static func requests(of module: RuleModule) -> [(String, RuleModule.Request)] {
        var found: [(String, RuleModule.Request)] = []
        func add(_ entry: RuleModule.Entry?, _ path: String) {
            guard let entry else { return }
            found.append((path, entry.request))
            if let detail = entry.detail { found.append(("\(path).detail", detail.request)) }
        }
        for (index, entry) in module.modules.enumerated() { add(entry, "modules[\(index)]") }
        add(module.search, "search")
        add(module.lookup, "lookup")
        add(module.genre, "genre")
        if let detail = module.detail { found.append(("detail", detail.request)) }
        if let related = module.related { found.append(("related", related.request)) }
        if let reviews = module.reviews { found.append(("reviews", reviews.request)) }
        if let comments = module.comments {
            found.append(("comments.chapters", comments.chapters.request))
            found.append(("comments.chapter", comments.chapter.request))
            if let paragraph = comments.paragraph { found.append(("comments.paragraph", paragraph.request)) }
            if let counts = comments.counts { found.append(("comments.counts", counts.request)) }
            if let hot = comments.hot { found.append(("comments.hot", hot.request)) }
            if let say = comments.authorSay { found.append(("comments.authorSay", say.request)) }
            if let replies = comments.replies { found.append(("comments.replies", replies.request)) }
        }
        return found
    }

    /// 本章說: the site's chapters of a record `search` or `lookup` found, then one chapter's
    /// comments by the id the chapter list gave it.
    private static func validate(_ comments: RuleModule.Comments, records: [RuleModule.Entry],
                                 hosts: RuleModuleHosts, globals: Set<String>) throws(RuleModuleRejection) {
        try validate(comments.chapters.request, path: "comments.chapters", keyNames: ["id", "url"], records: records,
                     hosts: hosts, globals: globals)
        let chapters = comments.chapters.list
        try requireText(chapters.items, "comments.chapters.list.items")
        try requireText(chapters.id, "comments.chapters.list.id")
        try requireText(chapters.title, "comments.chapters.list.title")
        for (name, rule) in [("items", chapters.items), ("id", chapters.id), ("title", chapters.title)] {
            try checkRule(rule, field: "comments.chapters.list.\(name)", declared: [], innerRules: true)
        }

        try validate(comments.chapter, path: "comments.chapter", hosts: hosts, globals: globals)
        if let paragraph = comments.paragraph {
            try validate(paragraph, path: "comments.paragraph", hosts: hosts, globals: globals, ofParagraph: true)
        }
        if let replies = comments.replies {
            // A comment's replies are asked by its id: a list must read one.
            func has(_ rule: String?) -> Bool { !(rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard has(comments.chapter.list.id) || has(comments.paragraph?.list.id) else {
                throw .missingField("comments.chapter.list.id")
            }
            try validateChapterRequest(replies.request, path: "comments.replies", hosts: hosts, globals: globals,
                                       extra: ["page", "paragraphId", "commentId"], requiresChapter: false)
            guard templates(of: replies.request).contains("commentId") else {
                throw .missingField("comments.replies.request.url {{commentId}}")
            }
            try validate(replies.list, path: "comments.replies.list")
            if let total = replies.total { try checkRule(total, field: "comments.replies.total", declared: [], innerRules: true) }
        }
        for (index, page) in (comments.sourcePages ?? []).enumerated() {
            try validate(page, path: "comments.sourcePages[\(index)]")
        }
        if let counts = comments.counts {
            // A bubble opens its paragraph's comments.
            guard comments.paragraph != nil else { throw .missingField("comments.paragraph") }
            try validateChapterRequest(counts.request, path: "comments.counts", hosts: hosts, globals: globals)
            try requireText(counts.list.items, "comments.counts.list.items")
            try requireText(counts.list.count, "comments.counts.list.count")
            try validate(counts.list.paragraph, count: counts.paragraphCount, path: "comments.counts")
            for case let (name, rule?) in [("list.items", counts.list.items), ("list.count", counts.list.count),
                                           ("list.hot", counts.list.hot), ("list.voice", counts.list.voice),
                                           ("paragraphCount", counts.paragraphCount)] as [(String, String?)] {
                try checkRule(rule, field: "comments.counts.\(name)", declared: [], innerRules: true)
            }
        }
        if let hot = comments.hot {
            try validateChapterRequest(hot.request, path: "comments.hot", hosts: hosts, globals: globals)
            try requireText(hot.list.items, "comments.hot.list.items")
            try requireText(hot.list.text, "comments.hot.list.text")
            try validate(hot.list.paragraph, count: hot.paragraphCount, path: "comments.hot")
            for case let (name, rule?) in [("list.items", hot.list.items), ("list.text", hot.list.text), ("list.author", hot.list.author),
                                           ("list.likes", hot.list.likes), ("paragraphCount", hot.paragraphCount)] as [(String, String?)] {
                try checkRule(rule, field: "comments.hot.\(name)", declared: [], innerRules: true)
            }
        }
        if let say = comments.authorSay {
            try validateChapterRequest(say.request, path: "comments.authorSay", hosts: hosts, globals: globals)
            guard !say.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .emptyRule(field: "comments.authorSay.text")
            }
            for case let (name, rule?) in [("text", say.text), ("author", say.author)] as [(String, String?)] {
                try checkRule(rule, field: "comments.authorSay.\(name)", declared: [], innerRules: true)
            }
        }
    }

    /// How an item names its paragraph: by its text, or by its number with the site's count of
    /// the chapter's paragraphs beside it. A number alone is refused: nothing would tell that
    /// the reader's chapter is cut as the site's is.
    private static func validate(_ rules: RuleModule.ParagraphRules, count: String?, path: String) throws(RuleModuleRejection) {
        func has(_ rule: String?) -> Bool { !(rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard has(rules.quote) || has(rules.index) else { throw .missingField("\(path).list.quote") }
        if !has(rules.quote), !has(count) { throw .missingField("\(path).paragraphCount") }
        for case let (name, rule?) in [("quote", rules.quote), ("index", rules.index), ("id", rules.id), ("title", rules.title)]
            as [(String, String?)] {
            try checkRule(rule, field: "\(path).list.\(name)", declared: [], innerRules: true)
        }
    }

    /// A request about one chapter: `{{chapterId}}` it must name (unless `requiresChapter` is
    /// off: a comment's replies are told by the comment's id), the record's keys, and with
    /// `extra` whatever else its block fills. On the module's hosts.
    private static func validateChapterRequest(_ request: RuleModule.Request, path: String, hosts: RuleModuleHosts,
                                               globals: Set<String>, extra: Set<String> = [],
                                               requiresChapter: Bool = true) throws(RuleModuleRejection) {
        let method = (request.method ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw .unsupportedMethod(field: "\(path).request.method", method: request.method ?? "")
        }
        let declared = globals.union(["id", "url", "chapterId"]).union(extra)
        try requireText(request.url, "\(path).request.url")
        try checkRule(request.url, field: "\(path).request.url", declared: declared)
        if let body = request.body { try checkRule(body, field: "\(path).request.body", declared: declared) }
        if let encoding = request.bodyEncoding, RuleModule.BodyEncoding(rawValue: encoding) == nil {
            throw .unknownValue(field: "\(path).request.bodyEncoding", value: encoding)
        }
        for (name, value) in (request.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "\(path).request.headers.\(name)", declared: declared)
        }
        if hasOptionTail(request.url) { throw .urlOptions(field: "\(path).request.url") }
        // Which chapter: without it the page would be the same for every chapter.
        guard !requiresChapter || templates(of: request).contains("chapterId") else {
            throw .missingField("\(path).request.url {{chapterId}}")
        }
        try checkHost(request.url, field: "\(path).request.url", hosts: hosts)
    }

    private static func templates(of request: RuleModule.Request) -> Set<String> {
        Set(templateNames(in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
    }

    /// A list of comments: a chapter's, or with `ofParagraph` one paragraph's (`{{paragraphId}}`).
    private static func validate(_ block: RuleModule.ChapterComments, path: String, hosts: RuleModuleHosts,
                                 globals: Set<String>, ofParagraph: Bool = false) throws(RuleModuleRejection) {
        try validateChapterRequest(block.request, path: path, hosts: hosts, globals: globals,
                                   extra: ofParagraph ? ["page", "sort", "paragraphId"] : ["page", "sort"])
        let templates = templates(of: block.request)
        if ofParagraph, !templates.contains("paragraphId") { throw .missingField("\(path).request.url {{paragraphId}}") }
        if let sorts = block.sorts {
            guard !sorts.isEmpty, templates.contains("sort") else { throw .missingField("\(path).request.url {{sort}}") }
            for (index, sort) in sorts.enumerated() { try requireText(sort.title, "\(path).sorts[\(index)].title") }
        } else if templates.contains("sort") {
            throw .missingField("\(path).sorts")
        }
        let list = block.list
        try requireText(list.items, "\(path).list.items")
        try requireText(list.text, "\(path).list.text")
        let rules: [(String, String?)] = [
            ("list.items", list.items), ("list.text", list.text), ("list.title", list.title), ("list.author", list.author),
            ("list.date", list.date), ("list.likes", list.likes), ("list.id", list.id), ("list.avatar", list.avatar),
            ("list.badge", list.badge), ("list.floor", list.floor), ("list.replyCount", list.replyCount), ("list.quote", list.quote),
            ("list.meta", list.meta), ("list.images", list.images), ("list.voice", list.voice), ("list.isAuthor", list.isAuthor),
            ("total", block.total),
        ]
        for case let (name, rule?) in rules {
            try checkRule(rule, field: "\(path).\(name)", declared: [], innerRules: true)
        }
        if let replies = list.replies { try validate(replies, path: "\(path).list.replies") }
    }

    /// The replies under a comment, or on a page of their own.
    private static func validate(_ rules: RuleModule.ReplyRules, path: String) throws(RuleModuleRejection) {
        try requireText(rules.items, "\(path).items")
        try requireText(rules.text, "\(path).text")
        let named: [(String, String?)] = [
            ("items", rules.items), ("text", rules.text), ("author", rules.author), ("date", rules.date),
            ("likes", rules.likes), ("id", rules.id), ("avatar", rules.avatar), ("badge", rules.badge), ("floor", rules.floor),
            ("meta", rules.meta), ("images", rules.images), ("voice", rules.voice), ("isAuthor", rules.isAuthor),
        ]
        for case let (name, rule?) in named {
            try checkRule(rule, field: "\(path).\(name)", declared: [], innerRules: true)
        }
    }

    /// A 來源配置's comment page: hosts written out or as `*.`, a path that is a regular
    /// expression, and the parts that are `id`, `chapterId` and `paragraphId`, the chapter's
    /// among them. No other part of the address can become a value.
    private static func validate(_ page: RuleModule.SourcePage, path: String) throws(RuleModuleRejection) {
        guard !page.hosts.isEmpty else { throw .missingField("\(path).hosts") }
        for host in page.hosts {
            let entry = host.trimmingCharacters(in: .whitespaces).lowercased()
            let isWritten = !entry.isEmpty && !RuleModuleHosts.isWildcard(entry)
                && entry.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            guard isWritten || RuleModuleHosts.wildcardDomain(entry) != nil else {
                throw .unknownValue(field: "\(path).hosts", value: host)
            }
        }
        var names = Set<String>()
        if let pattern = page.path {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw .unknownValue(field: "\(path).path", value: pattern) }
            for group in ModuleCommentSourcePages.groupNames(in: pattern) {
                guard ModuleCommentSourcePages.valueNames.contains(group) else {
                    throw .unknownValue(field: "\(path).path", value: group)
                }
                names.insert(group)
            }
        }
        for (name, parameter) in (page.query ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard ModuleCommentSourcePages.valueNames.contains(name) else { throw .unknownValue(field: "\(path).query", value: name) }
            try requireText(parameter, "\(path).query.\(name)")
            names.insert(name)
        }
        // Which chapter: without it every chapter's bubble would open the same comments.
        guard names.contains("chapterId") else { throw .missingField("\(path).query.chapterId") }
    }

    // MARK: - Entries

    private static func validate(_ entry: RuleModule.Entry, path: String, hosts: RuleModuleHosts,
                                 isSearch: Bool, isLookup: Bool = false, globals: Set<String>, format3: inout String?,
                                 format301: inout String?, format302: inout String?) throws(RuleModuleRejection) {
        func uses3(_ field: String) { if format3 == nil { format3 = field } }
        if let prefixes = entry.isbnPrefixes {
            uses3("\(path).isbnPrefixes")
            // Only a lookup is asked by ISBN.
            guard isLookup else { throw .unknownValue(field: "\(path).isbnPrefixes", value: prefixes.joined(separator: ",")) }
            for prefix in prefixes where prefix.isEmpty || prefix.count > 13 || !prefix.allSatisfy({ $0.isASCII && $0.isNumber }) {
                throw .unknownValue(field: "\(path).isbnPrefixes", value: prefix)
            }
        }
        if let length = entry.minKeywordLength {
            uses3("\(path).minKeywordLength")
            // Only a search is sent a keyword.
            guard isSearch, length >= 1 else { throw .unknownValue(field: "\(path).minKeywordLength", value: String(length)) }
        }
        if let authors = entry.searchesAuthors {
            if format301 == nil { format301 = "\(path).searchesAuthors" }
            // Only a search is sent a keyword.
            guard isSearch else { throw .unknownValue(field: "\(path).searchesAuthors", value: String(authors)) }
        }
        if isLookup {
            // The ISBN is what is asked, and the record's own ISBN is how it is known to be the copy's.
            let request = entry.request
            guard (request.url + (request.body ?? "")).contains("{{isbn}}") else { throw .missingField("\(path).request.url {{isbn}}") }
            try requireText(entry.list.isbn ?? "", "\(path).list.isbn")
        }
        if let kind = entry.contentKind {
            uses3("\(path).contentKind")
            guard [ContentKind.text, .comic].map(\.rawValue).contains(kind) else {
                throw .unknownValue(field: "\(path).contentKind", value: kind)
            }
        }
        if entry.excludeTags != nil { uses3("\(path).excludeTags") }
        if let store = entry.store {
            if format302 == nil { format302 = "\(path).store" }
            try validateStore(store, of: entry, path: path)
        }

        var declared = pagingNames.union(globals)
        if isSearch { declared.insert("keyword") }
        if isLookup { declared.insert("isbn") }
        try validateScope(entry.params, path: "\(path).params", format302: &format302)
        for (index, param) in entry.params.enumerated() {
            let field = "\(path).params[\(index)]"
            try requireText(param.name, "\(field).name")
            guard let kind = param.kind else { throw .unknownParamType(field: "\(field).type", type: param.type) }
            if kind == .enumeration, param.enumOptions?.isEmpty ?? true {
                throw .enumerationWithoutOptions(field: "\(field).enumOptions")
            }
            if let follows = param.followsLanguage {
                uses3("\(field).followsLanguage")
                // Only a choice has an option in a language to follow.
                guard kind == .enumeration else { throw .unknownValue(field: "\(field).followsLanguage", value: String(follows)) }
            }
            for (option, index) in zip(param.enumOptions ?? [], 0...) {
                guard let language = option.language else { continue }
                uses3("\(field).enumOptions[\(index)].language")
                guard isLanguageTag(language) else { throw .unknownValue(field: "\(field).enumOptions[\(index)].language", value: language) }
            }
            if kind == .page || kind == .offset, let start = param.value {
                // Where the first page starts; an older app starts at 1 or 0 whatever it says.
                uses3("\(field).value")
                guard let number = Int(start), number >= 0 else { throw .unknownValue(field: "\(field).value", value: start) }
            }
            declared.insert(param.name)
        }

        let request = entry.request
        let method = (request.method ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw .unsupportedMethod(field: "\(path).request.method", method: request.method ?? "")
        }
        try requireText(request.url, "\(path).request.url")
        try checkRule(request.url, field: "\(path).request.url", declared: declared)
        if let body = request.body { try checkRule(body, field: "\(path).request.body", declared: declared) }
        if let encoding = request.bodyEncoding {
            uses3("\(path).request.bodyEncoding")
            guard RuleModule.BodyEncoding(rawValue: encoding) != nil else {
                throw .unknownValue(field: "\(path).request.bodyEncoding", value: encoding)
            }
        }
        for (name, value) in (request.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "\(path).request.headers.\(name)", declared: declared)
        }
        if hasOptionTail(request.url) { throw .urlOptions(field: "\(path).request.url") }
        try checkHost(request.url, field: "\(path).request.url", hosts: hosts)

        let list = entry.list
        try requireText(list.items, "\(path).list.items")
        try requireText(list.title, "\(path).list.title")
        let rules: [(String, String?)] = [
            ("items", list.items), ("title", list.title), ("author", list.author), ("cover", list.cover),
            ("intro", list.intro), ("url", list.url), ("kind", list.kind), ("language", list.language),
        ]
        let format3Rules: [(String, String?)] = [
            ("aliases", list.aliases), ("tags", list.tags), ("publisher", list.publisher), ("isbn", list.isbn),
            ("series", list.series), ("seriesCovers", list.seriesCovers), ("contentKind", list.contentKind),
        ]
        if let id = list.id {
            if format301 == nil { format301 = "\(path).list.id" }
            try checkRule(id, field: "\(path).list.id", declared: [], innerRules: true)
        }
        if let volumes = list.volumes {
            if format301 == nil { format301 = "\(path).list.volumes" }
            try checkRule(volumes, field: "\(path).list.volumes", declared: [], innerRules: true)
        }
        for case let (name, rule?) in rules + format3Rules {
            // A list rule fills no parameters. Its `{{…}}` may only hold a rule, which the engine
            // reads in place (`{{$.id}}`, Legado's own); anything else would go to the JS evaluator.
            try checkRule(rule, field: "\(path).list.\(name)", declared: [], innerRules: true)
        }
        for case let (name, _?) in format3Rules { uses3("\(path).list.\(name)") }

        if let detail = entry.detail {
            uses3("\(path).detail")
            try validate(detail, of: path, hosts: hosts, isRecord: isSearch || isLookup, globals: globals,
                         hasURLRule: !(entry.list.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// A list's store (`Entry.store`): only a home list has one, each section a layout of books
    /// with values its own parameters take.
    private static func validateStore(_ store: [RuleModule.StoreSection], of entry: RuleModule.Entry,
                                      path: String) throws(RuleModuleRejection) {
        let field = "\(path).store"
        guard path.hasPrefix("modules["), !store.isEmpty, store.count <= maxStoreSections else {
            throw .unknownValue(field: field, value: String(store.count))
        }
        for (index, section) in store.enumerated() {
            let layout = HomeSectionLayout(rawValue: section.layout)
            if let shelves = section.shelves {
                // Shelves are lists: the layout that draws them, and no values of the section's own.
                guard layout == .groupedShelves, section.params == nil else {
                    throw .unknownValue(field: "\(field)[\(index)].layout", value: section.layout)
                }
                guard !shelves.isEmpty, shelves.count <= maxStoreShelves else {
                    throw .unknownValue(field: "\(field)[\(index)].shelves", value: String(shelves.count))
                }
                for (shelfIndex, shelf) in shelves.enumerated() {
                    let shelfField = "\(field)[\(index)].shelves[\(shelfIndex)]"
                    // Another list's values are checked once every list is known (`validateShelfLists`).
                    if shelf.list == nil { try validateStoreParams(shelf.params, of: entry, field: "\(shelfField).params") }
                    if let belongTo = shelf.belongTo {
                        guard let param = entry.params.first(where: { $0.name == belongTo.paramName }), param.kind == .enumeration,
                              !belongTo.value.isEmpty,
                              belongTo.value.allSatisfy({ value in (param.enumOptions ?? []).contains { $0.value == value } }) else {
                            throw .unknownValue(field: "\(shelfField).belongTo", value: belongTo.paramName)
                        }
                    }
                }
                continue
            }
            guard layout.isKnown, !layout.style.drawsLists, ![.tiles, .readingCard, .compactReadingCard].contains(layout) else {
                throw .unknownValue(field: "\(field)[\(index)].layout", value: section.layout)
            }
            try validateStoreParams(section.params, of: entry, field: "\(field)[\(index)].params")
        }
    }

    /// Values a store section or shelf sets: each a parameter of the list, an option it has.
    private static func validateStoreParams(_ params: [String: String]?, of entry: RuleModule.Entry,
                                            field: String) throws(RuleModuleRejection) {
        for (name, value) in (params ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let param = entry.params.first(where: { $0.name == name }) else {
                throw .unknownValue(field: field, value: name)
            }
            if param.kind == .enumeration, !(param.enumOptions ?? []).contains(where: { $0.value == value }) {
                throw .unknownValue(field: "\(field).\(name)", value: value)
            }
        }
    }

    /// A shelf of another list (`StoreShelf.list`): one of the module's lists, with its values.
    private static func validateShelfLists(_ module: RuleModule) throws(RuleModuleRejection) {
        let entries = Dictionary(module.modules.compactMap { entry in entry.id.map { ($0, entry) } },
                                 uniquingKeysWith: { first, _ in first })
        for (index, entry) in module.modules.enumerated() {
            for (sectionIndex, section) in (entry.store ?? []).enumerated() {
                for (shelfIndex, shelf) in (section.shelves ?? []).enumerated() {
                    guard let id = shelf.list else { continue }
                    let field = "modules[\(index)].store[\(sectionIndex)].shelves[\(shelfIndex)]"
                    guard let other = entries[id] else { throw .unknownValue(field: "\(field).list", value: id) }
                    try validateStoreParams(shelf.params, of: other, field: "\(field).params")
                }
            }
        }
    }

    /// The most sections a list's store has.
    static let maxStoreSections = 12
    /// The most shelves a store's section has, every region's together.
    static let maxStoreShelves = 40

    /// A record's own page: only a search's or a lookup's records are asked for one (a home
    /// list's rows never are), and it gives a description or tags.
    private static func validate(_ detail: RuleModule.Detail, of entryPath: String, hosts: RuleModuleHosts,
                                 isRecord: Bool, globals: Set<String>, hasURLRule: Bool) throws(RuleModuleRejection) {
        let path = entryPath.isEmpty ? "detail" : "\(entryPath).detail"
        guard isRecord else { throw .unknownValue(field: path, value: "detail") }
        let request = detail.request
        let method = (request.method ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw .unsupportedMethod(field: "\(path).request.method", method: request.method ?? "")
        }
        let declared = globals.union(["url"])
        try requireText(request.url, "\(path).request.url")
        try checkRule(request.url, field: "\(path).request.url", declared: declared)
        if let body = request.body { try checkRule(body, field: "\(path).request.body", declared: declared) }
        if let encoding = request.bodyEncoding, RuleModule.BodyEncoding(rawValue: encoding) == nil {
            throw .unknownValue(field: "\(path).request.bodyEncoding", value: encoding)
        }
        for (name, value) in (request.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "\(path).request.headers.\(name)", declared: declared)
        }
        if hasOptionTail(request.url) { throw .urlOptions(field: "\(path).request.url") }
        // `{{url}}` with no url rule would be the list page's own address.
        let templates = templateNames(in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined())
        if templates.contains("url"), !hasURLRule { throw .missingField(entryPath.isEmpty ? "modules.list.url" : "\(entryPath).list.url") }
        // `{{url}}…` is the record's own address, read from the module's hosts; `send` refuses it
        // when it names another. Any other address is checked here.
        if !request.url.trimmingCharacters(in: .whitespaces).hasPrefix("{{url}}") {
            try checkHost(request.url, field: "\(path).request.url", hosts: hosts)
        }
        let rules = [("intro", detail.intro), ("tags", detail.tags)]
        guard rules.contains(where: { !($0.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw .missingField("\(path).intro")
        }
        for case let (name, rule?) in rules {
            try checkRule(rule, field: "\(path).\(name)", declared: [], innerRules: true)
        }
    }

    /// A record's reviews: asked of a record `search` or `lookup` found, by the keys its request
    /// names, so one of them must read every such key; each review has a text.
    private static func validate(_ reviews: RuleModule.Reviews, records: [RuleModule.Entry],
                                 hosts: RuleModuleHosts, globals: Set<String>) throws(RuleModuleRejection) {
        let path = "reviews"
        let request = reviews.request
        let method = (request.method ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw .unsupportedMethod(field: "\(path).request.method", method: request.method ?? "")
        }
        let keyNames: Set<String> = ["id", "url"]
        let declared = globals.union(keyNames)
        try requireText(request.url, "\(path).request.url")
        try checkRule(request.url, field: "\(path).request.url", declared: declared)
        if let body = request.body { try checkRule(body, field: "\(path).request.body", declared: declared) }
        if let encoding = request.bodyEncoding, RuleModule.BodyEncoding(rawValue: encoding) == nil {
            throw .unknownValue(field: "\(path).request.bodyEncoding", value: encoding)
        }
        for (name, value) in (request.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "\(path).request.headers.\(name)", declared: declared)
        }
        if hasOptionTail(request.url) { throw .urlOptions(field: "\(path).request.url") }
        // Which record: without a key the page would be the same for every book.
        let keys = Set(templateNames(in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
            .intersection(keyNames)
        guard !keys.isEmpty else { throw .missingField("\(path).request.url {{id}}") }
        guard !records.isEmpty else { throw .missingField("search") }
        func reads(_ entry: RuleModule.Entry, _ key: String) -> Bool {
            let rule = key == "id" ? entry.list.id : entry.list.url
            return !(rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard records.contains(where: { entry in keys.allSatisfy { reads(entry, $0) } }) else {
            throw .missingField("search.list.\(keys.sorted().first ?? "id")")
        }
        // `{{url}}…` is the record's own address; `send` refuses it when it names another host.
        if !request.url.trimmingCharacters(in: .whitespaces).hasPrefix("{{url}}") {
            try checkHost(request.url, field: "\(path).request.url", hosts: hosts)
        }
        if let scale = reviews.ratingScale, !(scale > 0) {
            throw .unknownValue(field: "\(path).ratingScale", value: String(scale))
        }
        let list = reviews.list
        try requireText(list.items, "\(path).list.items")
        try requireText(list.text, "\(path).list.text")
        let rules: [(String, String?)] = [
            ("list.items", list.items), ("list.text", list.text), ("list.title", list.title), ("list.author", list.author),
            ("list.date", list.date), ("list.rating", list.rating), ("list.likes", list.likes),
            ("list.id", list.id), ("list.avatar", list.avatar), ("list.badge", list.badge), ("list.floor", list.floor),
            ("list.replyCount", list.replyCount), ("list.quote", list.quote), ("list.meta", list.meta),
            ("list.images", list.images), ("list.voice", list.voice), ("list.isAuthor", list.isAuthor),
            ("rating.score", reviews.rating?.score), ("rating.count", reviews.rating?.count),
            ("rating.distribution", reviews.rating?.distribution),
        ]
        if let rating = reviews.rating { try requireText(rating.score, "\(path).rating.score") }
        for case let (name, rule?) in rules {
            try checkRule(rule, field: "\(path).\(name)", declared: [], innerRules: true)
        }
        if let replies = list.replies { try validate(replies, path: "\(path).list.replies") }
    }

    /// A request asked of a record `search` or `lookup` found (`related`; `reviews` has its own
    /// copy of these checks): it names the record by `keyNames`, which one of those lists reads.
    private static func validate(_ request: RuleModule.Request, path: String, keyNames: Set<String>,
                                 records: [RuleModule.Entry], hosts: RuleModuleHosts,
                                 globals: Set<String>) throws(RuleModuleRejection) {
        let method = (request.method ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw .unsupportedMethod(field: "\(path).request.method", method: request.method ?? "")
        }
        let declared = globals.union(keyNames)
        try requireText(request.url, "\(path).request.url")
        try checkRule(request.url, field: "\(path).request.url", declared: declared)
        if let body = request.body { try checkRule(body, field: "\(path).request.body", declared: declared) }
        if let encoding = request.bodyEncoding, RuleModule.BodyEncoding(rawValue: encoding) == nil {
            throw .unknownValue(field: "\(path).request.bodyEncoding", value: encoding)
        }
        for (name, value) in (request.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "\(path).request.headers.\(name)", declared: declared)
        }
        if hasOptionTail(request.url) { throw .urlOptions(field: "\(path).request.url") }
        let keys = Set(templateNames(in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
            .intersection(keyNames)
        guard !keys.isEmpty else { throw .missingField("\(path).request.url {{id}}") }
        guard !records.isEmpty else { throw .missingField("search") }
        func reads(_ entry: RuleModule.Entry, _ key: String) -> Bool {
            let rule = key == "id" ? entry.list.id : entry.list.url
            return !(rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard records.contains(where: { entry in keys.allSatisfy { reads(entry, $0) } }) else {
            throw .missingField("search.list.\(keys.sorted().first ?? "id")")
        }
        if !request.url.trimmingCharacters(in: .whitespaces).hasPrefix("{{url}}") {
            try checkHost(request.url, field: "\(path).request.url", hosts: hosts)
        }
    }

    /// A list's rules read outside an entry (`related.list`): an item and its title, each a rule
    /// with no parameter in it.
    private static func validateListRules(_ list: RuleModule.ListRules, path: String) throws(RuleModuleRejection) {
        try requireText(list.items, "\(path).items")
        try requireText(list.title, "\(path).title")
        let rules: [(String, String?)] = [
            ("items", list.items), ("title", list.title), ("author", list.author), ("cover", list.cover),
            ("intro", list.intro), ("url", list.url), ("kind", list.kind), ("language", list.language),
            ("aliases", list.aliases), ("tags", list.tags), ("publisher", list.publisher), ("isbn", list.isbn),
            ("series", list.series), ("seriesCovers", list.seriesCovers), ("contentKind", list.contentKind),
            ("id", list.id), ("volumes", list.volumes),
        ]
        for case let (name, rule?) in rules {
            try checkRule(rule, field: "\(path).\(name)", declared: [], innerRules: true)
        }
    }

    // MARK: - Global parameters, belongTo, placeholders (format 3.0.2)

    /// The template names every request fills itself: no global may take one.
    static let reservedNames: Set<String> = ["page", "offset", "keyword", "isbn", "id", "url", "tag"]

    /// The module's own settings: a value the reader sets once (`input`, `count`, `enumeration`)
    /// or a `constant`, named apart from every list's parameters and the names requests fill.
    /// One that follows 中繼資料語言偏好推薦 has no language to follow outside a home section.
    private static func validateGlobals(_ globals: [RuleModule.Param],
                                        entries: [RuleModule.Entry]) throws(RuleModuleRejection) {
        var unused: String?
        try validateScope(globals, path: "globalParams", format302: &unused)
        let listNames = Set(entries.flatMap { $0.params.map(\.name) })
        var seen: Set<String> = []
        for (index, param) in globals.enumerated() {
            let field = "globalParams[\(index)]"
            try requireText(param.name, "\(field).name")
            guard let kind = param.kind else { throw .unknownParamType(field: "\(field).type", type: param.type) }
            guard [.input, .count, .enumeration, .constant].contains(kind) else {
                throw .unknownParamType(field: "\(field).type", type: param.type)
            }
            if kind == .enumeration, param.enumOptions?.isEmpty ?? true {
                throw .enumerationWithoutOptions(field: "\(field).enumOptions")
            }
            if let follows = param.followsLanguage { throw .unknownValue(field: "\(field).followsLanguage", value: String(follows)) }
            guard !reservedNames.contains(param.name), !listNames.contains(param.name), seen.insert(param.name).inserted else {
                throw .unknownValue(field: "\(field).name", value: param.name)
            }
        }
    }

    /// One set of parameters (a list's, or `globalParams`): each `belongTo`, a parameter's or an
    /// option's, names another of them and no chain of them leads back to where it started; the
    /// option a parameter defaults to is always offered, so an option `belongTo` is never on
    /// it, nor on a parameter that follows 中繼資料語言偏好推薦; `placeholders` only on an `input`.
    private static func validateScope(_ params: [RuleModule.Param], path: String,
                                      format302: inout String?) throws(RuleModuleRejection) {
        let byName = Dictionary(params.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        /// The parameters whose values decide whether this one, or one of its options, is shown.
        func targets(of param: RuleModule.Param) -> [String] {
            ([param.belongTo] + (param.enumOptions ?? []).map(\.belongTo)).compactMap { $0?.paramName }
        }
        func check(_ belongTo: RuleModule.BelongTo, of param: RuleModule.Param, field: String) throws(RuleModuleRejection) {
            if format302 == nil { format302 = field }
            guard belongTo.paramName != param.name, byName[belongTo.paramName] != nil, !belongTo.value.isEmpty else {
                throw .unknownValue(field: field, value: belongTo.paramName)
            }
            var visited: Set<String> = [param.name]
            var pending = [belongTo.paramName]
            while let name = pending.popLast() {
                guard name != param.name else { throw .unknownValue(field: field, value: belongTo.paramName) }
                guard visited.insert(name).inserted, let target = byName[name] else { continue }
                pending += targets(of: target)
            }
        }
        for (index, param) in params.enumerated() {
            let field = "\(path)[\(index)]"
            if let belongTo = param.belongTo {
                try check(belongTo, of: param, field: "\(field).belongTo")
            }
            let fallback = param.currentValue(in: [:], language: nil)
            for (offset, option) in (param.enumOptions ?? []).enumerated() {
                guard let belongTo = option.belongTo else { continue }
                let optionField = "\(field).enumOptions[\(offset)].belongTo"
                guard param.followsLanguage != true, option.value != fallback else {
                    throw .unknownValue(field: optionField, value: option.value)
                }
                try check(belongTo, of: param, field: optionField)
            }
            if let placeholders = param.placeholders {
                if format302 == nil { format302 = "\(field).placeholders" }
                guard param.kind == .input else { throw .unknownValue(field: "\(field).placeholders", value: param.type) }
                for (offset, placeholder) in placeholders.enumerated() {
                    try requireText(placeholder.title, "\(field).placeholders[\(offset)].title")
                }
            }
        }
    }

    // MARK: - Rules and templates

    /// No JS unless the module declares `javascript`, no variables, and every `{{…}}` declared,
    /// or with `innerRules` a rule (`SourceRule.looksLikeRule`) that passes the same checks.
    private static func checkRule(_ rule: String, field: String, declared: Set<String>,
                                  innerRules: Bool = false) throws(RuleModuleRejection) {
        // The engine's own split decides what is JS, so the validator and the engine never disagree.
        if !allowsJavaScript, ModernRuleEngine().splitSourceRule(rule).contains(where: { $0.mode == .js }) {
            throw .javaScript(field: field)
        }
        let lowered = rule.lowercased()
        if lowered.contains("@get:") || lowered.contains("@put:") { throw .variables(field: field) }
        for name in templateNames(in: rule) where !declared.contains(name) {
            guard innerRules, SourceRule.looksLikeRule(name) else { throw .undeclaredTemplate(field: field, name: name) }
            try checkRule(name, field: field, declared: [])
        }
    }

    /// The text inside each `{{…}}`, trimmed.
    static func templateNames(in text: String) -> [String] {
        let ns = text as NSString
        return SourceRule.evalPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let token = ns.substring(with: match.range)
            guard token.hasPrefix("{{") else { return nil }
            return String(token.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Legado splits a request on `,` before `{` (`AnalyzeUrl.paramPattern`) once its templates
    /// are filled, so a template right after a comma is no option tail.
    private static func hasOptionTail(_ url: String) -> Bool {
        let filled = SourceRule.evalPattern.stringByReplacingMatches(
            in: url, range: NSRange(location: 0, length: (url as NSString).length), withTemplate: "0")
        return filled.range(of: #",\s*\{"#, options: .regularExpression) != nil
    }

    private static func checkHost(_ url: String, field: String, hosts: RuleModuleHosts) throws(RuleModuleRejection) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { throw .invalidURL(field: field) }
        let afterScheme = trimmed[trimmed.range(of: "://")!.upperBound...]
        let authority = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // A host built from a parameter could point anywhere.
        guard !authority.contains("{{") else { throw .hostNotAllowed(field: field, host: String(authority)) }
        guard let host = URLComponents(string: "http://\(authority)")?.host?.lowercased(), !host.isEmpty else {
            throw .invalidURL(field: field)
        }
        guard hosts.allowsRequest(to: host) else { throw .hostNotAllowed(field: field, host: host) }
    }

    // MARK: - Helpers

    private static func decode(_ data: Data) throws(RuleModuleRejection) -> RuleModule {
        do {
            return try JSONDecoder().decode(RuleModule.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw .missingField(path(context.codingPath + [key]))
        } catch let DecodingError.typeMismatch(_, context) {
            throw .malformed(field: path(context.codingPath))
        } catch let DecodingError.valueNotFound(_, context) {
            throw .missingField(path(context.codingPath))
        } catch let DecodingError.dataCorrupted(context) where !context.codingPath.isEmpty {
            throw .malformed(field: path(context.codingPath))
        } catch {
            throw .notJSON
        }
    }

    /// `modules[0].list.title`.
    private static func path(_ keys: [any CodingKey]) -> String {
        keys.reduce(into: "") { result, key in
            if let index = key.intValue { result += "[\(index)]" } else { result += result.isEmpty ? key.stringValue : ".\(key.stringValue)" }
        }
    }

    // MARK: - Reading

    private static func validate(_ reading: RuleModule.Reading) throws(RuleModuleRejection) {
        for (name, value) in (reading.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkRule(value, field: "reading.headers.\(name)", declared: [])
        }
        let toc = reading.toc
        try requireText(toc.items, "reading.toc.items")
        try requireText(toc.title, "reading.toc.title")
        try requireText(toc.url, "reading.toc.url")
        try requireText(reading.content.text, "reading.content.text")
        let rules: [(String, String?)] = [
            ("toc.items", toc.items), ("toc.title", toc.title), ("toc.url", toc.url), ("toc.nextPage", toc.nextPage),
            ("toc.singleChapter", toc.singleChapter), ("content.text", reading.content.text),
            ("content.title", reading.content.title), ("content.nextPage", reading.content.nextPage),
        ]
        for case let (name, rule?) in rules {
            try checkRule(rule, field: "reading.\(name)", declared: [], innerRules: true)
        }
    }

    /// `en`, `zh-Hant`, `pt-BR`: a language code, then script or region subtags.
    private static func isLanguageTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return false
        }
        return parts.dropFirst().allSatisfy { (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    private static func requireText(_ text: String, _ field: String) throws(RuleModuleRejection) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw field.contains(".list.") ? .emptyRule(field: field) : .missingField(field)
        }
    }

    static func isFileSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != ".", id != ".." else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }
}
