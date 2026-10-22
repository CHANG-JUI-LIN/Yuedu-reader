import CryptoKit
import Foundation

/// One page of a module's list, as read from its site or from the entry's cache.
struct RuleModulePage: Codable, Equatable, Sendable {
    var items: [RuleListItem]
    var fetchedAt: Date
}

extension RuleModule.Entry {
    /// Its pages are counted (`page`, from 1) or offset (`offset`, from 0); nil when it has one page.
    var paging: RuleModule.ParamType? {
        if params.contains(where: { $0.kind == .page }) { return .page }
        if params.contains(where: { $0.kind == .offset }) { return .offset }
        return nil
    }

    /// Where the first page starts: the paging parameter's `value` (format 3.0; なろう counts
    /// its items from 1), else page 1, offset 0.
    var firstPosition: Int {
        if let start = params.first(where: { $0.kind == .page || $0.kind == .offset })?.value.flatMap({ Int($0) }) {
            return start
        }
        return paging == .page ? 1 : 0
    }

    /// Where the page after the one at `position` starts; nil after the last.
    func position(after position: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        switch paging {
        case .page: return position + 1
        case .offset: return position + itemCount
        default: return nil
        }
    }

    /// Every template's value: each parameter's default (an enumeration's first option when
    /// it has none, the option in `language` when it follows it), the reader's own for this
    /// section, then the page's position.
    func values(_ parameters: [String: String], position: Int, keyword: String? = nil, language: String?) -> [String: String] {
        var values: [String: String] = [:]
        for param in params {
            switch param.kind {
            case .page, .offset:
                values[param.name] = String(position)
            default:
                values[param.name] = param.currentValue(in: parameters, language: language)
            }
        }
        if let keyword { values["keyword"] = keyword }
        return values
    }

    /// What the section form offers the reader (Phase 6f): not a constant, nor the paging.
    var editableParams: [RuleModule.Param] {
        params.filter { [.input, .count, .enumeration].contains($0.kind) }
    }
}

extension RuleModule.Param {
    /// The section's own value, else the option in `language` (the reader's 中繼資料語言偏好推薦,
    /// a `MetadataLanguage` tag) for a parameter that follows it, else the default, else an
    /// enumeration's first option.
    func currentValue(in parameters: [String: String], language: String?) -> String {
        parameters[name] ?? language.flatMap(option(in:))?.value ?? value ?? enumOptions?.first?.value ?? ""
    }

    /// A `followsLanguage` parameter's option in `language`, else in another script or region of
    /// it (`zh-Hans` for `zh-Hant`); nil when none is, or the parameter does not follow it.
    func option(in language: String) -> RuleModule.Option? {
        guard followsLanguage == true, let options = enumOptions else { return nil }
        func tag(of option: RuleModule.Option) -> String { option.language ?? option.value }
        return options.first { tag(of: $0).caseInsensitiveCompare(language) == .orderedSame }
            ?? options.first { ReadingLanguage.base(of: tag(of: $0)) == ReadingLanguage.base(of: language) }
    }
}

/// Reads a module's pages: the request its entry describes, through `WebFetcher` under the
/// module's `rateLimit`, then its list rules on a bare `ModernRuleEngine` (no JS evaluator,
/// never `BookSourceSession`), through the mapping 來源配置 use.
///
/// Every address it sends to passes `safeURL` and the module's `hosts`, a redirect included;
/// a refused redirect is never sent.
struct RuleModuleClient: Sendable {
    let fetcher: WebFetcher
    let store: RuleModuleStore
    let now: @Sendable () -> Date

    init(fetcher: WebFetcher = .shared, store: RuleModuleStore = RuleModuleStore(), now: @escaping @Sendable () -> Date = { .now }) {
        self.fetcher = fetcher
        self.store = store
        self.now = now
    }

    func page(of entry: RuleModule.Entry, in module: RuleModule, values: [String: String]) async throws -> RuleModulePage {
        let entryID = entry.id ?? "search"
        let cacheFile = cacheFile(module: module.id, entry: entryID, values: values)
        let duration = TimeInterval(max(entry.cacheDuration ?? 0, 0))
        if duration > 0, let cached = cached(cacheFile), now().timeIntervalSince(cached.fetchedAt) < duration {
            return cached
        }

        let started = SourcePerfTrace.now
        let page = RuleModulePage(items: try await fetch(entry, in: module, values: values), fetchedAt: now())
        SourcePerfTrace.record("module.page", "module=\(module.id) entry=\(entryID) items=\(page.items.count)",
                               since: started, thresholdMs: 0)
        if duration > 0 { save(page, to: cacheFile) }
        return page
    }

    // MARK: - Request

    private func fetch(_ entry: RuleModule.Entry, in module: RuleModule, values: [String: String]) async throws -> [RuleListItem] {
        let request = entry.request
        let address = Self.fill(request.url, values, encode: true)
        let bodyEncoding: TemplateEncoding = request.bodyEncoding == RuleModule.BodyEncoding.json.rawValue ? .json : .percent
        let page = try await send(address, method: (request.method ?? "GET").uppercased(),
                                  body: request.body.map { Self.fill($0, values, encoding: bodyEncoding) },
                                  headers: (request.headers ?? [:]).mapValues { Self.fill($0, values, encode: false) },
                                  charset: request.charset, in: module)
        let list = entry.list
        return RuleListMapping.items(engine: ModernRuleEngine(), content: page.text, baseURL: page.baseURL,
                                     listRule: list.items, fields: list.fields)
    }

    /// The record's own page, read by `detail` (Open Library's `/works/<id>.json`): the item with
    /// its empty description and tags given from it. `{{url}}` is the item's `url`, as it is at
    /// the start of the address, percent-encoded anywhere else.
    func detailed(_ item: RuleListItem, by detail: RuleModule.Detail, in module: RuleModule) async throws -> RuleListItem {
        let request = detail.request
        let values = ["url": item.bookUrl]
        let leading = request.url.trimmingCharacters(in: .whitespaces).hasPrefix("{{url}}")
        let bodyEncoding: TemplateEncoding = request.bodyEncoding == RuleModule.BodyEncoding.json.rawValue ? .json : .percent
        let started = SourcePerfTrace.now
        let page = try await send(Self.fill(request.url, values, encode: !leading), method: (request.method ?? "GET").uppercased(),
                                  body: request.body.map { Self.fill($0, values, encoding: bodyEncoding) },
                                  headers: (request.headers ?? [:]).mapValues { Self.fill($0, values, encode: false) },
                                  charset: request.charset, in: module)
        let engine = ModernRuleEngine()
        engine.setContent(page.text, baseUrl: page.baseURL)
        var item = item
        if item.intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rule = detail.intro, !rule.isEmpty {
            item.intro = engine.getString(ruleStr: rule)
        }
        if (item.tags ?? []).isEmpty, let rule = detail.tags, !rule.isEmpty {
            item.tags = RuleListMapping.values(engine, rule)
        }
        SourcePerfTrace.record("module.detail", "module=\(module.id)", since: started, thresholdMs: 0)
        return item
    }

    /// One request of the module's: `safeURL` and its hosts on the address and every redirect,
    /// under its `rateLimit`; the reply decoded as text.
    func send(_ address: String, method: String = "GET", body: String? = nil, headers: [String: String],
              charset: String?, in module: RuleModule, followsRefresh: Bool = true) async throws -> (text: String, baseURL: String) {
        let hosts = RuleModuleHosts(module.hosts)
        let redirects = Self.redirectGate(hosts)
        guard let url = safeURL(string: address), let host = url.host, hosts.allowsRequest(to: host) else {
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(address))
        }
        let charset = charset.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let page = try await SourceRateLimit.run(rate: module.rateLimit ?? "", key: "module:\(module.id)") {
            try await fetcher.fetchPage(url: url, method: method, body: body, headers: headers, baseURL: "",
                                        bodyCharset: charset, redirect: redirects)
        }
        let status = page.statusCode
        if (300...399).contains(status) {
            let location = (page.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
            let target = URL(string: location, relativeTo: url)?.absoluteString ?? location
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(target))
        }
        guard (200...299).contains(status) else {
            throw SourceFailure(kind: .rejected, status: status, underlying: FetchError.httpError(status))
        }
        guard let text = HTMLResponseDecoder.decode(data: page.data, response: page.response, declaredCharset: charset) else {
            throw SourceFailure(kind: .parse, underlying: FetchError.encodingError)
        }
        let baseURL = page.response.url ?? url
        // A soft redirect, followed once, to the module's own hosts. The real case: なろう's API
        // names a work in upper case (N9669BK) and the site answers that address with a 200
        // 「リダイレクト中」 page whose meta refresh points at the lower-case one, so every book's
        // table of contents read empty (2026-10-17). It can go when the format can transform a
        // field's case or the sites stop serving these pages.
        if followsRefresh, method == "GET", let target = Self.metaRefreshTarget(in: text, baseURL: baseURL),
           target.absoluteString != baseURL.absoluteString {
            guard redirects(target) else {
                AppLogger.network("module page refreshes to an address outside its hosts; read as it is",
                                  context: ["module": module.id, "page": baseURL.absoluteString, "target": target.absoluteString])
                return (text, baseURL.absoluteString)
            }
            return try await send(target.absoluteString, method: method, headers: headers, charset: charset,
                                  in: module, followsRefresh: false)
        }
        return (text, baseURL.absoluteString)
    }

    // Literal patterns: a typo fails the first test that reads a page, not a user's request.
    nonisolated private static let metaTag = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: .caseInsensitive)
    nonisolated private static let metaContent = try! NSRegularExpression(
        pattern: #"\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: .caseInsensitive)
    nonisolated private static let refreshURL = try! NSRegularExpression(
        pattern: #"^\s*\d*(?:\.\d*)?\s*[;,]\s*url\s*=\s*['"]?([^'"]+)"#, options: .caseInsensitive)

    /// The address a page's `<meta http-equiv="refresh" content="N;URL=…">` sends a browser to,
    /// read before its `<body>`. Nil for a page without one, or one that only reloads itself.
    nonisolated static func metaRefreshTarget(in html: String, baseURL: URL) -> URL? {
        let head = html.range(of: "<body", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        let tags = Self.metaTag, contentPattern = Self.metaContent, urlPattern = Self.refreshURL
        let text = String(head)
        for match in tags.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let tagRange = Range(match.range, in: text) else { continue }
            let tag = String(text[tagRange])
            guard tag.range(of: #"http-equiv\s*=\s*["']?refresh"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let content = contentPattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let value = [1, 2].lazy.compactMap({ Range(content.range(at: $0), in: tag) }).first.map({ String(tag[$0]) }),
                  let address = urlPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let addressRange = Range(address.range(at: 1), in: value)
            else { continue }
            let target = value[addressRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: target, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    /// Where a redirect may go: the hosts written out, or a `*.` domain, and a safe address.
    nonisolated private static func redirectGate(_ hosts: RuleModuleHosts) -> @Sendable (URL) -> Bool {
        { url in
            guard let host = url.host, hosts.allowsRedirect(to: host) else { return false }
            return safeURL(string: url.absoluteString) != nil
        }
    }

    /// A cover a lookup's record names (format 3.0): from the module's `hosts` only, under its
    /// `rateLimit`. Nil when the site lists a cover it does not serve (404) or that is no image.
    func image(_ address: String, in module: RuleModule) async throws -> Data? {
        let hosts = RuleModuleHosts(module.hosts)
        let redirects = Self.redirectGate(hosts)
        guard let url = safeURL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host,
              hosts.allowsRequest(to: host) else {
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(address))
        }
        let page = try await SourceRateLimit.run(rate: module.rateLimit ?? "", key: "module:\(module.id)") {
            try await fetcher.fetchPage(url: url, method: "GET", body: nil, headers: [:], baseURL: "", redirect: redirects)
        }
        if page.statusCode == 404 { return nil }
        // A redirect the hosts refuse is a cover this module may not fetch, every time: no cover,
        // not a failure that would lose the record's other values and ask again each week.
        if (300...399).contains(page.statusCode) {
            let location = (page.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
            AppLogger.network("module cover redirects outside its hosts", context: [
                "module": module.id, "url": url.absoluteString, "target": location,
            ])
            return nil
        }
        guard (200...299).contains(page.statusCode) else {
            throw SourceFailure(kind: .rejected, status: page.statusCode, underlying: FetchError.httpError(page.statusCode))
        }
        guard BookCoverLoader.decodedCover(from: page.data) != nil else {
            AppLogger.network("module cover is no image", context: ["module": module.id, "url": url.absoluteString])
            return nil
        }
        return page.data
    }

    /// A module file, for 新增模組 and 檢查更新: through the same `WebFetcher` path as the
    /// module's own requests, `safeURL` on the address and on every redirect (a refused redirect
    /// is never sent). Any host: the module's `hosts` bind its requests, not where it is shared.
    nonisolated static func download(_ address: String, fetcher: WebFetcher = .shared) async throws -> (data: Data, url: URL) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = safeURL(string: trimmed) else {
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(trimmed))
        }
        let page = try await fetcher.fetchPage(url: url, method: "GET", body: nil,
                                               headers: ["Accept": "application/json, text/plain, */*"], baseURL: "",
                                               redirect: { safeURL(string: $0.absoluteString) != nil })
        let status = page.statusCode
        if (300...399).contains(status) {
            let location = (page.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(location))
        }
        guard (200...299).contains(status) else {
            throw SourceFailure(kind: .rejected, status: status, underlying: FetchError.httpError(status))
        }
        return (page.data, url)
    }

    /// How a value is written into the text that holds its template.
    enum TemplateEncoding: Sendable {
        /// As it is: a header.
        case none
        /// A URL or a form body.
        case percent
        /// Inside a JSON string: quotes, backslashes and control characters escaped.
        case json
    }

    /// `text` with each `{{name}}` replaced by its value, percent-encoded for a URL or a form
    /// body. The validator let no other template through.
    static func fill(_ text: String, _ values: [String: String], encode: Bool) -> String {
        fill(text, values, encoding: encode ? .percent : .none)
    }

    static func fill(_ text: String, _ values: [String: String], encoding: TemplateEncoding) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in SourceRule.evalPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range)
            let name = String(token.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            let value = values[name] ?? ""
            switch encoding {
            case .none: result += value
            case .percent: result += value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
            case .json: result += jsonEscaped(value)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// `value` as the inside of a JSON string literal.
    private static func jsonEscaped(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let control where control.value < 0x20:
                escaped += String(format: "\\u%04x", control.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// A value never adds a query separator of its own.
    private static let valueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))

    // MARK: - Cache

    /// One file per entry and its values, so a section's own parameters keep their own pages.
    private func cacheFile(module: String, entry: String, values: [String: String]) -> URL {
        let key = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return store.cacheDirectory(id: module).appendingPathComponent("\(entry)-\(digest.prefix(32)).json")
    }

    /// A cache that cannot be read is a miss: the page is fetched again and the file replaced.
    private func cached(_ file: URL) -> RuleModulePage? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode(RuleModulePage.self, from: Data(contentsOf: file))
        } catch {
            AppLogger.cache("Module page cache unreadable", error: error, context: ["file": file.lastPathComponent], level: .warning)
            return nil
        }
    }

    private func save(_ page: RuleModulePage, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(page).write(to: file, options: .atomic)
        } catch {
            AppLogger.cache("Module page cache not written", error: error, context: ["file": file.lastPathComponent], level: .warning)
        }
    }
}
