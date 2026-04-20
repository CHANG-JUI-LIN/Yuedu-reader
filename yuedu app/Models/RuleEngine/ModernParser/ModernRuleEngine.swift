import Foundation

/// Central rule processing engine ported from Legado's AnalyzeRule.kt.
/// Orchestrates all extractors and implements the full rule processing pipeline.
///
/// Key responsibilities (matching AnalyzeRule.kt):
/// 1. Content management: set content (HTML/JSON/elements), track context
/// 2. Rule splitting: split by JS boundaries, then chain SourceRule segments
/// 3. Mode routing: route each segment to the correct extractor by SourceRule.mode
/// 4. Template evaluation: resolved by SourceRule.makeUpRule
/// 5. JavaScript evaluation: @js: / <js> via jsEvaluator closure
/// 6. Regex post-processing: ##pattern##replacement via RegexReplacer
/// 7. Variable storage: @put/@get via RuleDataInterface chain
final class ModernRuleEngine {

    // MARK: - Global Extractor Registry (Open/Closed Principle)

    private static var _registry: [RuleExtractor] = [
        CssExtractor(),
        XPathExtractor(),
        JsonExtractor(),
        JsoupDefaultExtractor(),
        RegexExtractor(),
        LegacyFallbackExtractor(),
    ]
    private static let registryLock = NSLock()

    static func registerExtractor(_ extractor: RuleExtractor) {
        registryLock.withLock { _registry.append(extractor) }
    }

    static func registerExtractor(_ extractor: RuleExtractor, at index: Int) {
        registryLock.withLock {
            _registry.insert(extractor, at: min(index, _registry.count))
        }
    }

    static var registeredExtractors: [RuleExtractor] {
        registryLock.withLock { _registry }
    }

    static func setExtractors(_ extractors: [RuleExtractor]) {
        registryLock.withLock { _registry = extractors }
    }

    // MARK: - Instance Properties

    /// Content to parse (HTML string, JSON string, element, etc.)
    private var content: Any?

    /// Base URL for resolving relative URLs
    private(set) var baseUrl: String = ""

    /// Redirect URL used for URL resolution (matching Legado)
    private(set) var redirectUrl: URL?

    /// Whether current content is detected as JSON
    private var isJSON: Bool = false

    /// Whether engine is currently in regex mode
    private var isRegex: Bool = false

    /// Context objects implementing RuleDataInterface.
    /// Variable lookup chain: chapter -> book -> ruleData -> source
    var source: RuleDataInterface?
    var book: RuleDataInterface?
    var chapter: RuleDataInterface?
    var ruleData: RuleDataInterface?

    /// Next chapter URL (available in JS context)
    var nextChapterUrl: String?

    /// Registered extractors for this engine instance
    private let extractors: [RuleExtractor]

    /// JS evaluator: (jsCode, currentResult) -> evaluatedResult.
    /// Wire in Phase 3 with JavaScriptCore integration.
    var jsEvaluator: ((String, Any?) -> Any?)?

    /// Parsed-rule cache to avoid re-parsing the same rule string
    private let stringRuleCache = LRUCache<String, [SourceRule]>(capacity: 256)

    /// Optional debug observer. When set, the engine emits `RuleDebugEvent`s at
    /// each pipeline step (raw data, rule type, nodes extracted, regex applied, JS result).
    /// Set this in `BookSourceDebugEngine` to collect granular logs comparable with
    /// Legado's Android debug output.  Has zero overhead when nil.
    var debugObserver: ((RuleDebugEvent) -> Void)?

    // MARK: - JS Pattern (matching Legado AppPattern.JS_PATTERN)

    /// Matches <js>...</js> (lazy) or @js:... (greedy to end)
    private static let jsPattern = try! NSRegularExpression(
        pattern: #"<js>([\w\W]*?)</js>|@js:([\w\W]*)"#,
        options: .caseInsensitive
    )

    // MARK: - Initialisation

    init(extractors: [RuleExtractor]? = nil) {
        self.extractors = extractors ?? ModernRuleEngine.registeredExtractors
    }

    // MARK: - Content Management (matching Legado setContent/setBaseUrl)

    @discardableResult
    func setContent(_ content: Any?, baseUrl: String = "") -> ModernRuleEngine {
        self.content = content
        self.baseUrl = baseUrl
        self.isJSON = Self.detectJSON(content)

        if let obs = debugObserver {
            let str = Self.toString(content)
            let type: String
            if isJSON { type = "JSON" }
            else if content is String { type = "HTML" }
            else { type = "Elements" }
            obs(.contentSet(
                contentType: type,
                length: str.count,
                preview: String(str.prefix(200)),
                baseUrl: baseUrl
            ))
        }

        return self
    }

    @discardableResult
    func setBaseUrl(_ baseUrl: String?) -> ModernRuleEngine {
        if let url = baseUrl { self.baseUrl = url }
        return self
    }

    @discardableResult
    func setRedirectUrl(_ url: String) -> ModernRuleEngine {
        self.redirectUrl = URL(string: url)
        return self
    }

    // MARK: - getString (matching Legado AnalyzeRule.getString)

    /// Get a single string by evaluating a rule chain.
    /// Rules are split by JS boundaries into SourceRule segments; each segment
    /// is evaluated sequentially with the previous result as input.
    func getString(ruleStr: String?, mContent: Any? = nil, isUrl: Bool = false) -> String {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else {
            return isUrl ? baseUrl : ""
        }
        let ruleList = splitSourceRuleCached(ruleStr)
        return getString(ruleList: ruleList, mContent: mContent, isUrl: isUrl)
    }

    /// Evaluate a pre-parsed rule list for a single string.
    func getString(
        ruleList: [SourceRule],
        mContent: Any? = nil,
        isUrl: Bool = false
    ) -> String {
        var result: Any? = nil
        let content = mContent ?? self.content
        guard content != nil, !ruleList.isEmpty else {
            return isUrl ? baseUrl : ""
        }

        let t0 = debugObserver != nil ? Date() : Date.distantPast

        // Emit rule-parse event
        if let obs = debugObserver {
            let segs = ruleList.enumerated().map { i, sr in
                RuleDebugEvent.RuleSegmentInfo(
                    index: i,
                    mode: "\(sr.mode)",
                    rule: sr.rule,
                    replacePattern: sr.replaceRegex
                )
            }
            // Use first rule's original rule string as label
            let ruleStr = ruleList.first.map { $0.rule } ?? ""
            obs(.rulesParsed(ruleStr: ruleStr, segments: segs))
        }

        result = content
        for (idx, sourceRule) in ruleList.enumerated() {
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: result) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard result != nil else { continue }

            let rule = sourceRule.rule
            if !rule.trimmingCharacters(in: .whitespaces).isEmpty
                || sourceRule.replaceRegex.isEmpty
            {
                let inputPreview = String(Self.toString(result).prefix(200))

                switch sourceRule.mode {
                case .js:
                    debugObserver?(.beforeExtract(
                        segmentIndex: idx, mode: "js",
                        qualifiedRule: String(rule.prefix(80)), inputPreview: inputPreview
                    ))
                    let jsResult = evalJS(rule, result: result)
                    result = jsResult
                    debugObserver?(.jsExecuted(
                        segmentIndex: idx,
                        script: String(rule.prefix(300)),
                        inputPreview: inputPreview,
                        result: Self.toString(jsResult)
                    ))

                case .regex:
                    result = rule

                case .json, .xpath, .default:
                    let qualified = modeQualifiedRule(mode: sourceRule.mode, rule: rule)
                    debugObserver?(.beforeExtract(
                        segmentIndex: idx, mode: "\(sourceRule.mode)",
                        qualifiedRule: qualified, inputPreview: inputPreview
                    ))
                    let extracted = extractStringViaExtractor(content: result!, rule: qualified)
                    result = extracted
                    debugObserver?(.afterExtractValue(
                        segmentIndex: idx, result: Self.toString(extracted)
                    ))
                }
            }

            if result != nil, !sourceRule.replaceRegex.isEmpty {
                let before = Self.toString(result)
                result = replaceRegex(result: before, sourceRule: sourceRule)
                debugObserver?(.regexApplied(
                    segmentIndex: idx,
                    pattern: sourceRule.replaceRegex,
                    replacement: sourceRule.replacement,
                    before: before,
                    after: Self.toString(result)
                ))
            }
        }

        let resultStr = result == nil ? "" : Self.toString(result)
        if let obs = debugObserver {
            let ms = Date().timeIntervalSince(t0) * 1000
            obs(.finalResult(value: resultStr, elapsedMs: ms))
        }

        if isUrl {
            return resultStr.isEmpty ? baseUrl : resolveURL(resultStr)
        }
        return resultStr
    }

    // MARK: - getStringList (matching Legado AnalyzeRule.getStringList)

    /// Get a list of strings by evaluating a rule chain.
    func getStringList(
        ruleStr: String?, mContent: Any? = nil, isUrl: Bool = false
    ) -> [String] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }
        let ruleList = splitSourceRuleCached(ruleStr)
        return getStringList(ruleList: ruleList, mContent: mContent, isUrl: isUrl)
    }

    /// Evaluate a pre-parsed rule list for a string list.
    func getStringList(
        ruleList: [SourceRule],
        mContent: Any? = nil,
        isUrl: Bool = false
    ) -> [String] {
        var result: Any? = nil
        let content = mContent ?? self.content
        guard content != nil, !ruleList.isEmpty else { return [] }

        let t0 = debugObserver != nil ? Date() : Date.distantPast

        result = content
        for (idx, sourceRule) in ruleList.enumerated() {
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: result) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard result != nil else { continue }

            let rule = sourceRule.rule
            if !rule.isEmpty {
                let inputPreview = String(Self.toString(result).prefix(200))

                switch sourceRule.mode {
                case .js:
                    debugObserver?(.beforeExtract(
                        segmentIndex: idx, mode: "js",
                        qualifiedRule: String(rule.prefix(80)), inputPreview: inputPreview
                    ))
                    let jsResult = evalJS(rule, result: result)
                    result = jsResult
                    debugObserver?(.jsExecuted(
                        segmentIndex: idx,
                        script: String(rule.prefix(300)),
                        inputPreview: inputPreview,
                        result: Self.toString(jsResult)
                    ))

                case .regex:
                    result = rule

                case .json, .xpath, .default:
                    let qualified = modeQualifiedRule(mode: sourceRule.mode, rule: rule)
                    debugObserver?(.beforeExtract(
                        segmentIndex: idx, mode: "\(sourceRule.mode)",
                        qualifiedRule: qualified, inputPreview: inputPreview
                    ))
                    let extracted = extractStringListViaExtractor(content: result!, rule: qualified)
                    result = extracted
                    let items = (extracted as? [Any])?.map { Self.toString($0) } ?? []
                    debugObserver?(.afterExtractList(
                        segmentIndex: idx,
                        count: items.count,
                        items: Array(items.prefix(10))
                    ))
                }
            }

            if !sourceRule.replaceRegex.isEmpty {
                if let list = result as? [Any] {
                    let before = list.map { Self.toString($0) }
                    result = before.map { replaceRegex(result: $0, sourceRule: sourceRule) }
                    if let obs = debugObserver, let first = before.first {
                        let after = (result as? [String])?.first ?? ""
                        obs(.regexApplied(
                            segmentIndex: idx,
                            pattern: sourceRule.replaceRegex,
                            replacement: sourceRule.replacement,
                            before: first, after: after
                        ))
                    }
                } else if result != nil {
                    let before = Self.toString(result)
                    result = replaceRegex(result: before, sourceRule: sourceRule)
                    debugObserver?(.regexApplied(
                        segmentIndex: idx,
                        pattern: sourceRule.replaceRegex,
                        replacement: sourceRule.replacement,
                        before: before,
                        after: Self.toString(result)
                    ))
                }
            }
        }

        guard let finalResult = result else { return [] }

        // Convert result to [String]
        var stringList: [String]
        if let str = finalResult as? String {
            stringList = str.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else if let list = finalResult as? [Any] {
            stringList = list.map { Self.toString($0) }.filter { !$0.isEmpty }
        } else {
            let str = Self.toString(finalResult)
            stringList = str.isEmpty ? [] : [str]
        }

        if let obs = debugObserver {
            let ms = Date().timeIntervalSince(t0) * 1000
            obs(.finalResultList(values: stringList, elapsedMs: ms))
        }

        if isUrl {
            var urlList: [String] = []
            for item in stringList {
                let absoluteURL = resolveURL(item)
                if !absoluteURL.isEmpty, !urlList.contains(absoluteURL) {
                    urlList.append(absoluteURL)
                }
            }
            return urlList
        }
        return stringList
    }

    // MARK: - getElements (matching Legado AnalyzeRule.getElements)

    /// Get elements (for list rules like book list, chapter list).
    /// Uses allInOne = true when splitting (leading : forces regex mode).
    func getElements(ruleStr: String) -> [Any] {
        guard !ruleStr.isEmpty else { return [] }

        var result: Any? = nil
        let content = self.content
        let ruleList = splitSourceRule(ruleStr, allInOne: true)
        guard content != nil, !ruleList.isEmpty else { return [] }

        result = content
        for sourceRule in ruleList {
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: result) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard result != nil else { continue }

            let rule = sourceRule.rule
            switch sourceRule.mode {
            case .js:
                result = evalJS(rule, result: result)
            case .regex:
                result = extractRegexElements(content: result!, rule: rule)
            case .json, .xpath, .default:
                let qualified = modeQualifiedRule(mode: sourceRule.mode, rule: rule)
                result = extractElementsViaExtractor(
                    content: result!, rule: qualified
                )
            }

            if !sourceRule.replaceRegex.isEmpty, result != nil {
                result = replaceRegex(
                    result: Self.toString(result), sourceRule: sourceRule
                )
            }
        }

        if let list = result as? [Any] { return list }
        if let result = result { return [result] }
        return []
    }

    // MARK: - splitSourceRule (matching Legado AnalyzeRule.splitSourceRule)

    /// Split a rule string into SourceRule segments by JS boundaries.
    /// <js>...</js> and @js:... produce JS-mode segments; everything else
    /// becomes a segment with mode detected from prefixes.
    func splitSourceRule(_ ruleStr: String, allInOne: Bool = false) -> [SourceRule] {
        guard !ruleStr.isEmpty else { return [] }

        var ruleList: [SourceRule] = []
        var mMode: RuleMode = .default
        var start = 0

        // Leading : forces regex mode (Legado allInOne behavior)
        if allInOne, ruleStr.hasPrefix(":") {
            mMode = .regex
            isRegex = true
            start = 1
        } else if isRegex {
            mMode = .regex
        }

        let nsRule = ruleStr as NSString
        let searchRange = NSRange(location: start, length: nsRule.length - start)
        let jsMatches = Self.jsPattern.matches(in: ruleStr, range: searchRange)

        for match in jsMatches {
            let matchStart = match.range.location

            // Non-JS segment before this match
            if matchStart > start {
                let segment = nsRule.substring(
                    with: NSRange(location: start, length: matchStart - start)
                ).trimmingCharacters(in: .whitespaces)
                if !segment.isEmpty {
                    ruleList.append(
                        SourceRule(ruleStr: segment, mainMode: mMode, isJSON: isJSON)
                    )
                }
            }

            // JS segment: group 1 = <js>content</js>, group 2 = @js:content
            let group1 = match.range(at: 1)
            let group2 = match.range(at: 2)
            let jsCode: String
            if group1.location != NSNotFound {
                jsCode = nsRule.substring(with: group1)
            } else if group2.location != NSNotFound {
                jsCode = nsRule.substring(with: group2)
            } else {
                jsCode = ""
            }

            if !jsCode.isEmpty {
                ruleList.append(
                    SourceRule(ruleStr: jsCode, mainMode: .js, isJSON: isJSON)
                )
            }

            start = match.range.location + match.range.length
        }

        // Remaining text after the last JS match
        if nsRule.length > start {
            let segment = nsRule.substring(from: start)
                .trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty {
                ruleList.append(
                    SourceRule(ruleStr: segment, mainMode: mMode, isJSON: isJSON)
                )
            }
        }

        return ruleList
    }

    // MARK: - Variable System (matching Legado put/get chain)

    /// Store a variable. Writes to the first available context:
    /// chapter -> book -> ruleData -> source
    func put(key: String, value: String) {
        if let ch = chapter {
            ch.putVariable(key: key, value: value)
        } else if let bk = book {
            bk.putVariable(key: key, value: value)
        } else if let rd = ruleData {
            rd.putVariable(key: key, value: value)
        } else if let src = source {
            src.putVariable(key: key, value: value)
        }
    }

    /// Retrieve a variable from the chain until a non-empty value is found:
    /// chapter -> book -> ruleData -> source
    func get(key: String) -> String {
        if let v = chapter?.getVariable(key: key), !v.isEmpty { return v }
        if let v = book?.getVariable(key: key), !v.isEmpty { return v }
        if let v = ruleData?.getVariable(key: key), !v.isEmpty { return v }
        if let v = source?.getVariable(key: key), !v.isEmpty { return v }
        return ""
    }

    // MARK: - Legacy Compatibility API

    /// Extract a list (backward compatible with old engine API).
    /// Handles ||/&&/%% at the engine level and ## post-processing.
    func extractList(
        from content: String, rule: String, baseURL: String
    ) throws -> [String] {
        let (cleanedRule, shouldReverse) = preprocessListRule(rule)
        let (mainRule, regexParts) = splitRuleAndRegex(cleanedRule)
        let (opType, opParts) = RuleSyntaxParser.splitRuleByOperators(mainRule)

        if opParts.count > 1 {
            switch opType {
            case "||":
                for part in opParts {
                    let result = try extractList(
                        from: content, rule: part, baseURL: baseURL
                    )
                    if !result.isEmpty {
                        return shouldReverse ? result.reversed() : result
                    }
                }
                return []
            case "&&":
                let merged = try opParts.flatMap {
                    try extractList(from: content, rule: $0, baseURL: baseURL)
                }
                return shouldReverse ? merged.reversed() : merged
            case "%%":
                let lists = try opParts.map {
                    try extractList(from: content, rule: $0, baseURL: baseURL)
                }
                guard lists.allSatisfy({ !$0.isEmpty }) else { return [] }
                let interleaved = interleave(lists)
                return shouldReverse ? interleaved.reversed() : interleaved
            default:
                break
            }
        }

        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: cleanedRule)
        }) else {
            throw ModernRuleEngineError.unsupportedRule(cleanedRule)
        }
        let extracted = try extractor.extractList(
            from: content, rule: mainRule, baseURL: baseURL
        )
        let postProcessed = extracted
            .map {
                applyRegexParts(to: $0, parts: regexParts)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return shouldReverse ? postProcessed.reversed() : postProcessed
    }

    /// Extract a single value (backward compatible with old engine API).
    func extractValue(
        from content: String, rule: String, baseURL: String
    ) throws -> String {
        let cleanedRule = preprocess(rule)
        let (mainRule, regexParts) = splitRuleAndRegex(cleanedRule)
        let (opType, opParts) = RuleSyntaxParser.splitRuleByOperators(mainRule)

        if opParts.count > 1 {
            switch opType {
            case "&&":
                let pieces = try opParts.compactMap { part -> String? in
                    let value = try extractValue(
                        from: content, rule: part, baseURL: baseURL
                    )
                    return value.isEmpty ? nil : value
                }
                return pieces.joined(separator: "\n")
            case "||":
                for part in opParts {
                    let value = try extractValue(
                        from: content, rule: part, baseURL: baseURL
                    )
                    if !value.isEmpty { return value }
                }
                return ""
            default:
                break
            }
        }

        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: mainRule)
        }) else {
            throw ModernRuleEngineError.unsupportedRule(mainRule)
        }
        let extracted = try extractor.extractValue(
            from: content, rule: mainRule, baseURL: baseURL
        )
        let value: String
        if extracted.isEmpty && !regexParts.isEmpty {
            value = applyRegexParts(to: content, parts: regexParts)
        } else {
            value = applyRegexParts(to: extracted, parts: regexParts)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Rule Cache

    private func splitSourceRuleCached(_ ruleStr: String) -> [SourceRule] {
        if let cached = stringRuleCache.get(ruleStr) { return cached }
        let parsed = splitSourceRule(ruleStr)
        stringRuleCache.put(ruleStr, value: parsed)
        return parsed
    }

    // MARK: - Private: @put Processing

    /// Evaluate each value in the putMap as a rule, then store via put().
    private func putRule(_ map: [String: String]) {
        for (key, value) in map {
            put(key: key, value: getString(ruleStr: value))
        }
    }

    // MARK: - Private: JS Evaluation

    private func evalJS(_ jsStr: String, result: Any?) -> Any? {
        guard !jsStr.isEmpty else { return nil }
        return jsEvaluator?(jsStr, result)
    }

    private func evalJSToString(_ jsStr: String, result: Any?) -> String? {
        guard let value = evalJS(jsStr, result: result) else { return nil }
        if let str = value as? String { return str }
        return "\(value)"
    }

    // MARK: - Private: Mode-Qualified Rule

    /// Prepend a mode prefix so that the correct extractor canHandle matches.
    /// SourceRule strips prefixes during mode detection; this re-adds them
    /// when the bare rule text would not trigger the right extractor.
    private func modeQualifiedRule(mode: RuleMode, rule: String) -> String {
        switch mode {
        case .xpath:
            let l = rule.lowercased()
            if l.hasPrefix("@xpath:") || rule.hasPrefix("//") || rule.hasPrefix("/") {
                return rule
            }
            return "@xpath:" + rule
        case .json:
            let l = rule.lowercased()
            if l.hasPrefix("@json:") || rule.hasPrefix("$.") || rule.hasPrefix("$[") {
                return rule
            }
            return "@json:" + rule
        default:
            return rule
        }
    }

    // MARK: - Private: Extractor Routing

    private func extractStringViaExtractor(content: Any, rule: String) -> Any? {
        let contentStr = Self.toString(content)
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            return contentStr
        }
        return try? extractor.extractValue(
            from: contentStr, rule: rule, baseURL: baseUrl
        )
    }

    private func extractStringListViaExtractor(
        content: Any, rule: String
    ) -> Any? {
        let contentStr = Self.toString(content)
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            return [contentStr]
        }
        return try? extractor.extractList(
            from: contentStr, rule: rule, baseURL: baseUrl
        )
    }

    private func extractElementsViaExtractor(
        content: Any, rule: String
    ) -> Any? {
        let contentStr = Self.toString(content)
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            return [contentStr]
        }
        return try? extractor.extractList(
            from: contentStr, rule: rule, baseURL: baseUrl
        )
    }

    /// Regex-based element extraction (matching Legado AnalyzeByRegex.getElements).
    private func extractRegexElements(content: Any, rule: String) -> Any? {
        let contentStr = Self.toString(content)
        let parts = rule.components(separatedBy: "&&").filter { !$0.isEmpty }
        guard let pattern = parts.first, !pattern.isEmpty else {
            return [contentStr]
        }
        guard let regex = RegexCache.shared.regex(for: pattern) else {
            return [contentStr]
        }

        let nsContent = contentStr as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = regex.matches(in: contentStr, range: fullRange)
        guard !matches.isEmpty else { return [] as [Any] }

        return matches.map { match -> [String?] in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location != NSNotFound
                    ? nsContent.substring(with: range) : nil
            }
        }
    }

    // MARK: - Private: Regex Post-Processing

    private func replaceRegex(result: String, sourceRule: SourceRule) -> String {
        RegexReplacer.replaceRegex(
            result: result,
            pattern: sourceRule.replaceRegex,
            replacement: sourceRule.replacement,
            replaceFirst: sourceRule.replaceFirst
        )
    }

    // MARK: - Private: URL Resolution

    private func resolveURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("data:")
        {
            return trimmed
        }
        if let redirect = redirectUrl,
           let resolved = URL(string: trimmed, relativeTo: redirect)?
            .absoluteString
        {
            return resolved
        }
        if !baseUrl.isEmpty,
           let base = URL(string: baseUrl),
           let resolved = URL(string: trimmed, relativeTo: base)?.absoluteString
        {
            return resolved
        }
        return trimmed
    }

    // MARK: - Private: Utility

    /// Convert any value to String. Lists are joined with newline.
    static func toString(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let str = value as? String { return str }
        if let list = value as? [Any] {
            return list.map { toString($0) }.joined(separator: "\n")
        }
        return "\(value)"
    }

    private static func detectJSON(_ content: Any?) -> Bool {
        guard let str = content as? String else { return false }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    // MARK: - Private: Legacy Helpers

    private func preprocess(_ rawRule: String) -> String {
        var result = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("@@") {
            result = String(result.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func preprocessListRule(
        _ rawRule: String
    ) -> (rule: String, shouldReverse: Bool) {
        var cleaned = preprocess(rawRule)
        var shouldReverse = false
        if cleaned.hasPrefix("-") {
            shouldReverse = true
            cleaned = String(cleaned.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cleaned, shouldReverse)
    }

    private func interleave(_ lists: [[String]]) -> [String] {
        var result: [String] = []
        var index = 0
        while true {
            var appended = false
            for list in lists where index < list.count {
                result.append(list[index])
                appended = true
            }
            if !appended { break }
            index += 1
        }
        return result
    }

    private func splitRuleAndRegex(_ rule: String) -> (String, [String]) {
        let parts = rule.components(separatedBy: "##")
        let mainRule = parts.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let regexParts = Array(parts.dropFirst())
        return (mainRule, regexParts)
    }

    private func applyRegexParts(to text: String, parts: [String]) -> String {
        guard !parts.isEmpty else { return text }
        let pattern = parts[0]
        guard !pattern.isEmpty else { return text }
        let replacement = parts.count >= 2 ? parts[1] : ""
        return RegexCache.shared.replaceMatches(
            in: text, pattern: pattern, replacement: replacement
        ) ?? text
    }
}
