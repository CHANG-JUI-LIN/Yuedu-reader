import Foundation
import CryptoKit

// MARK: - Error

enum ModernParserBridgeError: LocalizedError {
    case invalidURL(String)
    case parseError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .timeout: return "Request timed out"
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
            var bindings: [String: Any] = [
                "baseUrl": engine.baseUrl,
                "baseURL": engine.baseUrl
            ]
            if let content = engine.content {
                // Legado exposes the response currently being parsed as the global `src`.
                // Some sources intentionally read `src` after an earlier rule segment has
                // transformed `result`, so the two values must remain independent.
                bindings["src"] = content
            }
            return self.jsEngine.evaluateIsolated(
                jsCode,
                result: prevResult,
                bindings: bindings
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
        jsEngine.sourceBridge.getKeyValueHandler = { [weak self] key in
            self?.runtimeStateStore.sourceValue(for: sourceUrl, key: key)
        }
        jsEngine.sourceBridge.putKeyValueHandler = { [weak self] key, value in
            self?.runtimeStateStore.setSourceValue(value, for: sourceUrl, key: key)
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
                sourceHeader: self.sourceRuleData.source.header,
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
        if !bookUrl.isEmpty {
            jsEngine.bookBridge.bookUrl = bookUrl
        }
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
        // An empty cover rule must NOT fall back to baseUrl (getString's isUrl path does that),
        // otherwise sources with an empty ruleBookInfo (七猫/书旗) get the site URL as a "cover"
        // and clobber the real search-result cover. Empty rule → empty cover → UI keeps search cover.
        let coverRule = source.ruleBookInfo.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverUrl = coverRule.isEmpty ? "" : engine.getString(ruleStr: coverRule, isUrl: true)
        let intro = engine.getString(ruleStr: source.ruleBookInfo.intro)
        let kind = engine.getString(ruleStr: source.ruleBookInfo.kind)
        let wordCount = engine.getString(ruleStr: source.ruleBookInfo.wordCount)
        let lastChapter = engine.getString(ruleStr: source.ruleBookInfo.lastChapter)
        // Same guard for tocUrl: an empty rule would otherwise resolve to baseUrl (site root) and
        // we'd scrape the homepage as a TOC. Empty rule → fall back to the book's own URL.
        let tocRule = source.ruleBookInfo.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let tocUrlRaw = tocRule.isEmpty ? "" : engine.getString(ruleStr: tocRule, isUrl: true)
        let tocUrl = tocUrlRaw.isEmpty ? bookUrl : tocUrlRaw

        return OnlineBook(
            // Leave empty when the source has no/empty ruleBookInfo (e.g. 七猫/书旗 ship `{}`)
            // or the name rule yields nothing — the detail UI then falls back to the search
            // result's title instead of clobbering it with a placeholder.
            name: name,
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
        guard !elements.isEmpty else {
            // Device-visible diagnostic: an empty chapter list almost always means the
            // chapterList rule's JS threw (e.g. a TDZ on `let result`, a failed java.ajax,
            // or a missing jsLib symbol). Surface the source + last JS error to Console so
            // "目录为空" is diagnosable without the in-app debug engine.
            AppLogger.parse("TOC chapterList produced 0 chapters", context: [
                "source": source.bookSourceName,
                "jsError": jsEngine.lastError ?? "none",
                "tocUrl": String(baseURL.prefix(120)),
                "bodyLen": "\(html.count)",
                "bodyHead": String(html.prefix(120)),
                "rule": String(listRule.prefix(60))
            ])
            return []
        }

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
                    let isVolume = Self.parseBool(isVolumeStr)
                    let isVip = Self.parseBool(isVipStr)
                    let isPay = Self.parseBool(isPayStr)

                    if !formatJs.isEmpty {
                        let chapterDict: [String: Any] = [
                            "index": index,
                            "title": title,
                            "url": url,
                            "isVolume": isVolume,
                            "isVip": isVip,
                            "isPay": isPay
                        ]
                        if let formatted = jsEngine.evaluate(
                            formatJs,
                            bindings: ["index": index, "title": title, "chapter": chapterDict]
                        ), !formatted.isEmpty {
                            title = ReaderHTMLUtilities.displayText(fromHTMLFragment: formatted)
                        }
                    }

                    let ref = OnlineChapterRef(
                        index: index,
                        title: title,
                        url: url,
                        isVolume: isVolume,
                        isVip: isVip,
                        isPay: isPay,
                        runtimeVariables: dumpRuntimeVariables()
                    )
                    if ref.isVolume || ref.hasVolumeSeparatorTitle || index < 12 {
                        AppLogger.parse("⟐ tocItem", context: [
                            "index": index,
                            "title": title,
                            "isVolumeRaw": isVolumeStr,
                            "isVolume": ref.isVolume,
                            "volumeTitle": ref.hasVolumeSeparatorTitle,
                            "shouldSkip": ref.shouldRenderAsVolumeSeparator,
                            "isVip": ref.isVip,
                            "isPay": ref.isPay,
                            "urlLen": ref.sanitizedContentURL.count,
                            "urlHead": String(ref.sanitizedContentURL.prefix(120))
                        ])
                    }
                    chapters.append(ref)
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
                    url: chapterRef.url,
                    // Carry the chapter's VIP flag (from ruleToc.isVip) into `chapter.isVip()`.
                    // 起点's content JS does `try { isVip = chapter.isVip() } catch { isVip = result.v }`
                    // to choose `/chapter/vip` vs `/chapter/free`. Building the bridge WITHOUT this
                    // (the build23 regression) left `chapter.isVip()` always false → VIP chapters
                    // were fetched from `/chapter/free` → proxy returned「网络开小差了」. result.v is
                    // never reached because isVip() returns a value (doesn't throw).
                    isVip: chapterRef.isVip
                )
            )
        } else {
            jsEngine.setChapterBridge(LegadoChapterBridge())
        }
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        // ⟐ contentJS — diagnose 段评-on infinite-loading: if "done" never logs the
        // ruleContent JS (getComments→ajaxAll) hung; if it logs empty the JS returned
        // nothing; if it logs content+0 bubbles the comment injection silently failed.
        let paraState = BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: source.bookSourceUrl) ?? ""
        AppLogger.parse("⟐ contentJS start", context: [
            "title": chapterRef?.title ?? "",
            "vars": String(paraState.prefix(160))
        ])
        // 段评样式: content JS 的段评注入函数在 iOS 上（deviceType=='苹果'）会走「iOS 变体」，
        // 产出 <comment count onPress> → app 原生 .commentBadge，完全忽略书源「段评样式」SVG
        // 设置（起点对话框等）。为忠实还原书源样式，在 content 规则执行前把「iOS 变体」别名成
        // 「Android 变体」，让 iOS 也按书源段评样式产出 SVG <img>，再由 CommentBubbleSVGRecognizer
        // 原生重绘、跟随阅读字体。仅同时定义两者的源会被改写；只定义 iOS 变体的源维持原状。
        // 覆盖两套常见命名: paraForiOS/paraForAndroid 与 getCommentsios/getComments。
        // 注意: createSvg 用 java.get('dev') 选气泡变体，dev='ios'(见 qread 移除)→ios 变体(方形/紧凑)，
        // dev='android-轻阅读'→轻阅读变体(偏宽)。
        let aliasedParaForiOS = jsEngine.evaluate(
            """
            (function () {
                var done = [];
                if (typeof paraForAndroid === 'function' && typeof paraForiOS === 'function') {
                    paraForiOS = paraForAndroid; done.push('para');
                }
                if (typeof getComments === 'function' && typeof getCommentsios === 'function') {
                    getCommentsios = getComments; done.push('getComments');
                }
                return done.length ? done.join('+') : 'false';
            })()
            """
        ) ?? "false"

        let _contentStart = Date()
        let content = engine.getString(ruleStr: source.ruleContent.content)
        let _contentMs = Int(Date().timeIntervalSince(_contentStart) * 1000)

        let lowerContent = content.lowercased()
        let lowerInput = html.lowercased()
        let bubbleCount = content.components(separatedBy: "data:image/svg").count - 1
        AppLogger.parse("⟐ contentJS done", context: [
            "ms": _contentMs,
            "len": content.count,
            "bubbles": bubbleCount,
            "commentTags": lowerContent.components(separatedBy: "<comment").count - 1,
            "ydreview": lowerContent.components(separatedBy: "ydreview://").count - 1,
            "showCmt": lowerContent.components(separatedBy: "showcmt").count - 1,
            "androidShowCmt": lowerContent.components(separatedBy: "androidshowcmt").count - 1,
            "aliasParaForiOS": aliasedParaForiOS,
            "inputLen": html.count,
            "baseURL": String(baseURL.prefix(120)),
            "inputHex": Self.hexPreview(html, byteLimit: 32),
            "inputHasContent": lowerInput.contains(#""content""#),
            "inputHasReview": lowerInput.contains("review") || lowerInput.contains("comment"),
            "empty": content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "jsError": jsEngine.lastError ?? "none",
            "head": String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        ])
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
        // #region agent log
        if source.bookSourceName.contains("企点") {
            NSLog("[企點診斷] searchBooks fetch URL → %@", finalUrl)
            NSLog("[企點診斷] searchBooks response(前200字) → %@", String(body.prefix(200)))
        }
        _dbgLog("聚合/JS 搜尋", data: [
            "source": source.bookSourceName,
            "变量": String(
                (BookSourceRuntimeStateStore.shared
                    .sourceVariableJSON(for: source.bookSourceUrl) ?? "(空)").prefix(300)),
            "搜索参数": Self.searchParamsPreview(from: finalUrl),
        ], hyp: "S1")
        // #endregion
        return try parseSearchResults(html: body, baseURL: finalUrl, source: source)
    }

    func searchBooksStreaming(
        keyword: String,
        page: Int = 1,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async throws -> (books: [OnlineBook], streamed: Bool) {
        let source = sourceRuleData.source
        guard !source.searchUrl.isEmpty else { return ([], false) }

        let (body, finalUrl) = try await fetch(
            ruleUrl: source.searchUrl, key: keyword, page: page
        )
        // #region agent log
        _dbgLog("聚合/JS 搜尋", data: [
            "source": source.bookSourceName,
            "变量": String(
                (BookSourceRuntimeStateStore.shared
                    .sourceVariableJSON(for: source.bookSourceUrl) ?? "(空)").prefix(300)),
            "搜索参数": Self.searchParamsPreview(from: finalUrl),
        ], hyp: "S1")
        // #endregion

        if let plan = aggregateSearchPlan(fromHexBody: body) {
            let books = await searchAggregateSubsources(
                plan: plan,
                baseURL: finalUrl,
                source: source,
                onBatch: onBatch
            )
            return (books, true)
        }

        return (try parseSearchResults(html: body, baseURL: finalUrl, source: source), false)
    }

    private struct AggregateSearchPlan {
        var params: [String: Any]
        var sourceKeys: [String]
    }

    private func aggregateSearchPlan(fromHexBody body: String) -> AggregateSearchPlan? {
        guard var params = Self.jsonDictionaryFromHexBody(body),
              var key = params["key"] as? String,
              var tab = params["tab"] as? String,
              var selectedSource = params["sourcesKey"] as? String
        else {
            return nil
        }

        let prefix = key.prefix(2).lowercased()
        let mediaByPrefix = ["x:": "小说", "t:": "听书", "m:": "漫画", "d:": "短剧",
                             "x：": "小说", "t：": "听书", "m：": "漫画", "d：": "短剧"]
        var isQualified = false
        if let media = mediaByPrefix[prefix] {
            isQualified = true
            tab = media
            key.removeFirst(min(2, key.count))
        }
        if let at = key.firstIndex(of: "@") {
            isQualified = true
            let source = String(key[key.index(after: at)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            key = String(key[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty { selectedSource = source }
        }
        params["key"] = key
        params["tab"] = tab
        params["sourcesKey"] = selectedSource

        if selectedSource != "全部" {
            return isQualified ? AggregateSearchPlan(params: params, sourceKeys: [selectedSource]) : nil
        }
        guard !tab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let sourceKeys = configuredAggregateSourceKeys(for: tab)
        guard sourceKeys.count > 1 else { return nil }
        params["sourcesKey"] = selectedSource
        return AggregateSearchPlan(params: params, sourceKeys: sourceKeys)
    }

    private func configuredAggregateSourceKeys(for tab: String) -> [String] {
        guard let variableJSON = runtimeStateStore.sourceVariableJSON(
            for: sourceRuleData.source.bookSourceUrl),
              let data = variableJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        let config = (root["云端配置"] as? [String: Any]) ?? root
        guard let rawList = config[tab] as? [Any] else { return [] }

        var seen = Set<String>()
        var keys: [String] = []
        for item in rawList {
            guard let key = Self.aggregateSourceKey(from: item) else { continue }
            guard key != "全部", seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    private func searchAggregateSubsources(
        plan: AggregateSearchPlan,
        baseURL: String,
        source: BookSource,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async -> [OnlineBook] {
        let maxConcurrentSubsources = min(4, plan.sourceKeys.count)
        let observer = debugObserver
        var allBooks: [OnlineBook] = []

        await withTaskGroup(of: [OnlineBook].self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < plan.sourceKeys.count else { return }
                let sourceKey = plan.sourceKeys[nextIndex]
                nextIndex += 1

                var params = plan.params
                params["sourcesKey"] = sourceKey
                guard let body = Self.hexBody(forJSONObject: params) else { return }

                group.addTask {
                    guard !Task.isCancelled else { return [] }
                    let bridge = ModernParserBridge(source: source)
                    bridge.debugObserver = observer
                    return (try? bridge.parseSearchResults(
                        html: body,
                        baseURL: baseURL,
                        source: source
                    )) ?? []
                }
            }

            for _ in 0..<maxConcurrentSubsources {
                enqueueNext()
            }

            while let books = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if !books.isEmpty {
                    allBooks.append(contentsOf: books)
                    await onBatch(books)
                }
                enqueueNext()
            }
        }

        return allBooks
    }

    private static func aggregateSourceKey(from item: Any) -> String? {
        if let string = item as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = item as? [String: Any] {
            for field in ["name", "title", "source", "sourceName", "key"] {
                if let string = dict[field] as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func jsonDictionaryFromHexBody(_ body: String) -> [String: Any]? {
        var bytes: [UInt8] = []
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
            guard next <= body.endIndex else { return nil }
            let hex = body[index..<next]
            guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard !bytes.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    private static func hexBody(forJSONObject object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// For logging: if `url` is the aggregate sources' `data:;base64,…` pseudo-URL,
    /// decode it so the resolved search params (e.g. `sourcesKey`/`server`) are
    /// visible on-device. Returns a short prefix of the URL otherwise.
    private static func searchParamsPreview(from url: String) -> String {
        guard url.hasPrefix("data:"),
              let range = url.range(of: ";base64,") else {
            return String(url.prefix(120))
        }
        let payload = String(url[range.upperBound...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = String(data: data, encoding: .utf8) else {
            return String(url.prefix(120))
        }
        return String(json.prefix(200))
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
        let isJS = Self.isJSExploreRule(rawExploreUrl)
        if isJS {
            let jsCode = Self.jsCode(fromExploreRule: rawExploreUrl)
            let bindings: [String: Any] = [
                "page": page,
                "baseUrl": source.bookSourceUrl,
            ]
            ruleStr = jsEngine.evaluateIsolated(jsCode, bindings: bindings)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let result: [DiscoverItem]
        if ruleStr.isEmpty {
            result = []
        } else if Self.isJsonArrayOrObject(ruleStr) {
            let items = parseDiscoverJSON(ruleStr)
            // When the exploreUrl JS returns book data JSON directly (not a list
            // of discover categories), every decoded DiscoverItem has an empty
            // title.  If that happens AND the source has ruleExplore.bookList
            // (meaning it can parse book data), wrap the JSON as a data URI so
            // the normal discover pipeline feeds it through ruleExplore.
            if items.allSatisfy({ ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               !source.ruleExplore.bookList.isEmpty {
                let b64 = Data(ruleStr.utf8).base64EncodedString()
                let dataUrl = "data:application/json;base64,\(b64)"
                result = [DiscoverItem(title: source.bookSourceName, url: dataUrl)]
            } else {
                result = items
            }
        } else if Self.looksLikeMarkupOrError(ruleStr) {
            // A dynamic (<js>/@js:) exploreUrl whose backing endpoint has died returns an error
            // *document* — e.g. an nginx "404 Not Found" HTML page — not JSON and not a `分类::URL`
            // list. Shredding that markup line-by-line produced garbage category chips ("<html>",
            // "<head>…404…", …). Treat an unusable payload as "no explore content" instead.
            result = []
        } else {
            result = parseExploreKindText(ruleStr)
        }

        return result
    }

    /// True when an explore payload is an HTML/error document rather than a JSON or
    /// `分类::URL` list — so a dead endpoint's 404 page isn't rendered as fake categories.
    static func looksLikeMarkupOrError(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return true }
        if s.hasPrefix("<") { return true }
        let lower = s.lowercased()
        return lower.contains("<html")
            || lower.contains("<!doctype")
            || lower.contains("<body")
            || lower.contains("404 not found")
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
                // Drop stray markup lines (HTML fragments from a dead endpoint) — a real category
                // name never contains an `<…>` tag.
                if entry.range(of: #"<[^>]+>"#, options: .regularExpression) != nil { return nil }

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

        // Legado convention: a source that ships no explore-specific rules (empty
        // ruleExplore.bookList) reuses its SEARCH rules for discover — the explore
        // endpoints return the same shape as search results. Most comic sources
        // rely on this (their `ruleExplore` is `{}`, only `ruleSearch` is defined),
        // so fall back to ruleSearch instead of giving up on the discover list.
        let explore = source.ruleExplore
        let search = source.ruleSearch
        let useSearch = explore.bookList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let listRule = useSearch ? search.bookList : explore.bookList

        guard !listRule.isEmpty else {
            // Neither explore nor search defines a book list — last-ditch: treat the
            // payload as a JSON list of {title,url} discover items.
            return discoverItemsAsBooks(html: html, source: source)
        }

        let nameRule = useSearch ? search.name : explore.name
        let authorRule = useSearch ? search.author : explore.author
        let bookUrlRule = useSearch ? search.bookUrl : explore.bookUrl
        let coverRule = useSearch ? search.coverUrl : explore.coverUrl
        let introRule = useSearch ? search.intro : explore.intro
        let wordCountRule = useSearch ? search.wordCount : explore.wordCount
        let lastChapterRule = useSearch ? search.lastChapter : explore.lastChapter
        let kindRule = useSearch ? search.kind : explore.kind

        // Parse books for one bookList variant. Resets engine content to the full
        // page first, because the per-element loop reassigns it.
        func parseBooks(listVariant: String) -> (books: [OnlineBook], elements: Int, emptyNames: Int) {
            engine.setContent(html, baseUrl: baseURL)
            let elements = engine.getElements(ruleStr: listVariant)
            var result: [OnlineBook] = []
            var emptyNames = 0
            for (idx, element) in elements.enumerated() {
                engine.setContent(element, baseUrl: baseURL)
                let name = engine.getString(ruleStr: nameRule)
                if idx == 0 {
                    let elHTML = String(describing: element).prefix(180)
                        .replacingOccurrences(of: "\n", with: " ")
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) EL0 list='\(listVariant.prefix(24))' nameRule='\(nameRule.prefix(24))' name='\(name.prefix(30))' el=\(elHTML)")
                }
                guard !name.isEmpty else { emptyNames += 1; continue }
                let bookUrl = engine.getString(ruleStr: bookUrlRule, isUrl: true)
                // `isUrl:true` falls back to baseURL when the rule matches nothing —
                // a cover that is merely the page URL is junk (e.g. a bookList narrowed
                // past the <img>, like zymk's `class.item@h3`), so treat it as missing.
                // This also lets the cover-broaden retry below detect the gap.
                var coverUrl = engine.getString(ruleStr: coverRule, isUrl: true)
                if coverUrl == baseURL { coverUrl = "" }
                result.append(OnlineBook(
                    name: name,
                    author: engine.getString(ruleStr: authorRule),
                    intro: engine.getString(ruleStr: introRule),
                    coverUrl: coverUrl,
                    bookUrl: bookUrl,
                    tocUrl: bookUrl,
                    wordCount: engine.getString(ruleStr: wordCountRule),
                    lastChapter: engine.getString(ruleStr: lastChapterRule),
                    kind: engine.getString(ruleStr: kindRule),
                    sourceId: source.id, sourceName: source.bookSourceName
                ))
            }
            return (result, elements.count, emptyNames)
        }

        let primary = parseBooks(listVariant: listRule)
        var books = primary.books
        NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore useSearch=\(useSearch) listRule='\(listRule.prefix(40))' elements=\(primary.elements) books=\(books.count) emptyNames=\(primary.emptyNames)")

        // Compatibility beyond Legado: a `||` bookList returns the FIRST non-empty
        // element set, but that set can be the wrong one — e.g. a discover page that
        // reuses the search grid's class (`.manga-list`) for its category nav, so the
        // first branch matches nav links and every "book" has an empty name. When the
        // chosen branch yields zero valid books, retry the remaining `||` branches.
        if books.isEmpty {
            let (op, parts) = RuleSyntaxParser.splitRuleByOperators(listRule)
            if op == "||", parts.count > 1 {
                for branch in parts.dropFirst() {
                    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let alt = parseBooks(listVariant: trimmed)
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore || retry '\(trimmed.prefix(30))' elements=\(alt.elements) books=\(alt.books.count)")
                    if !alt.books.isEmpty { books = alt.books; break }
                }
            }
        }

        // Cover compatibility: some sources narrow the bookList past the cover —
        // e.g. `class.item@h3` selects the title node while the <img> lives in a
        // sibling `.thumbnail`, so `img@data-src` resolves empty for every book.
        // When all books came back cover-less, retry with the bookList's parent
        // scope (drop the trailing `@leaf`), but only ADOPT it when it returns the
        // same number of books AND actually recovers covers — so a correctly-scoped
        // bookList, or a source that genuinely has no covers, is left untouched.
        if !books.isEmpty,
           books.allSatisfy({ $0.coverUrl.isEmpty }),
           let lastAt = listRule.range(of: "@", options: .backwards) {
            let broaderList = String(listRule[..<lastAt.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !broaderList.isEmpty {
                let broader = parseBooks(listVariant: broaderList)
                if broader.books.count == books.count,
                   broader.books.contains(where: { !$0.coverUrl.isEmpty }) {
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore cover-broaden '\(broaderList.prefix(30))' recovered covers (\(broader.books.count) books)")
                    books = broader.books
                }
            }
        }

        // The ruleSearch fallback can legitimately match nothing when the discover
        // payload is instead a plain {title,url} JSON list. Preserve that legacy
        // path so no source that worked before this fallback regresses.
        if books.isEmpty, useSearch {
            let fallback = discoverItemsAsBooks(html: html, source: source)
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore search-fallback empty → discoverJSON books=\(fallback.count)")
            return fallback
        }
        return books
    }

    /// Last-resort discover parse: decode the payload as a JSON list of `{title,url}`
    /// items (Legado's "exploreUrl returns book data directly" shape). Returns an
    /// empty list for any other payload, so it is safe as a fallback.
    private func discoverItemsAsBooks(html: String, source: BookSource) -> [OnlineBook] {
        parseDiscoverJSON(html).compactMap { item in
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

    /// Prime a site cookie that a source's discover endpoints read inline but never set themselves.
    /// 起点's 榜單/分類 build URLs with `…&_csrfToken={{cookie.getKey("https://qidian.com","_csrfToken")}}`
    /// AND 起点 requires the SAME token be SENT as a cookie (double-submit) — verified: param-only →
    /// `{"code":1,"msg":"失败"}` 0 books; param+cookie → 20 books. That token is only issued by browsing
    /// a 起点 book/search page (NOT the homepage, NOT the qt 密鑰). So on iOS the discover is empty
    /// unless we obtain it. We **always re-fetch a fresh token** (not just when absent): a STALE
    /// `_csrfToken` left over from old browsing is session-rejected by 起点, and a skip-if-present
    /// guard would keep using it → still 0 books. Fetching the source's own search page reissues a
    /// current token (stored in HTTPCookieStorage, auto-sent by URLSession on the ranking request).
    func primeDiscoverCookiesIfNeeded() async {
        let source = sourceRuleData.source
        guard source.exploreUrl.contains("_csrfToken") else { return }
        let searchUrl = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchUrl.isEmpty else { return }
        _ = try? await fetch(ruleUrl: searchUrl, key: "1", page: 1)
    }

    func fetch(
        ruleUrl: String, key: String? = nil, page: Int? = nil
    ) async throws -> (String, String) {
        ensureCloudSettingsIfNeeded()
        let analyzeUrl = AnalyzeUrl(
            ruleUrl: ruleUrl,
            key: key,
            page: page,
            sourceHeader: sourceRuleData.source.header,
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

        if sourceRuleData.source.bookSourceName.contains("企点") {
            NSLog("[企點診斷] fetch 請求 URL → %@", request.url?.absoluteString ?? "nil")
            NSLog("[企點診斷] fetch 請求 method → %@ body → %@",
                  request.httpMethod ?? "GET",
                  request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")
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

        // Explicitly attach the cookie jar for this URL when no Cookie header is set.
        // Some endpoints require a cookie to be SENT alongside a matching URL param
        // (double-submit CSRF) — 起点 榜單/分類 reject the request unless the `_csrfToken`
        // cookie == the `_csrfToken` query param (verified: param-only → 0 books;
        // param+cookie → 20). URLSession.shared *should* auto-send it from HTTPCookieStorage,
        // but being explicit (mirroring WebFetcher) guarantees it isn't dropped.
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let reqUrl = request.url?.absoluteString {
            let jar = CookieStore.shared.get(url: reqUrl)
            if !jar.isEmpty {
                request.setValue(jar, forHTTPHeaderField: "Cookie")
            }
        }

        // Use a cooperative timeout so a hanging server never blocks the search/reader
        // indefinitely. The per-source search already has its own timeout in the
        // aggregator, but individual TOC/book-info fetches do not.
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withThrowingTaskGroup(
                of: (Data, URLResponse).self
            ) { group in
                group.addTask {
                    try await URLSession.shared.data(for: request)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw ModernParserBridgeError.timeout
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        } catch is ModernParserBridgeError {
            throw ModernParserBridgeError.timeout
        }

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
            bookUrl: runtimeVariables?["book.bookUrl"] ?? "",
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

    private static func hexPreview(_ text: String, byteLimit: Int) -> String {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return "" }
        return data.prefix(byteLimit).map { String(format: "%02x", $0) }.joined(separator: " ")
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
        // A `type` key in the data-URI options means "return the payload hex-encoded"
        // (binary-safe), which the source then decodes with `java.hexDecodeToString`.
        // The VALUE is just a marker — 起点 uses `{"type":"X-QD"}` for tocUrl but
        // `{"type":""}` (empty!) for chapter content, and BOTH content/toc JS call
        // hexDecodeToString. Keying off `type?.isEmpty == false` wrongly sent the
        // empty-type content payload back as UTF-8, so hexDecodeToString failed and the
        // chapter stuck on "加载中". Hex whenever `type` is present (even empty); only a
        // fully absent `type` returns the decoded string.
        if analyzeUrl.type != nil {
            return decoded.data.map { String(format: "%02x", $0) }.joined()
        }
        return String(data: decoded.data, encoding: .utf8)
            ?? String(decoding: decoded.data, as: UTF8.self)
    }

    // MARK: - jsLib Caching

    /// Hashed `jsLib` content that was last evaluated.  `nil` means jsLib has never been evaluated.
    private var evaluatedJsLibHash: String?
    /// Engine generation at the time `evaluatedJsLibHash` was set.  Invalidated
    /// when `jsEngine.generation` changes (engine was reset after a JS timeout).
    private var evaluatedJsLibEngineGen: UInt64 = 0

    /// Evaluate jsLib once per source, caching the hash so we don't re-evaluate
    /// on every request.  jsLib functions (e.g. `BaseUrl()`, `getVariable()`,
    /// `request()`) stay in the shared JSContext scope.
    private func evaluateJsLibIfNeeded() {
        let jsLib = sourceRuleData.source.jsLib
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsLib.isEmpty else { return }

        // If the JS engine was reset (timeout recovery), the new context has no
        // jsLib code — force re-evaluation.
        if jsEngine.generation != evaluatedJsLibEngineGen {
            evaluatedJsLibHash = nil
            evaluatedJsLibEngineGen = jsEngine.generation
        }

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
