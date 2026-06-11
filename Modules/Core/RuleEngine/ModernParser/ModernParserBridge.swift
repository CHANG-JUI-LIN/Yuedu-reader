import Foundation
import CryptoKit

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

    private let jsEngine: JSCoreEngine
    private let loginManager: LoginManager
    private let runtimeStateStore: BookSourceRuntimeStateStore
    let sourceRuleData: BookSourceRuleData

    /// When set, every `ModernRuleEngine` created by `makeEngine()` will have this
    /// observer attached, emitting pipeline events for diff-driven debugging against
    /// Legado's Android logs.  Set by `BookSourceDebugEngine`.
    var debugObserver: ((RuleDebugEvent) -> Void)?

    // MARK: - Init

    init(source: BookSource) {
        self.sourceRuleData = BookSourceRuleData(source: source)
        self.jsEngine = JSCoreEngine()
        self.loginManager = LoginManager.shared
        self.runtimeStateStore = BookSourceRuntimeStateStore.shared

        wireJSEngine()
    }

    // MARK: - Engine Factory

    /// Creates a fresh, fully-wired ModernRuleEngine for a single parse operation.
    /// A new instance per call prevents state bleed when async operations overlap.
    private func makeEngine() -> ModernRuleEngine {
        let e = ModernRuleEngine()
        e.source = sourceRuleData
        e.debugObserver = debugObserver

        // Capture `e` weakly so the closure doesn't extend its lifetime past the parse call.
        e.jsEvaluator = { [weak self, weak e] jsCode, prevResult in
            guard let self, let engine = e else { return nil }
            // Point JS back-references at THIS engine instance before evaluating.
            // Safe because jsEngine serialises all evaluations on its dedicated queue.
            self.jsEngine.getStringHandler = { ruleStr in engine.getString(ruleStr: ruleStr) }
            self.jsEngine.getStringListHandler = { ruleStr in engine.getStringList(ruleStr: ruleStr) }
            return self.jsEngine.evaluateIsolated(
                jsCode,
                result: prevResult,
                bindings: [
                    "baseUrl": engine.baseUrl,
                    "baseURL": engine.baseUrl
                ]
            )
        }
        return e
    }

    // MARK: - Wire JS-only state (source headers, variable storage, network)

    private func wireJSEngine() {
        jsEngine.bookSource = sourceRuleData.source

        jsEngine.errorHandler = { [weak self] msg, script in
            self?.debugObserver?(.jsExecuted(
                segmentIndex: -1, script: String(script.prefix(200)),
                inputPreview: "", result: "ERROR: \(msg)"
            ))
            #if DEBUG
            print("[ModernParserBridge] JS error: \(msg)")
            #endif
        }

        jsEngine.getData = { [weak self] key in
            self?.sourceRuleData.getVariable(key: key)
        }
        jsEngine.putData = { [weak self] key, value in
            self?.sourceRuleData.putVariable(key: key, value: value)
        }

        // ── Source Bridge Wiring ──

        let sourceUrl = sourceRuleData.source.bookSourceUrl

        jsEngine.sourceBridge.getVariableHandler = { [weak self] in
            guard let self else { return "" }
            return self.runtimeStateStore.sourceVariableJSON(for: sourceUrl) ?? ""
        }
        jsEngine.sourceBridge.setVariableHandler = { [weak self] jsonString in
            self?.runtimeStateStore.setSourceVariableJSON(jsonString, for: sourceUrl)
        }

        jsEngine.sourceBridge.getLoginInfoHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl).flatMap { info in
                if let data = try? JSONSerialization.data(withJSONObject: info),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return nil
            }
        }
        jsEngine.sourceBridge.putLoginInfoHandler = { info in
            guard let data = info.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceUrl, info: dict)
        }
        jsEngine.sourceBridge.getLoginInfoMapHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
        }
        jsEngine.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        jsEngine.sourceBridge.putLoginHeaderHandler = { header in
            guard let data = header.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            LoginManager.shared.storeLoginHeaders(sourceUrl: sourceUrl, headers: dict)
        }
        jsEngine.sourceBridge.getLoginHeaderHandler = {
            LoginManager.shared.getLoginHeader(sourceUrl: sourceUrl)
        }
        jsEngine.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        jsEngine.sourceBridge.getHeaderMapHandler = { [weak self] in
            var merged = self?.jsEngine.parseHeaders(self?.sourceRuleData.source.header ?? "") ?? [:]
            if let loginHeaders = LoginManager.shared.getLoginHeaderMap(sourceUrl: sourceUrl) {
                merged.merge(loginHeaders) { _, new in new }
            }
            return merged
        }
        jsEngine.sourceBridge.evalJSHandler = { [weak self] js in
            self?.jsEngine.evaluate(js) ?? ""
        }

        // ── AnalyzeUrl handler for java.ajax() ──
        jsEngine.analyzeUrlHandler = { [weak self] urlStr in
            guard let self else { return nil }
            let analyzeUrl = AnalyzeUrl(
                ruleUrl: urlStr,
                baseUrl: self.sourceRuleData.source.bookSourceUrl,
                source: self.sourceRuleData,
                jsEvaluator: { [weak self] jsCode, bindings in
                    self?.jsEngine.evaluateIsolated(jsCode, bindings: bindings)
                }
            )
            if analyzeUrl.isDataUri {
                return Self.bodyForDataURI(analyzeUrl)
            }
            guard var request = analyzeUrl.toURLRequest() else { return nil }
            for (key, value) in self.sourceRuleData.source.parsedHeaders {
                if request.value(forHTTPHeaderField: key) == nil {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            LoginManager.shared.applyLoginHeaders(to: &request, sourceUrl: sourceUrl)
            let sem = DispatchSemaphore(value: 0)
            var result: String?
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data {
                    let encoding = Self.encodingFromCharset(analyzeUrl.charset)
                    result = String(data: data, encoding: encoding)
                        ?? String(data: data, encoding: .utf8)
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 30)
            return result
        }

        // Evaluate jsLib if present, cache the hash to avoid re-evaluation
        evaluateJsLibIfNeeded()

        // setContent handler: JS calls java.setContent(html) → create engine, set content, wire back-refs
        jsEngine.setContentHandler = { [weak self] content, baseUrl in
            guard let self else { return }
            let engine = ModernRuleEngine()
            engine.source = self.sourceRuleData
            engine.jsEvaluator = { [weak engine] jsCode, prevResult in
                guard engine != nil else { return nil }
                return self.jsEngine.evaluate(
                    jsCode,
                    result: prevResult,
                    bindings: [
                        "baseUrl": baseUrl ?? "",
                        "baseURL": baseUrl ?? ""
                    ]
                )
            }
            engine.setContent(content, baseUrl: baseUrl ?? "")
            self.jsEngine.getStringHandler = { ruleStr in engine.getString(ruleStr: ruleStr) }
            self.jsEngine.getStringListHandler = { ruleStr in engine.getStringList(ruleStr: ruleStr) }
            self.jsEngine.getElementsHandler = { ruleStr in engine.getElements(ruleStr: ruleStr) }
            self.jsEngine.getStringWithContentHandler = { ruleStr, content in
                engine.setContent(content, baseUrl: baseUrl ?? "")
                return engine.getString(ruleStr: ruleStr)
            }
        }

        // networkHandler runs on the jsEngine serial queue thread — blocking via
        // semaphore here is intentional and safe (dedicated thread, not the global pool).
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

    // MARK: - Parsing API (matches BookSourceParsingPipeline signatures)

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource
    ) throws -> [OnlineBook] {
        let engine = makeEngine()
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
        setBookContext(runtimeVariables: runtimeVariables)
        jsEngine.setChapterBridge(LegadoChapterBridge())
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        // Execute init script if present (Legado ruleBookInfo.init)
        let initScript = source.ruleBookInfo.initScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !initScript.isEmpty {
            if initScript.hasPrefix(":") {
                // AllInOne Regex: matches groups become the effective content for subsequent rules
                let pattern = String(initScript.dropFirst())
                if !pattern.isEmpty,
                   let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let nsHTML = html as NSString
                    var groups: [String] = []
                    for i in 0..<match.numberOfRanges {
                        let r = match.range(at: i)
                        groups.append(r.location != NSNotFound ? nsHTML.substring(with: r) : "")
                    }
                    engine.setContent(groups, baseUrl: baseURL)
                }
            } else {
                // Legado init can itself be a full rule chain, e.g.
                // `<js>...</js>$.data`; run it through ModernRuleEngine.
                let initResult = engine.getString(ruleStr: initScript)
                if let jsonData = initResult.data(using: .utf8),
                   let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    engine.setContent(jsonObj, baseUrl: baseURL)
                } else if !initResult.isEmpty {
                    engine.setContent(initResult, baseUrl: baseURL)
                } else if let jsonText = jsEngine.evaluate(initScript, result: html),
                   let jsonData = jsonText.data(using: .utf8),
                   let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    engine.setContent(jsonObj, baseUrl: baseURL)
                } else {
                    _ = jsEngine.evaluate(initScript, result: html)
                }
            }
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

        return OnlineBook(
            name: name.isEmpty ? "Unknown Title" : name,
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
        setBookContext(runtimeVariables: runtimeVariables)
        jsEngine.setChapterBridge(LegadoChapterBridge())
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleToc.chapterList
        guard !listRule.isEmpty else { return [] }

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else { return [] }

        let formatJs = source.ruleToc.formatJs.trimmingCharacters(in: .whitespacesAndNewlines)

        var chapters: [OnlineChapterRef] = []
        chapters.reserveCapacity(elements.count)
        // Drain autorelease pool every 200 elements to prevent OOM from SwiftSoup DOM accumulation
        let batchSize = 200
        for batchStart in stride(from: 0, to: elements.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, elements.count)
            autoreleasepool {
                for index in batchStart..<batchEnd {
                    let element = elements[index]
                    engine.setContent(element, baseUrl: baseURL)

                    var title = ReaderHTMLUtilities.displayText(
                        fromHTMLFragment: engine.getString(ruleStr: source.ruleToc.chapterName)
                    )
                    let url = engine.getString(ruleStr: source.ruleToc.chapterUrl, isUrl: true)
                    guard !title.isEmpty || !url.isEmpty else { continue }

                    let isVolumeStr = engine.getString(ruleStr: source.ruleToc.isVolume)
                    let isVipStr = engine.getString(ruleStr: source.ruleToc.isVip)
                    let isPayStr = engine.getString(ruleStr: source.ruleToc.isPay)

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
                            title = ReaderHTMLUtilities.displayText(fromHTMLFragment: formatted)
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
            }
        }

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
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)
        return engine.getString(ruleStr: rule, isUrl: true)
    }

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        chapterRef: OnlineChapterRef? = nil
    ) throws -> ChapterParsePayload {
        loadRuntimeVariables(runtimeVariables)
        setBookContext(runtimeVariables: runtimeVariables)
        if let chapterRef {
            jsEngine.setChapterBridge(
                LegadoChapterBridge(
                    index: chapterRef.index,
                    title: chapterRef.title,
                    order: chapterRef.index,
                    url: chapterRef.url
                )
            )
        } else {
            jsEngine.setChapterBridge(LegadoChapterBridge())
        }
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let content = engine.getString(ruleStr: source.ruleContent.content)
        let title = engine.getString(ruleStr: source.ruleContent.title)

        let sourceRegex = source.ruleContent.sourceRegex
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceMatched = sourceRegex.isEmpty || html.range(of: sourceRegex, options: .regularExpression) != nil

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
        let engine = makeEngine()
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

    // MARK: - Explore / Discover

    /// Discover item returned from exploreUrl JS evaluation.
    ///
    /// Decoding is intentionally lenient: aggregator sources (e.g. 光遇聚合) emit
    /// `style` values as numbers/bools (`layout_flexBasisPercent: 0.45`), which a
    /// strict `[String: String]` decode would reject — failing the *entire* array.
    struct DiscoverItem: Decodable {
        var title: String?
        var url: String?
        var style: [String: String]?
        var type: String?
        var action: String?
        var chars: [String]?
        var `default`: String?
        var viewName: String?

        enum CodingKeys: String, CodingKey {
            case title, url, style, type, action, chars, `default`, viewName
        }

        init(
            title: String? = nil,
            url: String? = nil,
            style: [String: String]? = nil,
            type: String? = nil,
            action: String? = nil,
            chars: [String]? = nil,
            default defaultValue: String? = nil,
            viewName: String? = nil
        ) {
            self.title = title
            self.url = url
            self.style = style
            self.type = type
            self.action = action
            self.chars = chars
            self.default = defaultValue
            self.viewName = viewName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            action = try? c.decodeIfPresent(String.self, forKey: .action)
            `default` = try? c.decodeIfPresent(String.self, forKey: .default)
            viewName = try? c.decodeIfPresent(String.self, forKey: .viewName)
            chars = try? c.decodeIfPresent([String].self, forKey: .chars)
            if let raw = try? c.decodeIfPresent([String: LenientScalar].self, forKey: .style) {
                style = raw.mapValues(\.stringValue)
            } else {
                style = nil
            }
        }

        /// Decodes a JSON scalar (string / number / bool) into a string.
        private struct LenientScalar: Decodable {
            let stringValue: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { stringValue = s }
                else if let i = try? c.decode(Int.self) { stringValue = String(i) }
                else if let d = try? c.decode(Double.self) { stringValue = String(d) }
                else if let b = try? c.decode(Bool.self) { stringValue = String(b) }
                else { stringValue = "" }
            }
        }
    }

    /// Evaluate exploreUrl for a book source and return discover items.
    /// Mirrors Legado's exploreKinds(): JS may produce a rule string, JSON is
    /// decoded directly, and plain text is split into title::url kinds.
    func getExploreItems(page: Int = 1) async -> [DiscoverItem] {
        ensureCloudSettingsIfNeeded()
        let source = sourceRuleData.source
        let rawExploreUrl = source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawExploreUrl.isEmpty else { return [] }

        var ruleStr = rawExploreUrl
        if Self.isJSExploreRule(rawExploreUrl) {
            let jsCode = Self.jsCode(fromExploreRule: rawExploreUrl)
            let bindings: [String: Any] = [
                "page": page,
                "baseUrl": source.bookSourceUrl,
            ]
            ruleStr = jsEngine.evaluateIsolated(jsCode, bindings: bindings)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        guard !ruleStr.isEmpty else { return [] }
        if Self.isJsonArrayOrObject(ruleStr) {
            return parseDiscoverJSON(ruleStr)
        }
        return parseExploreKindText(ruleStr)
    }

    /// Parse a JSON array string into DiscoverItem list.
    private func parseDiscoverJSON(_ json: String) -> [DiscoverItem] {
        guard let data = json.data(using: .utf8) else { return [] }
        if let items = try? JSONDecoder().decode([DiscoverItem].self, from: data) {
            return items
        }
        if let single = try? JSONDecoder().decode(DiscoverItem.self, from: data) {
            return [single]
        }
        return []
    }

    private func parseExploreKindText(_ text: String) -> [DiscoverItem] {
        let normalized = text.replacingOccurrences(
            of: #"(&&|\r?\n)+"#,
            with: "\n",
            options: .regularExpression
        )
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawEntry in
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty else { return nil }

                guard let separator = entry.range(of: "::") else {
                    return DiscoverItem(title: entry, url: nil)
                }

                let title = entry[..<separator.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let url = entry[separator.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return DiscoverItem(title: title, url: url.isEmpty ? nil : url)
            }
    }

    private static func isJSExploreRule(_ value: String) -> Bool {
        value.hasPrefix("<js>") || value.hasPrefix("@js:")
    }

    private static func jsCode(fromExploreRule value: String) -> String {
        if value.hasPrefix("@js:") {
            return String(value.dropFirst(4))
        }
        if value.hasPrefix("<js>"), value.hasSuffix("</js>") {
            return String(value.dropFirst(4).dropLast(5))
        }
        return value
    }

    private static func isJsonArrayOrObject(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
    }

    /// Parse explore results using ruleExplore rules (for non-JS exploreUrl).
    func parseExploreResults(html: String, baseURL: String, source: BookSource) -> [OnlineBook] {
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleExplore.bookList
        guard !listRule.isEmpty else {
            // If no ruleExplore, try to parse the HTML as JSON discover items
            let items = parseDiscoverJSON(html)
            return items.compactMap { item in
                guard let title = item.title, !title.isEmpty else { return nil }
                return OnlineBook(
                    name: title, author: "", intro: "",
                    coverUrl: "", bookUrl: item.url ?? "",
                    tocUrl: item.url ?? "", wordCount: "",
                    lastChapter: "", kind: "",
                    sourceId: source.id, sourceName: source.bookSourceName
                )
            }
        }

        let elements = engine.getElements(ruleStr: listRule)
        var books: [OnlineBook] = []
        for element in elements {
            engine.setContent(element, baseUrl: baseURL)
            let name = engine.getString(ruleStr: source.ruleExplore.name)
            guard !name.isEmpty else { continue }
            let author = engine.getString(ruleStr: source.ruleExplore.author)
            let bookUrl = engine.getString(ruleStr: source.ruleExplore.bookUrl, isUrl: true)
            let coverUrl = engine.getString(ruleStr: source.ruleExplore.coverUrl, isUrl: true)
            let intro = engine.getString(ruleStr: source.ruleExplore.intro)
            let wordCount = engine.getString(ruleStr: source.ruleExplore.wordCount)
            let lastChapter = engine.getString(ruleStr: source.ruleExplore.lastChapter)
            let kind = engine.getString(ruleStr: source.ruleExplore.kind)
            books.append(OnlineBook(
                name: name, author: author, intro: intro,
                coverUrl: coverUrl, bookUrl: bookUrl,
                tocUrl: bookUrl, wordCount: wordCount,
                lastChapter: lastChapter, kind: kind,
                sourceId: source.id, sourceName: source.bookSourceName
            ))
        }
        return books
    }

    // MARK: - Network fetch using AnalyzeUrl

    func checkLoginRequired(
        html: String,
        baseURL: String
    ) -> Bool {
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let js = sourceRuleData.source.loginCheckJs
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !js.isEmpty else { return false }

        let result = engine.getString(ruleStr: js)
        let lower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "true" || lower == "1" || lower == "yes"
    }

    func fetch(
        ruleUrl: String, key: String? = nil, page: Int? = nil
    ) async throws -> (String, String) {
        ensureCloudSettingsIfNeeded()
        let analyzeUrl = AnalyzeUrl(
            ruleUrl: ruleUrl,
            key: key,
            page: page,
            baseUrl: sourceRuleData.source.bookSourceUrl,
            source: sourceRuleData,
            jsEvaluator: { [weak self] jsCode, bindings in
                self?.jsEngine.evaluateIsolated(jsCode, bindings: bindings)
            }
        )

        if analyzeUrl.isDataUri {
            return (Self.bodyForDataURI(analyzeUrl), analyzeUrl.url)
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

    // MARK: - Private: Runtime Variable Helpers

    private func loadRuntimeVariables(_ vars: [String: String]?) {
        guard let vars, !vars.isEmpty else { return }
        for (key, value) in vars {
            sourceRuleData.putVariable(key: key, value: value)
        }
    }

    private func dumpRuntimeVariables() -> [String: String]? {
        var map = sourceRuleData.variableMap
        map.merge(jsEngine.bookBridge.runtimeStateVariables()) { _, new in new }
        for (key, value) in jsEngine.bookBridge.runtimeVariables() where !value.isEmpty {
            map["book.variable.\(key)"] = value
        }
        return map.isEmpty ? nil : map
    }

    private func ensureCloudSettingsIfNeeded() {
        guard sourceMayUseCloudSettings else { return }
        evaluateJsLibIfNeeded()
        guard !sourceVariableHasCloudConfig() else { return }

        _ = jsEngine.evaluate(
            """
            cache.delete('gyksconfig');
            if (typeof getCloudSettings === 'function') {
                getCloudSettings(true);
            }
            """,
            bindings: [
                "baseUrl": sourceRuleData.source.bookSourceUrl,
                "baseURL": sourceRuleData.source.bookSourceUrl
            ]
        )
    }

    private var sourceMayUseCloudSettings: Bool {
        [
            sourceRuleData.source.jsLib,
            sourceRuleData.source.exploreUrl,
            sourceRuleData.source.searchUrl
        ].contains { script in
            script.contains("云端配置")
                || script.contains("getCloudSettings")
                || script.contains("gyksconfig")
        }
    }

    private func sourceVariableHasCloudConfig() -> Bool {
        guard let json = runtimeStateStore.sourceVariableJSON(for: sourceRuleData.source.bookSourceUrl),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cloudConfig = object["云端配置"]
        else { return false }

        switch cloudConfig {
        case let dict as [String: Any]:
            return !dict.isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case is NSNull:
            return false
        default:
            return true
        }
    }

    private func setBookContext(runtimeVariables: [String: String]?) {
        var bookVariables: [String: String] = [:]
        runtimeVariables?.forEach { key, value in
            if key.hasPrefix("book.variable.") {
                let rawKey = String(key.dropFirst("book.variable.".count))
                bookVariables[rawKey] = value
            }
        }
        let bridge = LegadoBookBridge(
            durChapterIndex: Int(runtimeVariables?["book.durChapterIndex"] ?? "") ?? 0,
            durChapterTitle: runtimeVariables?["book.durChapterTitle"] ?? "",
            order: Int(runtimeVariables?["book.order"] ?? "") ?? 0,
            type: Int(runtimeVariables?["book.type"] ?? "") ?? 0,
            imageStyle: runtimeVariables?["book.imageStyle"] ?? "",
            name: runtimeVariables?["book.name"] ?? "",
            author: runtimeVariables?["book.author"] ?? "",
            coverUrl: runtimeVariables?["book.coverUrl"] ?? "",
            abstract: runtimeVariables?["book.abstract"] ?? "",
            variables: bookVariables
        )
        jsEngine.setBookBridge(bridge)
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

    private static func bodyForDataURI(_ analyzeUrl: AnalyzeUrl) -> String {
        guard let decoded = analyzeUrl.decodeDataUri() else { return "" }
        if analyzeUrl.type?.isEmpty == false {
            return decoded.data.map { String(format: "%02x", $0) }.joined()
        }
        return String(data: decoded.data, encoding: .utf8)
            ?? String(decoding: decoded.data, as: UTF8.self)
    }

    // MARK: - jsLib Caching

    /// Hashed `jsLib` content that was last evaluated.  `nil` means jsLib has never been evaluated.
    private var evaluatedJsLibHash: String?

    /// Evaluate jsLib once per source, caching the hash so we don't re-evaluate
    /// on every request.  jsLib functions (e.g. `BaseUrl()`, `getVariable()`,
    /// `request()`) stay in the shared JSContext scope.
    private func evaluateJsLibIfNeeded() {
        let jsLib = sourceRuleData.source.jsLib
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsLib.isEmpty else { return }

        let newHash = jsLib.md5Hash
        guard newHash != evaluatedJsLibHash else { return }

        _ = jsEngine.evaluate(jsLib)
        evaluatedJsLibHash = newHash
    }

    /// Re-evaluate jsLib on next use (e.g. after source variable reset).
    func invalidateJsLibCache() {
        evaluatedJsLibHash = nil
    }
}

private extension String {
    var md5Hash: String {
        guard let data = data(using: .utf8) else { return "" }
        let hash = CryptoKit.Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
