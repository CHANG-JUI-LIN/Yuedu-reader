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
    /// `@js:` or `<js>`: a module never reaches the JavaScript bridge.
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
}

/// Checks a module file at import, before anything is stored. What it lets through runs on a
/// bare rule engine with no JS evaluator.
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

    static func validate(_ module: RuleModule, appVersion: String) throws(RuleModuleRejection) {
        guard isFileSafe(module.id) else { throw .invalidID(module.id) }
        try requireText(module.title, "title")
        guard RuleModuleVersion(module.version) != nil else { throw .invalidVersion(field: "version", value: module.version) }
        if let required = module.requiredVersion {
            guard let needed = RuleModuleVersion(required) else { throw .invalidVersion(field: "requiredVersion", value: required) }
            if let running = RuleModuleVersion(appVersion), running < needed {
                throw .requiresNewerApp(required: required, running: appVersion)
            }
        }
        guard !module.modules.isEmpty || module.search != nil else { throw .noEntries }
        guard module.modules.count <= maxEntries else { throw .tooManyEntries(module.modules.count) }

        let hosts = Set(module.hosts.map { $0.lowercased() })
        var seen: Set<String> = []
        for (index, entry) in module.modules.enumerated() {
            let path = "modules[\(index)]"
            guard let id = entry.id, !id.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingField("\(path).id") }
            guard isFileSafe(id) else { throw .invalidID(id) }
            guard seen.insert(id).inserted else { throw .duplicateEntryID(id) }
            try requireText(entry.title ?? "", "\(path).title")
            try validate(entry, path: path, hosts: hosts, isSearch: false)
        }
        if let search = module.search { try validate(search, path: "search", hosts: hosts, isSearch: true) }
    }

    // MARK: - Entries

    private static func validate(_ entry: RuleModule.Entry, path: String, hosts: Set<String>,
                                 isSearch: Bool) throws(RuleModuleRejection) {
        var declared = pagingNames
        if isSearch { declared.insert("keyword") }
        for (index, param) in entry.params.enumerated() {
            let field = "\(path).params[\(index)]"
            try requireText(param.name, "\(field).name")
            guard let kind = param.kind else { throw .unknownParamType(field: "\(field).type", type: param.type) }
            if kind == .enumeration, param.enumOptions?.isEmpty ?? true {
                throw .enumerationWithoutOptions(field: "\(field).enumOptions")
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
        for case let (name, rule?) in rules {
            // A list rule fills no parameters: a `{{…}}` there would go to the JS evaluator.
            try checkRule(rule, field: "\(path).list.\(name)", declared: [])
        }
    }

    // MARK: - Rules and templates

    /// No JS, no variables, and every `{{…}}` declared.
    private static func checkRule(_ rule: String, field: String, declared: Set<String>) throws(RuleModuleRejection) {
        // The engine's own split decides what is JS, so the validator and the engine never disagree.
        if ModernRuleEngine().splitSourceRule(rule).contains(where: { $0.mode == .js }) { throw .javaScript(field: field) }
        let lowered = rule.lowercased()
        if lowered.contains("@get:") || lowered.contains("@put:") { throw .variables(field: field) }
        for name in templateNames(in: rule) where !declared.contains(name) {
            throw .undeclaredTemplate(field: field, name: name)
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

    private static func checkHost(_ url: String, field: String, hosts: Set<String>) throws(RuleModuleRejection) {
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
        guard hosts.contains(host) else { throw .hostNotAllowed(field: field, host: host) }
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
