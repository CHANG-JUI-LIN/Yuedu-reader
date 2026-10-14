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

    /// Where the first page starts.
    var firstPosition: Int { paging == .page ? 1 : 0 }

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
    /// it has none), the reader's own for this section, then the page's position.
    func values(_ parameters: [String: String], position: Int, keyword: String? = nil) -> [String: String] {
        var values: [String: String] = [:]
        for param in params {
            switch param.kind {
            case .page, .offset:
                values[param.name] = String(position)
            default:
                values[param.name] = parameters[param.name] ?? param.value ?? param.enumOptions?.first?.value ?? ""
            }
        }
        if let keyword { values["keyword"] = keyword }
        return values
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
        let hosts = Set(module.hosts.map { $0.lowercased() })
        let allowed: @Sendable (URL) -> Bool = { url in
            guard let host = url.host?.lowercased(), hosts.contains(host) else { return false }
            return safeURL(string: url.absoluteString) != nil
        }
        let request = entry.request
        let address = Self.fill(request.url, values, encode: true)
        guard let url = safeURL(string: address), allowed(url) else {
            throw SourceFailure(kind: .invalidAddress, underlying: FetchError.invalidURL(address))
        }
        let method = (request.method ?? "GET").uppercased()
        let body = request.body.map { Self.fill($0, values, encode: true) }
        let headers = (request.headers ?? [:]).mapValues { Self.fill($0, values, encode: false) }
        let charset = request.charset.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        let page = try await SourceRateLimit.run(rate: module.rateLimit ?? "", key: "module:\(module.id)") {
            try await fetcher.fetchPage(url: url, method: method, body: body, headers: headers, baseURL: "",
                                        bodyCharset: charset, redirect: allowed)
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
        guard let text = HTMLResponseDecoder.decode(data: page.data, response: page.response, declaredCharset: charset) else { throw SourceFailure(kind: .parse, underlying: FetchError.encodingError) }

        let list = entry.list
        let baseURL = page.response.url?.absoluteString ?? url.absoluteString
        return RuleListMapping.items(engine: ModernRuleEngine(), content: text, baseURL: baseURL,
                                     listRule: list.items, fields: list.fields)
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

    /// `text` with each `{{name}}` replaced by its value, percent-encoded for a URL or a form
    /// body. The validator let no other template through.
    static func fill(_ text: String, _ values: [String: String], encode: Bool) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in SourceRule.evalPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let token = ns.substring(with: match.range)
            let name = String(token.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            let value = values[name] ?? ""
            result += encode ? (value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value) : value
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
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
