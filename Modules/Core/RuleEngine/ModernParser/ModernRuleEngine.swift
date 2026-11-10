import Foundation
import os
import SwiftSoup

/// What a rule's last jsoup step selected, on its way to a script. Legado's
/// `AnalyzeRule.getElement(s)` answers jsoup's `Elements` there whatever it holds, so scripts
/// read one that matched nothing unguarded: 八叉书库 (YCK1330) calls `.attr("href")` on
/// `java.getElement(…)` for a link its page may lack. A bare `[Any]` cannot say that once it is
/// empty, and an empty one reached the script as an array. `LegadoJsoupElement.bridged` makes
/// this a polyfill `Elements`.
struct JsoupSelection {
    let elements: [Any]
}

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

    private static let registry = OSAllocatedUnfairLock<[RuleExtractor]>(initialState: [
        CssExtractor(),
        XPathExtractor(),
        JsonExtractor(),
        JsoupDefaultExtractor(),
        RegexExtractor(),
        LegacyFallbackExtractor(),
    ])

    static func registerExtractor(_ extractor: RuleExtractor) {
        registry.withLock { $0.append(extractor) }
    }

    static func registerExtractor(_ extractor: RuleExtractor, at index: Int) {
        registry.withLock { registry in
            registry.insert(extractor, at: min(index, registry.count))
        }
    }

    static var registeredExtractors: [RuleExtractor] {
        registry.withLock { $0 }
    }

    static func setExtractors(_ extractors: [RuleExtractor]) {
        registry.withLock { $0 = extractors }
    }

    // MARK: - Instance Properties

    /// Content to parse (HTML string, JSON string, element, etc.)
    private(set) var content: Any?

    /// Base URL for resolving relative URLs
    private(set) var baseUrl: String = ""

    /// The response's URL, which relative links resolve against (Legado's `redirectUrl`). Kept
    /// as written, as Java's `URL(spec)` keeps it: a Foundation `URL` re-encodes every `%` of a
    /// component that also holds a raw character, so each page of a chain that resolves against
    /// it gets a new URL — 嬉皮漫画's TOC (YCK1329) walked `%7B` → `%257B` → `%25257B`… for
    /// 400+ pages, where Legado meets the same URL again on the next page and stops.
    private(set) var redirectUrl: String?

    /// The page the content came from: what the extractors read the document against. On a
    /// book's own pages `baseUrl` is the rule's URL, options and all (`setRedirectUrl`).
    private var pageURL: String { redirectUrl ?? baseUrl }

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

    /// Legado's `AnalyzeRule.setRedirectUrl`: a `data:` URL is no page to resolve links against,
    /// and neither is one Java's `URL(spec)` refuses for having no scheme; the one before stays.
    @discardableResult
    func setRedirectUrl(_ url: String) -> ModernRuleEngine {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.lowercased().hasPrefix("data:"), url.range(of: "://") != nil else { return self }
        self.redirectUrl = url
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
        let resultStr = evaluateString(ruleList: ruleList, mContent: mContent, read: isUrl ? .url : .text)
        return isUrl ? (resultStr.isEmpty ? baseUrl : resolveURL(resultStr)) : resultStr
    }

    /// How a default-mode (JSoup) step's values make the string the next step reads.
    private enum StringRead {
        /// `AnalyzeByJSoup.getString`: the values joined with "\n", or null when none matched.
        /// `AnalyzeRule.getString` skips every later step of a null (`result ?: continue`), so
        /// `a@href@js:…` runs no script for a row without a link.
        case text
        /// `getString0`, which an `isUrl` read uses: the first value, or "" when none matched —
        /// a later script still runs.
        case url
        /// A link Legado reads with plain `getString` (a cover, a chapter's URL): null when none
        /// matched, as `text`. When several matched, the first, as `url`: joined, they are no
        /// URL at all (maintainer approved, 2026-10-20).
        case link
    }

    /// Legado's `AnalyzeRule.getString` without the `isUrl` page fallback; `read` is how a
    /// default-mode (JSoup) step's values become one string. Legado, MD3 and Sigma agree.
    private func evaluateString(ruleList: [SourceRule], mContent: Any?, read: StringRead) -> String {
        let content = mContent ?? self.content
        guard content != nil, !ruleList.isEmpty else { return "" }

        let t0 = debugObserver != nil ? Date() : Date.distantPast

        if let obs = debugObserver {
            let segs = ruleList.enumerated().map { i, sr in
                RuleDebugEvent.RuleSegmentInfo(
                    index: i, mode: "\(sr.mode)", rule: sr.rule, replacePattern: sr.replaceRegex
                )
            }
            obs(.rulesParsed(ruleStr: ruleList.first.map { $0.rule } ?? "", segments: segs))
        }

        var result: Any? = content
        // Whether `result` is a string an earlier step made: every JSONPath, XPath, JSoup or
        // regex step, and every replace, answers a `String` in Legado's `getString`, which a
        // later script reads as a plain string (`JSCoreEngine.ScriptString`). The content
        // the chain starts from, and what a script returned, keep their own shape.
        var resultIsStepString = false
        for (idx, parsedRule) in ruleList.enumerated() {
            var sourceRule = parsedRule
            putRule(sourceRule.putMap)
            let scriptInput: Any? = resultIsStepString
                ? (result as? String).map { JSCoreEngine.ScriptString($0) } ?? result
                : result
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: scriptInput) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard result != nil else { continue }
            if sourceRule.shouldPerformExtraction {
                result = applyStringExtraction(
                    sourceRule, result: result, scriptInput: scriptInput, idx: idx, read: read)
                resultIsStepString = sourceRule.mode != .js
            }
            if result != nil, !sourceRule.replaceRegex.isEmpty {
                result = applyStringReplace(sourceRule, result: result, idx: idx)
                resultIsStepString = true
            }
        }

        let resultStr = result == nil ? "" : Self.toString(result)
        if let obs = debugObserver {
            obs(.finalResult(value: resultStr, elapsedMs: Date().timeIntervalSince(t0) * 1000))
        }
        return resultStr
    }

    /// A link that exists only when the rule yields one: the rule's text resolved against
    /// the page, or an empty string. Legado reads covers this way in `BookList` and
    /// `BookInfo` — `getString(rule)`, then `getAbsoluteURL` when it is not empty — and
    /// Sigma reads RSS article images the same way; never with `isUrl`, whose blank result
    /// falls back to the page's own URL. That fallback
    /// suits a link the parse has to follow (a book, its contents); as a cover it made the
    /// app download the page itself as an image — for a search, the search request again.
    /// Unlike Legado, a rule that matches several links keeps the first, as an `isUrl` read
    /// does: Legado's `getString` joins them with "\n", which is no URL at all (maintainer
    /// approved, 2026-10-20).
    func getOptionalURL(ruleStr: String?) -> String {
        guard let ruleStr, !ruleStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let value = evaluateString(
            ruleList: splitSourceRuleCached(ruleStr), mContent: nil, read: .link)
        return value.isEmpty ? "" : resolveURL(value)
    }

    /// A chapter's link as Legado's `BookChapterList` reads it: `getString(urlRule)`, not an
    /// `isUrl` read (legado-E, MD3 and upstream agree), so a row whose link step matches nothing
    /// runs no script after it; a blank link is the TOC page (`bookChapter.url = baseUrl`).
    /// 英语阅读 (YCK1330/1331) has `a@href@js:if(result!=null){…tingroom…}else{result=baseUrl}`
    /// on an article page whose only row has no link: reading it as a URL handed the script ""
    /// and made every such chapter `http://m.tingroom.com/`.
    func getChapterURL(ruleStr: String?) -> String {
        guard let ruleStr, !ruleStr.isEmpty else { return baseUrl }
        let value = evaluateString(
            ruleList: splitSourceRuleCached(ruleStr), mContent: nil, read: .link)
        return value.isEmpty ? baseUrl : resolveURL(value)
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
        let content = mContent ?? self.content
        guard content != nil, !ruleList.isEmpty else { return [] }

        let t0 = debugObserver != nil ? Date() : Date.distantPast

        var result: Any? = content
        for (idx, parsedRule) in ruleList.enumerated() {
            var sourceRule = parsedRule
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: result) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard result != nil else { continue }
            if !sourceRule.rule.isEmpty {
                result = applyListExtraction(sourceRule, result: result, idx: idx)
            }
            if !sourceRule.replaceRegex.isEmpty {
                result = applyListReplace(sourceRule, result: result, idx: idx)
            }
        }

        guard let finalResult = result else { return [] }
        // JavaScriptCore crosses native JS arrays back to Swift as a JSON string,
        // while Android Legado's AnalyzeRule keeps them as a List. Normalize that
        // bridge representation before converting the final list to strings.
        let normalizedFinalResult = Self.rehydrateJSListResult(finalResult) ?? finalResult

        var stringList: [String]
        if let str = normalizedFinalResult as? String {
            stringList = str.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else if let list = normalizedFinalResult as? [Any] {
            stringList = list.map { Self.toString($0) }.filter { !$0.isEmpty }
        } else {
            let str = Self.toString(normalizedFinalResult)
            stringList = str.isEmpty ? [] : [str]
        }

        if let obs = debugObserver {
            obs(.finalResultList(values: stringList, elapsedMs: Date().timeIntervalSince(t0) * 1000))
        }

        guard isUrl else { return stringList }
        // A set beside the list: a rule that matched page text instead of links can yield
        // thousands of lines, and `urlList.contains` made deduplicating them quadratic.
        var urlList: [String] = []
        var seen: Set<String> = []
        for item in stringList {
            let absoluteURL = resolveURL(item)
            if !absoluteURL.isEmpty, seen.insert(absoluteURL).inserted {
                urlList.append(absoluteURL)
            }
        }
        return urlList
    }

    // MARK: - getElements (matching Legado AnalyzeRule.getElements)

    /// Get elements (for list rules like book list, chapter list).
    /// Uses allInOne = true when splitting (leading : forces regex mode).
    func getElements(ruleStr: String) -> [Any] {
        evaluateElements(ruleStr: ruleStr).list
    }

    private func evaluateElements(ruleStr: String) -> (list: [Any], selectedByJsoup: Bool) {
        guard !ruleStr.isEmpty else { return ([], false) }

        // Legado list-reverse marker: a leading `-` reverses the matched list
        // (chapter lists are commonly stored newest-first, e.g. `-class.detail-list@a`).
        // Strip it before extraction — otherwise `-class.detail-list` is handed to
        // the extractor as an invalid CSS selector and matches nothing — then
        // reverse the final result. Mirrors `preprocessListRule` used by `extractList`.
        var effectiveRule = ruleStr
        var shouldReverse = false
        let trimmedRule = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRule.hasPrefix("-"), !trimmedRule.hasPrefix("--") {
            shouldReverse = true
            effectiveRule = String(trimmedRule.dropFirst())
        }
        // Legado's BookList / BookChapterList drop a `+` after the `-` (an explicit "keep the
        // order"). Left on, the `+` of `+<js>…` became a selector step of its own and the
        // script's `result` was that step's elements, not the page: po18城's TOC failed with
        // `result.replace is not a function` (YCK1330 11-06 §4).
        if effectiveRule.hasPrefix("+") {
            effectiveRule = String(effectiveRule.dropFirst())
        }

        var result: Any? = nil
        let content = self.content
        let ruleList = splitSourceRule(effectiveRule, allInOne: true)
        guard content != nil, !ruleList.isEmpty else { return ([], false) }

        result = content
        var selectedByJsoup = false
        // Legado's `AnalyzeRule.getElements` runs each segment's rule as it was written: no
        // `makeUpRule`, so no `{{…}}` / `@get:` substitution and no `##` replacement (legado-E,
        // MD3 and upstream agree). 吾爱耽美 (YCK1330) lists with an `@js:` that tests
        // `baseUrl.match(/##/)`; split at `##`, the script ended inside the regex literal.
        for (ruleIndex, sourceRule) in ruleList.enumerated() {
            putRule(sourceRule.putMap)
            guard result != nil else { continue }

            let rule = sourceRule.rule
            selectedByJsoup = selectsWithJsoup(mode: sourceRule.mode, rule: rule)
            switch sourceRule.mode {
            case .js:
                // JS list rules (e.g. chapterList `@js:...reduce(...)`) return an array of
                // objects, but the JS bridge serialises arrays/objects to a JSON string.
                // Re-hydrate that JSON array back into `[Any]` so each item becomes one element
                // (matching the JSONPath path); otherwise the whole list collapses to a single
                // string element and every field rule resolves empty → 0 chapters.
                //
                // Only as the list's last step. Before another step the value goes on as the
                // script gave it, as in Legado (`AnalyzeRule.getElements`): `JSON.stringify(list)`
                // is text the next JSONPath step reads into objects — `LinkedHashMap`s, which a
                // script reads as `{id=1, …}`. 猫耳 (YCK1331) lists with
                // `<js>…JSON.stringify(list)</js>$.[*]` and takes each item's id with
                // `String(result).match(/id=(\d+)/)`; split here, the items stayed JSON text.
                let value = evalJS(rule, result: result)
                result = ruleIndex == ruleList.count - 1 ? Self.rehydrateJSListResult(value) : value
            case .regex:
                result = extractRegexElements(content: result!, rule: rule)
            case .json, .xpath, .default:
                result = extractElementsWithOperators(
                    content: result!, mode: sourceRule.mode, rule: rule
                )
            }
        }

        if let list = result as? [Any] { return (shouldReverse ? list.reversed() : list, selectedByJsoup) }
        if let result = result { return ([result], false) }
        return ([], false)
    }

    // MARK: - getElement (matching Legado AnalyzeRule.getElement)

    /// Legado's `AnalyzeRule.getElement` (legado-E, MD3 and upstream's `AnalyzeRuleCore` agree):
    /// what the rule selects, kept as the parser's own value instead of read into text. A jsoup
    /// rule yields its selected elements (`Elements`), a JSONPath rule the object or list it
    /// reads, a regex rule the first match's groups, a JS step whatever the script returns; a
    /// `##` replacement turns the value into the replaced text. `ruleBookInfo.init` sets its
    /// result as the content the detail fields read, and source JS calls it as
    /// `java.getElement(rule)`.
    func getElement(ruleStr: String) -> Any? {
        evaluateElement(ruleStr: ruleStr).value
    }

    /// `getElement` as `java.getElement(rule)` hands it to a script: what a last jsoup step
    /// selected comes back as a `JsoupSelection`.
    func scriptElement(ruleStr: String) -> Any? {
        let (value, selectedByJsoup) = evaluateElement(ruleStr: ruleStr)
        return selectedByJsoup ? JsoupSelection(elements: value as? [Any] ?? []) : value
    }

    /// `getElements` as `java.getElements(rule)` hands it to a script: what a last jsoup step
    /// selected comes back as a `JsoupSelection`.
    func scriptElements(ruleStr: String) -> Any {
        let (list, selectedByJsoup) = evaluateElements(ruleStr: ruleStr)
        return selectedByJsoup ? JsoupSelection(elements: list) : list
    }

    /// Whether a step selects with jsoup (Legado's `AnalyzeByJSoup.getElements`, which answers
    /// jsoup's `Elements`, an empty one for an empty rule): a default-mode rule, unless it reads
    /// JSON content by JSONPath — the test `extractElementsWithOperators` makes.
    private func selectsWithJsoup(mode: RuleMode, rule: String) -> Bool {
        guard mode == .default else { return false }
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isJSON || trimmedRule.lowercased().hasPrefix("@css:")
    }

    private func evaluateElement(ruleStr: String) -> (value: Any?, selectedByJsoup: Bool) {
        guard !ruleStr.isEmpty, let content else { return (nil, false) }
        let ruleList = splitSourceRule(ruleStr, allInOne: true)
        guard !ruleList.isEmpty else { return (nil, false) }

        var result: Any? = content
        var selectedByJsoup = false
        for parsedRule in ruleList {
            var sourceRule = parsedRule
            putRule(sourceRule.putMap)
            sourceRule.makeUpRule(
                result: result,
                getData: { self.get(key: $0) },
                evalJS: { self.evalJSToString($0, result: result) },
                analyzeRule: { self.getString(ruleStr: $0) }
            )
            guard let current = result else { continue }
            let rule = sourceRule.rule
            selectedByJsoup = selectsWithJsoup(mode: sourceRule.mode, rule: rule)
            switch sourceRule.mode {
            case .regex:
                result = firstRegexMatchGroups(content: current, rule: rule)
            case .js:
                result = evalJS(rule, result: current)
            case .json:
                result = JsonExtractor().extractRawObject(json: JsonExtractor.document(current), rule: rule)
            case .xpath, .default:
                // An empty rule — an `init` that only `@put`s — selects nothing: Legado's
                // `AnalyzeByJSoup.getElements("")` is an empty `Elements`, whose string (and
                // so its `isJson()`, which `setContent` reads) is "". An empty `[Any]` would
                // read as JSON.
                result = rule.isEmpty
                    ? ""
                    : extractElementsWithOperators(content: current, mode: sourceRule.mode, rule: rule)
            }
            if !sourceRule.replaceRegex.isEmpty, result != nil {
                result = replaceRegex(result: Self.toString(result), sourceRule: sourceRule)
                selectedByJsoup = false
            }
        }
        return (result, selectedByJsoup && result != nil)
    }

    /// Legado's `AnalyzeByRegex.getElement`: the first match's groups, nil without a match.
    /// An unmatched group is "" here too; Legado's `getElement` reads it with `group(i)!!`
    /// (AnalyzeByRegex.kt:20) and throws a NullPointerException, a crash this does not copy.
    private func firstRegexMatchGroups(content: Any, rule: String) -> [String?]? {
        guard let groups = extractRegexElements(content: content, rule: rule) as? [[String?]] else {
            return nil
        }
        return groups.first
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
                ).trimmingCharacters(in: .whitespacesAndNewlines)
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

        if !opType.isEmpty {
            var lists: [[String]] = []
            for part in opParts {
                let list = try extractList(from: content, rule: part, baseURL: baseURL)
                guard !list.isEmpty else { continue }
                lists.append(list)
                if opType == "||" { break }
            }
            let merged = opType == "%%"
                ? RuleSyntaxParser.interleaveByFirst(lists) : lists.flatMap { $0 }
            return shouldReverse ? merged.reversed() : merged
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
        let (opType, opParts) = RuleSyntaxParser.splitRuleByOperators(
            mainRule, operators: ["&&", "||"])

        if !opType.isEmpty {
            var texts: [String] = []
            for part in opParts {
                let value = try extractValue(from: content, rule: part, baseURL: baseURL)
                guard !value.isEmpty else { continue }
                texts.append(value)
                if opType == "||" { break }
            }
            return texts.joined(separator: "\n")
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

    /// JS list rules return an array, but the JS bridge serialises arrays to a JSON string.
    /// If `value` is a JSON-array string, parse it back into `[Any]` so `getElements` yields one
    /// element per item; otherwise pass the value through unchanged.
    private static func rehydrateJSListResult(_ value: Any?) -> Any? {
        guard let str = value as? String else { return value }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let array = OrderedJSON.parse(trimmed) as? [Any]
        else { return value }
        // Each object item is written back as JSON text, its keys in the order the script
        // produced them. This was written when JSONPath elements were JSON strings and
        // detectJSON accepted only strings, so a raw dict set as content made every field
        // rule (chapterName/chapterUrl) resolve empty. Neither holds any more: since 28808ca3
        // JSONPath elements are the parsed objects, and detectJSON treats a dictionary or
        // array as JSON. The strings are kept because a script's item reads as its JSON text
        // (`String(result)`), which the parsed object, read as a `LinkedHashMap`, would not.
        return array.map { item -> Any in
            if let s = item as? String { return s }
            return OrderedJSON.jsonText(item) ?? Self.toString(item)
        }
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
            // Only `@xpath:` and `//` are XPath to every extractor's `canHandle`; a rule with
            // one leading `/` (`/a/@href`, `/text()`) was left bare and JsoupDefaultExtractor
            // claimed it for its `@href`.
            let l = rule.lowercased()
            if l.hasPrefix("@xpath:") || rule.hasPrefix("//") {
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
            // Legado allows a bare JSON field name (for example `bid` or
            // `ChapterName`) after a JSON list element. The element is already
            // known to be JSON, so route that field through JsonExtractor before
            // falling back to the HTML/JSoup extractor. Without this, numeric
            // fields especially become an empty string and `isUrl` silently
            // falls back to the page URL.
            if isJSON {
                let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                let looksLikeHTMLSelector = lower.hasPrefix("@css:")
                    || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix(".")
                    || trimmed.hasPrefix("[")
                    || lower.hasPrefix("class.")
                    || lower.hasPrefix("id.")
                    || lower.hasPrefix("tag.")
                    || lower.hasPrefix("text.")
                    || lower.hasPrefix("children")
                if !trimmed.isEmpty, !looksLikeHTMLSelector {
                    return "@json:" + rule
                }
            }
            return rule
        }
    }

    // MARK: - Private: Segment Processing

    /// Mode-specific extraction step for a single-string pipeline.
    /// `scriptInput` is `result` as a script step reads it (`evaluateString`).
    private func applyStringExtraction(
        _ sourceRule: SourceRule, result: Any?, scriptInput: Any?, idx: Int, read: StringRead
    ) -> Any? {
        let rule = sourceRule.rule
        // Serializing the content (an Element's outerHtml / a whole page) is
        // expensive; only pay it when a debug observer is actually attached.
        let inputPreview = debugObserver != nil
            ? String(Self.toString(result).prefix(200))
            : ""
        switch sourceRule.mode {
        case .js:
            debugObserver?(.beforeExtract(
                segmentIndex: idx, mode: "js",
                qualifiedRule: String(rule.prefix(80)), inputPreview: inputPreview
            ))
            let jsResult = evalJS(rule, result: scriptInput)
            debugObserver?(.jsExecuted(
                segmentIndex: idx, script: String(rule.prefix(300)),
                inputPreview: inputPreview, result: Self.toString(jsResult)
            ))
            return jsResult
        case .regex:
            return rule
        case .json, .xpath, .default:
            let qualified = modeQualifiedRule(mode: sourceRule.mode, rule: rule)
            debugObserver?(.beforeExtract(
                segmentIndex: idx, mode: "\(sourceRule.mode)",
                qualifiedRule: qualified, inputPreview: inputPreview
            ))
            let extracted = extractStringWithOperators(
                content: result!, mode: sourceRule.mode, rule: rule, read: read)
            debugObserver?(.afterExtractValue(segmentIndex: idx, result: Self.toString(extracted)))
            return extracted
        }
    }

    /// String-value extraction. A default-mode rule — JSoup syntax or a CSS selector, both
    /// `AnalyzeByJSoup` in Legado — reads the same values as `getStringList`, operators
    /// (`||`/`&&`/`%%`) included, then makes them one string as `read` says (`StringRead`).
    /// Taking the first value for every field cut a content rule such as
    /// `class.content@tag.p@text` down to its first paragraph.
    private func extractStringWithOperators(
        content: Any, mode: RuleMode, rule: String, read: StringRead
    ) -> Any? {
        let qualified = modeQualifiedRule(mode: mode, rule: rule)
        let extractor = extractors.first { $0.canHandle(rule: qualified) }
        if extractor is JsoupDefaultExtractor || extractor is CssExtractor {
            guard let values = extractStringListViaExtractor(content: content, rule: qualified)
                as? [String] else { return nil }
            switch read {
            case .text: return values.isEmpty ? nil : values.joined(separator: "\n")
            case .url: return values.first ?? ""
            case .link: return values.first
            }
        }
        return extractStringViaExtractor(content: content, rule: qualified)
    }

    /// Regex replace post-processing step for a single-string pipeline.
    private func applyStringReplace(_ sourceRule: SourceRule, result: Any?, idx: Int) -> String {
        let before = Self.toString(result)
        let after = replaceRegex(result: before, sourceRule: sourceRule)
        debugObserver?(.regexApplied(
            segmentIndex: idx, pattern: sourceRule.replaceRegex,
            replacement: sourceRule.replacement, before: before, after: after
        ))
        return after
    }

    /// Mode-specific extraction step for a string-list pipeline.
    private func applyListExtraction(_ sourceRule: SourceRule, result: Any?, idx: Int) -> Any? {
        let rule = sourceRule.rule
        // Serializing the content (an Element's outerHtml / a whole page) is
        // expensive; only pay it when a debug observer is actually attached.
        let inputPreview = debugObserver != nil
            ? String(Self.toString(result).prefix(200))
            : ""
        switch sourceRule.mode {
        case .js:
            debugObserver?(.beforeExtract(
                segmentIndex: idx, mode: "js",
                qualifiedRule: String(rule.prefix(80)), inputPreview: inputPreview
            ))
            let jsResult = evalJS(rule, result: result)
            debugObserver?(.jsExecuted(
                segmentIndex: idx, script: String(rule.prefix(300)),
                inputPreview: inputPreview, result: Self.toString(jsResult)
            ))
            return jsResult
        case .regex:
            return rule
        case .json, .xpath, .default:
            let qualified = modeQualifiedRule(mode: sourceRule.mode, rule: rule)
            debugObserver?(.beforeExtract(
                segmentIndex: idx, mode: "\(sourceRule.mode)",
                qualifiedRule: qualified, inputPreview: inputPreview
            ))
            let extracted = extractStringListViaExtractor(content: result!, rule: qualified)
            let items = (extracted as? [Any])?.map { Self.toString($0) } ?? []
            debugObserver?(.afterExtractList(
                segmentIndex: idx, count: items.count, items: Array(items.prefix(10))
            ))
            return extracted
        }
    }

    /// Regex replace post-processing step for a string-list pipeline.
    /// Applies replacement element-wise when result is a list, or as a scalar otherwise.
    private func applyListReplace(_ sourceRule: SourceRule, result: Any?, idx: Int) -> Any? {
        if let list = result as? [Any] {
            let before = list.map { Self.toString($0) }
            let after: [Any] = before.map { replaceRegex(result: $0, sourceRule: sourceRule) }
            if let obs = debugObserver, let firstBefore = before.first,
               let firstAfter = after.first as? String {
                obs(.regexApplied(
                    segmentIndex: idx, pattern: sourceRule.replaceRegex,
                    replacement: sourceRule.replacement,
                    before: firstBefore, after: firstAfter
                ))
            }
            return after
        } else if result != nil {
            let before = Self.toString(result)
            let after = replaceRegex(result: before, sourceRule: sourceRule)
            debugObserver?(.regexApplied(
                segmentIndex: idx, pattern: sourceRule.replaceRegex,
                replacement: sourceRule.replacement, before: before, after: after
            ))
            return after
        }
        return result
    }

    // MARK: - Private: Extractor Routing

    private func extractStringViaExtractor(content: Any, rule: String) -> Any? {
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            let contentStr = Self.toString(content)
            return contentStr
        }
        // A list item is the context of an XPath field rule (`XPathExtractor.extractValue(fromItem:)`).
        if let node = content as? RuleHTMLElement, let xpath = extractor as? XPathExtractor {
            return xpath.extractValue(fromItem: node, rule: rule, baseURL: pageURL)
        }
        if let json = extractor as? JsonExtractor {
            return json.extractValue(json: JsonExtractor.document(content), rule: rule)
        }
        return try? extractor.extractValue(
            from: Self.toString(content), rule: rule, baseURL: pageURL
        )
    }

    private func extractStringListViaExtractor(
        content: Any, rule: String
    ) -> Any? {
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            let contentStr = Self.toString(content)
            return [contentStr]
        }
        do {
            // An element an earlier step selected is read as the element, as Legado's
            // `AnalyzeByJSoup(element)` does; see `RuleHTMLElement`.
            // `AnalyzeByJSoup.getStringList` reads both modes: `extractValueList` takes an
            // `@CSS:` rule's pieces as CSS and splits `&&` / `||` / `%%` for either.
            let readsJsoup = extractor is JsoupDefaultExtractor || extractor is CssExtractor
            if let node = content as? RuleHTMLElement {
                if readsJsoup {
                    return try JsoupDefaultExtractor()
                        .extractValueList(from: node.element, rule: rule, baseURL: pageURL)
                }
                if let xpath = extractor as? XPathExtractor {
                    return xpath.extractList(fromItem: node, rule: rule, baseURL: pageURL)
                }
            }
            if let json = extractor as? JsonExtractor {
                return json.extractList(json: JsonExtractor.document(content), rule: rule)
            }
            let contentStr = Self.toString(content)
            // A string list reads its last `@` step as a value, as Legado's does; the
            // extractor's `extractList` also serves `getElements` and cannot tell.
            if readsJsoup {
                return try JsoupDefaultExtractor()
                    .extractValueList(from: contentStr, rule: rule, baseURL: pageURL)
            }
            return try extractor.extractList(from: contentStr, rule: rule, baseURL: pageURL)
        } catch {
            AppLogger.parse("getStringList extraction failed", context: [
                "rule": String(rule.prefix(120)),
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// Element extraction that honors Legado's list operators (`||`/`&&`/`%%`) BEFORE picking an
    /// extractor. `getElements` previously fed the whole combined rule straight to one extractor,
    /// so a JSON list rule like `$.data.records||$.data.list||$.Data.ServerCase.BookInfo[*]` was
    /// handed to the JSON extractor as a single (invalid) JSONPath → 0 elements → empty 发现页
    /// (企点). This keeps RAW (non-stringified) elements so per-field `$.bName` rules still
    /// resolve against each record object.
    ///
    /// Each piece is read the way Legado's reader for it reads one: the JSONPath and XPath
    /// readers (`getList`, `getElements`) read a piece by calling themselves, so it splits again
    /// (哔哩哔哩's `A&&B&&C||D` reads `C||D` as C or else D) and an empty piece is left out of the
    /// merge; jsoup's `getElements` selects each piece as it stands and keeps an empty one, so
    /// under `%%` an empty first piece merges to nothing.
    private func extractElementsWithOperators(
        content: Any, mode: RuleMode, rule: String
    ) -> Any? {
        // Legado's `@CSS:` covers every piece of the rule (`AnalyzeByJSoup.getElements` selects
        // each with `select`), so the pieces after the first keep it too.
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let cssPrefix = trimmedRule.lowercased().hasPrefix("@css:") ? String(trimmedRule.prefix(5)) : ""
        // Legado's `SourceRule` reads a rule on JSON content as JSONPath unless it says `@CSS:`.
        let readsByPiece = mode == .json || mode == .xpath || (mode == .default && isJSON && cssPrefix.isEmpty)
        let (opType, opParts) = RuleSyntaxParser.splitRuleByOperators(
            cssPrefix.isEmpty ? rule : String(trimmedRule.dropFirst(5)),
            code: readsByPiece && mode != .xpath)
        if !opType.isEmpty {
            var lists: [[Any]] = []
            for part in opParts {
                let list: [Any]
                if readsByPiece {
                    list = extractElementsWithOperators(content: content, mode: mode, rule: part) as? [Any] ?? []
                    guard !list.isEmpty else { continue }
                } else {
                    let piece = part.lowercased().hasPrefix("@css:") ? part : cssPrefix + part
                    let qualified = modeQualifiedRule(mode: mode, rule: piece)
                    list = extractElementsViaExtractor(content: content, rule: qualified) as? [Any] ?? []
                }
                lists.append(list)
                if opType == "||", !list.isEmpty { break }
            }
            return opType == "%%" ? RuleSyntaxParser.interleaveByFirst(lists) : lists.flatMap { $0 }
        }
        let qualified = modeQualifiedRule(mode: mode, rule: rule)
        return extractElementsViaExtractor(content: content, rule: qualified)
    }

    private func extractElementsViaExtractor(
        content: Any, rule: String
    ) -> Any? {
        guard let extractor = extractors.first(where: {
            $0.canHandle(rule: rule)
        }) else {
            let contentStr = Self.toString(content)
            return [contentStr]
        }
        if extractor is CssExtractor || extractor is JsoupDefaultExtractor {
            return extractJsoupElements(content: content, rule: rule, extractor: extractor)
        }
        if let xpath = extractor as? XPathExtractor {
            return xpath.extractElements(from: content, rule: rule, baseURL: pageURL)
        }
        if let jsonExt = extractor as? JsonExtractor {
            return jsonExt.extractRawElements(json: JsonExtractor.document(content), rule: rule)
        }

        do {
            return try extractor.extractList(from: Self.toString(content), rule: rule, baseURL: pageURL)
        } catch {
            AppLogger.parse("getElements extraction failed", context: [
                "rule": String(rule.prefix(120)),
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// `AnalyzeByJSoup(content).getElements(rule)`: the selected elements themselves, each
    /// carried to the next rule as a `RuleHTMLElement` — Legado keeps the `Element`. A rule that
    /// ends in an accessor (`a@href`) lists its values instead. `content` is used as the root
    /// when it is an element; anything else is parsed, as Legado parses it.
    private func extractJsoupElements(content: Any, rule: String, extractor: RuleExtractor) -> Any? {
        do {
            let root: Element
            if let node = content as? RuleHTMLElement {
                root = node.element
            } else {
                // CssExtractor parses with an empty base, JsoupDefaultExtractor with the page's;
                // each keeps the base it reads values with.
                let base = extractor is CssExtractor ? "" : pageURL
                root = try JsoupDocumentCache.current.document(
                    for: Self.toString(content).truncatedForSwiftSoup(), baseURL: base)
            }
            let selected: [Element]?
            if let css = extractor as? CssExtractor {
                selected = try css.extractElements(from: root, rule: rule)
                if selected == nil {
                    return try css.extractList(from: root, rule: rule, baseURL: pageURL)
                }
            } else if let jsoup = extractor as? JsoupDefaultExtractor {
                selected = try jsoup.extractElements(from: root, rule: rule)
                if selected == nil {
                    return try jsoup.extractList(from: root, rule: rule, baseURL: pageURL)
                }
            } else {
                selected = nil
            }
            return (selected ?? []).map { RuleHTMLElement($0) }
        } catch {
            AppLogger.parse("getElements extraction failed", context: [
                "rule": String(rule.prefix(120)),
                "error": error.localizedDescription
            ])
            return nil
        }
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

        // A group its alternation branch left unmatched is "", as `resM.group(i) ?: ""`
        // (AnalyzeByRegex.kt:47; Java answers null, oracle `regex-unmatched-group.json`).
        // As nil, `$N` wrote its own text: 若夏书网's `$2$3` titled every free chapter
        // "$2第一章…", and 起点中文's 卷 rows got the URL `book/$1`.
        return matches.map { match -> [String?] in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location != NSNotFound
                    ? nsContent.substring(with: range) : ""
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

    /// Legado's `NetworkUtils.getAbsoluteURL` (legado-E, MD3 and Sigma agree): absolute and
    /// data URLs as they are, a `javascript…` link as nothing, anything else joined to the
    /// page. A link's `,{…}` options are split off before the join and put back after it, as
    /// Legado's `BookChapter.getAbsoluteURL` does. Java's `URL` leaves them where they are;
    /// `URL(string:relativeTo:)` percent-encodes them into the path, so a chapter or next page
    /// written `/p2,{"method":"POST"}` reached AnalyzeUrl without its options.
    private func resolveURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("data:")
        {
            return trimmed
        }
        if trimmed.hasPrefix("javascript") { return "" }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = AnalyzeUrl.paramPattern.firstMatch(in: trimmed, range: range),
              let options = Range(match.range, in: trimmed),
              options.lowerBound > trimmed.startIndex
        else {
            return joinToPage(trimmed)
        }
        return joinToPage(String(trimmed[..<options.lowerBound]))
            + "," + trimmed[options.upperBound...]
    }

    /// Java's `URL(base, spec)` (`AnalyzeUrl.javaAbsoluteURL`): the link keeps its characters,
    /// so a `charset` option on it still encodes them when it is fetched.
    private func joinToPage(_ trimmed: String) -> String {
        if let redirect = redirectUrl,
           let resolved = AnalyzeUrl.javaAbsoluteURL(trimmed, base: redirect) {
            return resolved
        }
        if !baseUrl.isEmpty, let resolved = AnalyzeUrl.javaAbsoluteURL(trimmed, base: baseUrl) {
            return resolved
        }
        return trimmed
    }

    // MARK: - Private: Utility

    /// Convert any value to String. Lists are joined with newline. A JSON object (JSONPath
    /// elements are the parsed `JSONSerialization` objects) prints as Legado's content does,
    /// `content.toString()` of the `LinkedHashMap` jayway read — `{id=12, name=…}`, keys in
    /// document order (`OrderedJSON.javaText`) — so `##` replaces and regex rules written
    /// for Legado match the element. Never Foundation's plist description, which escapes CJK
    /// as `\U6597…`.
    static func toString(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let str = value as? String { return str }
        if let str = value as? JSCoreEngine.ScriptString { return str.value }
        if let element = value as? RuleHTMLElement { return element.outerHTML }
        if let list = value as? [Any] {
            return list.map { toString($0) }.joined(separator: "\n")
        }
        if value is NSDictionary {
            return OrderedJSON.javaText(value)
        }
        return "\(value)"
    }

    private static func detectJSON(_ content: Any?) -> Bool {
        // Already-parsed JSON (a dictionary/array) IS JSON. This matters when an upstream
        // step set the content to a parsed object — e.g. ruleBookInfo.init runs
        // `<js>…</js>$.Data` and parseBookInfo stores the result as `[String: Any]`. Without
        // this, isJSON would be false and field rules WITHOUT an explicit `$.` prefix
        // (e.g. 起点's tocUrl step `.BaseBookInfo.BookId`, name `BaseBookInfo.BookName`)
        // would fall back to .default (CSS) mode and resolve empty → empty tocUrl → empty TOC.
        // Selected elements are not: Legado decides with `content.toString().isJson()`, and a
        // jsoup `Elements`' string is its outer HTML. An init like `class.info` hands the detail
        // fields such a list; read as JSON, every CSS field rule came back empty.
        if let list = content as? [Any], !list.isEmpty, list.allSatisfy({ $0 is RuleHTMLElement }) {
            return false
        }
        if content is [String: Any] || content is [Any] { return true }
        if content is NSDictionary || content is NSArray { return true }
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
        // `getElements`'s `+`, for the same list rules.
        if cleaned.hasPrefix("+") {
            cleaned = String(cleaned.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cleaned, shouldReverse)
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
