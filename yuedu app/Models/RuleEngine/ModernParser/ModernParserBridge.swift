import Foundation

// MARK: - Error

enum ModernParserBridgeError: LocalizedError {
    case invalidURL(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}

// MARK: - Bridge

/// Adapts ModernRuleEngine's API to the interface expected by
/// BookSourceParsingPipeline (parse-only) and BookSourceFetcher (fetch+parse).
///
/// Each instance is bound to a single BookSource.  Create a new bridge
/// when switching sources.
class ModernParserBridge {

    private let engine: ModernRuleEngine
    private let jsEngine: JSCoreEngine
    private let loginManager: LoginManager
    let sourceRuleData: BookSourceRuleData

    // MARK: - Init

    init(source: BookSource) {
        self.sourceRuleData = BookSourceRuleData(source: source)
        self.engine = ModernRuleEngine()
        self.jsEngine = JSCoreEngine()
        self.loginManager = LoginManager.shared

        wireEngine()
    }

    // MARK: - Parsing API (matches BookSourceParsingPipeline signatures)

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource
    ) throws -> [OnlineBook] {
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleSearch.bookList
        guard !listRule.isEmpty else { return [] }

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else { return [] }

        var books: [OnlineBook] = []
        for element in elements {
            engine.setContent(element, baseUrl: baseURL)

            let name = engine.getString(ruleStr: source.ruleSearch.name)
            guard !name.isEmpty else { continue }

            let author = engine.getString(ruleStr: source.ruleSearch.author)
            let bookUrl = engine.getString(ruleStr: source.ruleSearch.bookUrl, isUrl: true)
            let coverUrl = engine.getString(ruleStr: source.ruleSearch.coverUrl, isUrl: true)
            let intro = engine.getString(ruleStr: source.ruleSearch.intro)
            let wordCount = engine.getString(ruleStr: source.ruleSearch.wordCount)
            let lastChapter = engine.getString(ruleStr: source.ruleSearch.lastChapter)
            let kind = engine.getString(ruleStr: source.ruleSearch.kind)

            books.append(OnlineBook(
                name: name,
                author: author,
                intro: intro,
                coverUrl: coverUrl,
                bookUrl: bookUrl,
                tocUrl: bookUrl,
                wordCount: wordCount,
                lastChapter: lastChapter,
                kind: kind,
                sourceId: source.id,
                sourceName: source.bookSourceName
            ))
        }

        engine.setContent(html, baseUrl: baseURL)
        return books
    }

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> OnlineBook {
        loadRuntimeVariables(runtimeVariables)
        engine.setContent(html, baseUrl: baseURL)

        // Execute init script if present (Legado ruleBookInfo.init)
        let initScript = source.ruleBookInfo.initScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !initScript.isEmpty {
            _ = jsEngine.evaluate(initScript, result: html)
        }

        let name = engine.getString(ruleStr: source.ruleBookInfo.name)
        let author = engine.getString(ruleStr: source.ruleBookInfo.author)
        let coverUrl = engine.getString(ruleStr: source.ruleBookInfo.coverUrl, isUrl: true)
        let intro = engine.getString(ruleStr: source.ruleBookInfo.intro)
        let kind = engine.getString(ruleStr: source.ruleBookInfo.kind)
        let wordCount = engine.getString(ruleStr: source.ruleBookInfo.wordCount)
        let lastChapter = engine.getString(ruleStr: source.ruleBookInfo.lastChapter)
        let tocUrlRaw = engine.getString(ruleStr: source.ruleBookInfo.tocUrl, isUrl: true)
        let tocUrl = tocUrlRaw.isEmpty ? bookUrl : tocUrlRaw

        engine.setContent(html, baseUrl: baseURL)

        return OnlineBook(
            name: name.isEmpty ? "未知書名" : name,
            author: author,
            intro: intro,
            coverUrl: coverUrl,
            bookUrl: bookUrl,
            tocUrl: tocUrl,
            wordCount: wordCount,
            lastChapter: lastChapter,
            kind: kind,
            sourceId: source.id,
            sourceName: source.bookSourceName,
            runtimeVariables: dumpRuntimeVariables()
        )
    }

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineChapterRef] {
        loadRuntimeVariables(runtimeVariables)
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleToc.chapterList
        guard !listRule.isEmpty else { return [] }

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else { return [] }

        let formatJs = source.ruleToc.formatJs.trimmingCharacters(in: .whitespacesAndNewlines)

        var chapters: [OnlineChapterRef] = []
        for (index, element) in elements.enumerated() {
            engine.setContent(element, baseUrl: baseURL)

            var title = engine.getString(ruleStr: source.ruleToc.chapterName)
            let url = engine.getString(ruleStr: source.ruleToc.chapterUrl, isUrl: true)
            guard !title.isEmpty || !url.isEmpty else { continue }

            let isVolumeStr = engine.getString(ruleStr: source.ruleToc.isVolume)
            let isVipStr = engine.getString(ruleStr: source.ruleToc.isVip)
            let isPayStr = engine.getString(ruleStr: source.ruleToc.isPay)

            // Apply formatJs if specified (Legado: 章節格式化 JS).
            // Injects `index`, `title`, and `chapter` (full object) into JS context,
            // matching Legado's TocParser.applyFormatJS behaviour.
            if !formatJs.isEmpty {
                let chapterDict: [String: Any] = [
                    "index": index,
                    "title": title,
                    "url": url,
                    "isVolume": Self.parseBool(isVolumeStr),
                    "isVip": Self.parseBool(isVipStr),
                    "isPay": Self.parseBool(isPayStr)
                ]
                if let formatted = jsEngine.evaluate(
                    formatJs,
                    bindings: ["index": index, "title": title, "chapter": chapterDict]
                ), !formatted.isEmpty {
                    title = formatted
                }
            }

            chapters.append(OnlineChapterRef(
                index: index,
                title: title,
                url: url,
                isVolume: Self.parseBool(isVolumeStr),
                isVip: Self.parseBool(isVipStr),
                isPay: Self.parseBool(isPayStr),
                runtimeVariables: dumpRuntimeVariables()
            ))
        }

        engine.setContent(html, baseUrl: baseURL)
        return chapters
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> String {
        let rule = source.ruleToc.nextTocUrl
        guard !rule.isEmpty else { return "" }
        loadRuntimeVariables(runtimeVariables)
        engine.setContent(html, baseUrl: baseURL)
        return engine.getString(ruleStr: rule, isUrl: true)
    }

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> ChapterParsePayload {
        loadRuntimeVariables(runtimeVariables)
        engine.setContent(html, baseUrl: baseURL)

        let content = engine.getString(ruleStr: source.ruleContent.content)
        let title = engine.getString(ruleStr: source.ruleContent.title)

        let sourceRegex = source.ruleContent.sourceRegex
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceMatched = sourceRegex.isEmpty || html.range(of: sourceRegex, options: .regularExpression) != nil

        engine.setContent(html, baseUrl: baseURL)

        return ChapterParsePayload(
            content: content,
            title: title,
            sourceMatched: sourceMatched,
            isPay: false,
            runtimeVariables: dumpRuntimeVariables()
        )
    }

    func extractNextContentURLs(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> [String] {
        let rule = source.ruleContent.nextContentUrl
        guard !rule.isEmpty else { return [] }
        loadRuntimeVariables(runtimeVariables)
        engine.setContent(html, baseUrl: baseURL)
        let list = engine.getStringList(ruleStr: rule, isUrl: true)
        return list.filter { !$0.isEmpty }
    }

    // MARK: - Full pipeline methods (fetch + parse)

    func searchBooks(keyword: String, page: Int = 1) async throws -> [OnlineBook] {
        let source = sourceRuleData.source
        guard !source.searchUrl.isEmpty else { return [] }

        let (body, finalUrl) = try await fetch(
            ruleUrl: source.searchUrl, key: keyword, page: page
        )
        return try parseSearchResults(html: body, baseURL: finalUrl, source: source)
    }

    func getBookInfo(url: String) async throws -> OnlineBook {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        return try parseBookInfo(
            html: body, bookUrl: url, baseURL: finalUrl, source: source
        )
    }

    func getChapterList(url: String) async throws -> [OnlineChapterRef] {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        return try parseTOC(html: body, baseURL: finalUrl, source: source)
    }

    func getContent(url: String) async throws -> String {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        let payload = try parseChapterResult(
            html: body, baseURL: finalUrl, source: source
        )
        return payload.content
    }

    // MARK: - Network fetch using AnalyzeUrl

    func fetch(
        ruleUrl: String, key: String? = nil, page: Int? = nil
    ) async throws -> (String, String) {
        let analyzeUrl = AnalyzeUrl(
            ruleUrl: ruleUrl,
            key: key,
            page: page,
            baseUrl: sourceRuleData.source.bookSourceUrl,
            source: sourceRuleData
        )

        // Wire JS evaluator for URL-level JS
        analyzeUrl.jsEvaluator = { [weak self] jsCode, bindings in
            self?.jsEngine.evaluate(jsCode, bindings: bindings)
        }

        guard var request = analyzeUrl.toURLRequest() else {
            throw ModernParserBridgeError.invalidURL(ruleUrl)
        }

        // Apply source-level headers (don't overwrite per-request ones)
        for (key, value) in sourceRuleData.source.parsedHeaders {
            if request.value(forHTTPHeaderField: key) == nil {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Apply login headers
        loginManager.applyLoginHeaders(
            to: &request, sourceUrl: sourceRuleData.source.bookSourceUrl
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        let encoding = Self.encodingFromCharset(analyzeUrl.charset)
        let body = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .utf8) ?? ""
        let finalUrl = (response as? HTTPURLResponse)?.url?.absoluteString
            ?? analyzeUrl.url

        return (body, finalUrl)
    }

    // MARK: - Private: Engine Wiring

    private func wireEngine() {
        engine.source = sourceRuleData

        // Inject BookSource into JS `source` object and set headers for java.ajax
        jsEngine.bookSource = sourceRuleData.source

        // JS evaluator for ModernRuleEngine
        engine.jsEvaluator = { [weak self] jsCode, previousResult in
            let resultStr = ModernRuleEngine.toString(previousResult)
            return self?.jsEngine.evaluate(jsCode, result: resultStr)
        }

        // JS bridge → variable storage
        jsEngine.getData = { [weak self] key in
            self?.sourceRuleData.getVariable(key: key)
        }
        jsEngine.putData = { [weak self] key, value in
            self?.sourceRuleData.putVariable(key: key, value: value)
        }

        // JS bridge → rule engine getString/getStringList
        jsEngine.getStringHandler = { [weak self] ruleStr in
            self?.engine.getString(ruleStr: ruleStr)
        }
        jsEngine.getStringListHandler = { [weak self] ruleStr in
            self?.engine.getStringList(ruleStr: ruleStr)
        }

        // JS bridge → synchronous network request with charset-aware decoding
        jsEngine.networkHandler = { request in
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data {
                    result = LegadoJSBridge.decodeData(data, response: response)
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 30)
            return result
        }
    }

    // MARK: - Private: Runtime Variable Helpers

    private func loadRuntimeVariables(_ vars: [String: String]?) {
        guard let vars, !vars.isEmpty else { return }
        for (key, value) in vars {
            sourceRuleData.putVariable(key: key, value: value)
        }
    }

    private func dumpRuntimeVariables() -> [String: String]? {
        let map = sourceRuleData.variableMap
        return map.isEmpty ? nil : map
    }

    // MARK: - Private: Helpers

    private static func parseBool(_ str: String) -> Bool {
        let lower = str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "true" || lower == "1" || lower == "yes"
    }

    private static func encodingFromCharset(_ charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased() else { return .utf8 }
        switch charset {
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        default:
            return .utf8
        }
    }
}
