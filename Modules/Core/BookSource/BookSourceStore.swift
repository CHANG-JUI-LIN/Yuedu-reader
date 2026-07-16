import Foundation
import Combine

// MARK: - Book Source Management (ObservableObject)

class BookSourceStore: ObservableObject {
    static let shared = BookSourceStore()

    @Published var sources: [BookSource] = []

    private let fileName = "book_sources.json"

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    private init() {
        load()
    }

    // MARK: CRUD

    func add(_ source: BookSource) {
        var stamped = source
        // Stamp the local-modification clock so this creation wins the iCloud sync merge
        // (see importSources for why lastUpdateTime doubles as the last-write-wins clock).
        stamped.lastUpdateTime = Self.currentMillis()
        sources.insert(stamped, at: 0)
        save()
    }

    func update(_ source: BookSource) {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            var updated = source
            // Advance the sync clock so an in-app edit wins the last-write-wins merge and isn't
            // resurrected to the cloud copy on the next sync. Skip when only the clock would move,
            // so re-saving an unchanged source doesn't churn the sync.
            updated.lastUpdateTime = Self.sourceContentDiffers(updated, sources[idx])
                ? Self.currentMillis()
                : sources[idx].lastUpdateTime
            sources[idx] = updated
            save()
        }
    }

    @discardableResult
    func delete(id: UUID) -> Int {
        delete(ids: Set([id]))
    }

    @discardableResult
    func delete(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let originalCount = sources.count
        sources.removeAll { ids.contains($0.id) }
        let removedCount = originalCount - sources.count
        if removedCount > 0 {
            save()
        }
        return removedCount
    }

    func toggle(id: UUID) {
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            sources[idx].enabled.toggle()
            // The user's enable/disable must win the iCloud sync merge (advance the clock).
            sources[idx].lastUpdateTime = Self.currentMillis()
            save()
        }
    }

    /// Sets a source's enabled flag to an explicit value (no-op if already set). Used by the
    /// health checker to disable bad/slow sources without risk of accidentally re-enabling.
    /// Deliberately does NOT advance `lastUpdateTime`: an automated, possibly-transient disable
    /// shouldn't win the sync merge and propagate to other devices (unlike a user toggle above).
    func setEnabled(id: UUID, enabled: Bool) {
        if let idx = sources.firstIndex(where: { $0.id == id }), sources[idx].enabled != enabled {
            sources[idx].enabled = enabled
            save()
        }
    }

    var enabledSources: [BookSource] {
        sources.filter { $0.enabled }
    }

    // MARK: Import (Legado Compatible)

    /// Import from raw Data, using the file extension to choose the right parser.
    @discardableResult
    func importFromData(_ data: Data, fileExtension ext: String) throws -> Int {
        let lower = ext.lowercased()
        switch lower {
        case "yds":
            let sources = try parseYDS(data)
            return try importSources(sources)
        case "xbs", "mrs":
            throw ImportError.encryptedFormat(lower.uppercased())
        default:
            // .txt, .json, or unknown → try as Legado JSON
            guard let text = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
                throw ImportError.invalidData
            }
            return try importFromJSON(text)
        }
    }

    @discardableResult
    func importFromJSON(_ json: String) throws -> Int {
        guard let data = json.data(using: .utf8) else {
            throw ImportError.invalidData
        }
        let decoder = JSONDecoder()
        var imported: [BookSource] = []

        // Try array format [...]
        if let arr = try? decoder.decode([BookSource].self, from: data) {
            imported = arr
        }
        // Try single object {...}
        else if let single = try? decoder.decode(BookSource.self, from: data) {
            imported = [single]
        }
        // Try Legado App backup format (bookSources field)
        else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let raw = dict["bookSources"] {
            let subData = try JSONSerialization.data(withJSONObject: raw)
            imported = (try? decoder.decode([BookSource].self, from: subData)) ?? []
        }
        else {
            // Produce useful diagnostic messages
            let detail: String
            do {
                _ = try decoder.decode([BookSource].self, from: data)
                detail = ""
            } catch let DecodingError.typeMismatch(type, ctx) {
                detail = "Type mismatch: expected \(type), path: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch let DecodingError.keyNotFound(key, ctx) {
                detail = "Missing key: \(key.stringValue), path: \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            } catch let DecodingError.dataCorrupted(ctx) {
                detail = "Data corrupted: \(ctx.debugDescription)"
            } catch {
                detail = error.localizedDescription
            }
            throw ImportError.parseErrorDetail(detail)
        }

        return try importSources(imported)
    }

    // MARK: Private: Merge Book Sources

    @discardableResult
    private func importSources(_ imported: [BookSource]) throws -> Int {
        guard !imported.isEmpty else { throw ImportError.parseError }
        // iCloud/Firestore sync merges book sources last-write-wins, using `lastUpdateTime` as
        // the per-item clock (ties/older-remote win). A source's author-declared `lastUpdateTime`
        // is baked into the JSON — it is NOT a "modified locally now" time — so a freshly imported
        // version whose `lastUpdateTime` happens to be ≤ the cloud copy's would be silently
        // resurrected to the OLD version on the next sync (reported: import a new 大灰狼 source, it
        // reverts after one read). Stamp the import moment onto `lastUpdateTime` so the deliberate
        // local import wins the merge. Only bump when content actually changed, so re-importing an
        // identical list doesn't churn the sync. `lastUpdateTime` is otherwise only a sync clock /
        // cache key / display value — nothing compares it against a remote source to gate updates.
        let nowMillis = Self.currentMillis()
        for src in imported {
            if let idx = sources.firstIndex(where: { $0.bookSourceUrl == src.bookSourceUrl }) {
                var updated = src
                updated.id = sources[idx].id
                updated.lastUpdateTime = Self.sourceContentDiffers(updated, sources[idx])
                    ? nowMillis
                    : sources[idx].lastUpdateTime
                sources[idx] = updated
            } else {
                var added = src
                added.lastUpdateTime = nowMillis
                sources.append(added)
            }
        }
        save()
        return imported.count
    }

    /// Current wall-clock time in milliseconds — the unit `BookSource.lastUpdateTime` (and the
    /// iCloud/Firestore sync last-write-wins merge clock) is expressed in.
    private static func currentMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Compares two sources ignoring their `lastUpdateTime` sync clock, so re-importing byte-for-byte
    /// identical rules is detected as "no change" and doesn't advance the merge timestamp.
    private static func sourceContentDiffers(_ lhs: BookSource, _ rhs: BookSource) -> Bool {
        var a = lhs
        var b = rhs
        a.lastUpdateTime = 0
        b.lastUpdateTime = 0
        let encoder = JSONEncoder()
        return (try? encoder.encode(a)) != (try? encoder.encode(b))
    }

    /// Collapses sources sharing a `bookSourceUrl` to one newest entry. Legado source JSON carries
    /// no stable `id`, so each device decodes an imported source under a fresh random UUID; the
    /// iCloud merge keys on that UUID and can't tell two devices' copies of the *same* source apart,
    /// letting the cloud's older copy resurface — read by the user as a version revert / duplicate.
    /// `bookSourceUrl` is the real identity (importSources already dedupes on it), so normalize
    /// merged- and loaded-in source lists the same way, keeping the most recently updated copy.
    static func dedupedByURL(_ input: [BookSource]) -> [BookSource] {
        var indexByURL: [String: Int] = .init(minimumCapacity: input.count)
        var result: [BookSource] = []
        result.reserveCapacity(input.count)
        for source in input {
            let key = source.bookSourceUrl
            guard !key.isEmpty else {
                result.append(source)   // no URL to key on — keep as-is
                continue
            }
            if let idx = indexByURL[key] {
                if source.lastUpdateTime > result[idx].lastUpdateTime {
                    result[idx] = source   // keep the newer copy in the earlier slot
                }
            } else {
                indexByURL[key] = result.count
                result.append(source)
            }
        }
        return result
    }

    // MARK: YDS (.yds) Format Parsing

    /// .yds is a JSON dictionary keyed by source display name.
    /// Each value uses different field names from Legado; convert to BookSource.
    private func parseYDS(_ data: Data) throws -> [BookSource] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidData
        }
        var results: [BookSource] = []
        for (_, value) in root {
            guard let obj = value as? [String: Any] else { continue }
            var bs = BookSource()
            bs.bookSourceName  = obj["siteName"] as? String ?? ""
            bs.bookSourceUrl   = obj["host"] as? String ?? ""
            bs.bookSourceType  = obj["siteType"] as? Int ?? 0
            bs.enabled         = obj["enable"] as? Bool ?? true
            bs.loginUrl        = obj["loginUrl"] as? String ?? ""

            let host = bs.bookSourceUrl

            // ── searchRule ──────────────────────────────
            if let sr = obj["searchRule"] as? [String: Any] {
                bs.searchUrl          = ydsResolveUrl(sr["requestUrl"], host: host)
                bs.ruleSearch.bookList  = sr["list"]      as? String ?? ""
                bs.ruleSearch.name      = sr["title"]     as? String ?? ""
                bs.ruleSearch.author    = sr["author"]    as? String ?? ""
                bs.ruleSearch.coverUrl  = sr["cover"]     as? String ?? ""
                bs.ruleSearch.kind      = sr["tags"]      as? String ?? ""
                bs.ruleSearch.intro     = sr["desc"]      as? String ?? ""
                bs.ruleSearch.bookUrl   = sr["detailUrl"] as? String ?? ""
            }

            // ── detailRule → ruleBookInfo ────────────────
            if let dr = obj["detailRule"] as? [String: Any] {
                bs.ruleBookInfo.initScript = dr["requestUrl"] as? String ?? ""
                // detailRule.url is the identifier extracted from detail response
                // chapterRule.requestUrl then builds the actual TOC URL from that
                let chapterRequestUrl = (obj["chapterRule"] as? [String: Any])?["requestUrl"] as? String ?? ""
                if !chapterRequestUrl.isEmpty {
                    // Compose: extract detailRule.url, then pipe into chapterRule.requestUrl
                    let detailUrl = dr["url"] as? String ?? ""
                    bs.ruleBookInfo.tocUrl = ydsComposeTocUrl(detailUrl: detailUrl,
                                                               chapterRequestUrl: chapterRequestUrl)
                }
            }

            // ── chapterRule → ruleToc ────────────────────
            if let cr = obj["chapterRule"] as? [String: Any] {
                bs.ruleToc.chapterList = cr["list"]  as? String ?? ""
                bs.ruleToc.chapterName = cr["title"] as? String ?? ""
                bs.ruleToc.chapterUrl  = cr["url"]   as? String ?? ""
            }

            // ── contentRule → ruleContent ────────────────
            if let cont = obj["contentRule"] as? [String: Any] {
                bs.ruleContent.content = cont["content"] as? String ?? ""
                // contentRule.requestUrl: store as a init/preUpdate comment
                if let reqUrl = cont["requestUrl"] as? String, !reqUrl.isEmpty {
                    bs.ruleContent.webJs = reqUrl
                }
            }

            if !bs.bookSourceName.isEmpty || !bs.bookSourceUrl.isEmpty {
                results.append(bs)
            }
        }
        return results
    }

    /// Resolve a .yds `requestUrl` to the actual URL string used in Legado.
    /// The requestUrl is either:
    ///   - A JSON string like `{"url": "/path?$keyWord..."}` → combine with host
    ///   - A `@js:` expression → use as-is
    ///   - A plain URL → use as-is
    private func ydsResolveUrl(_ raw: Any?, host: String) -> String {
        guard let raw else { return "" }
        let s: String
        if let str = raw as? String { s = str.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { return "" }

        if s.hasPrefix("@js:") || s.hasPrefix("@JS:") { return s }

        // Try JSON object with "url" key
        if s.hasPrefix("{"), let d = s.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let path = dict["url"] as? String {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPath.hasPrefix("http") { return trimmedPath }
            return host + trimmedPath
        }
        // Plain URL or template
        if s.hasPrefix("http") { return s }
        return host + s
    }

    /// Compose a Legado `ruleBookInfo.tocUrl` from the .yds two-step chain:
    /// 1. `detailUrl` is a template/JSONPath applied to the detail response
    /// 2. `chapterRequestUrl` (@js:) builds the chapter list URL from that
    /// If detailUrl is empty, just return chapterRequestUrl directly.
    private func ydsComposeTocUrl(detailUrl: String, chapterRequestUrl: String) -> String {
        let det = detailUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let chap = chapterRequestUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the chapterRequestUrl is pure @js:, wrap both into a single @js: that:
        //   1. evaluates the detailUrl rule against `result` (the raw response)
        //   2. passes that to the chapterRequestUrl JS
        if det.isEmpty { return chap }
        if chap.hasPrefix("@js:") {
            let jsBody = String(chap.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "@js:\n// step 1: extract detail intermediate value\nvar _result = result;\n// step 2: build chapter URL\n\(jsBody)"
        }
        return det.isEmpty ? chap : det
    }

    // MARK: Export

    func exportToJSON() -> String {
        guard let data = try? JSONEncoder().encode(sources),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    func exportToJSON(ids: [UUID]) -> String {
        let selected = sources.filter { ids.contains($0.id) }
        guard let data = try? JSONEncoder().encode(selected),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    func replaceSourcesFromSync(_ syncedSources: [BookSource]) {
        // Collapse any cross-device duplicates (same bookSourceUrl, different random id) the merge
        // couldn't unify, so an old cloud copy can't resurface next to a freshly imported one.
        sources = Self.dedupedByURL(syncedSources)
        save()
    }

    /// Re-reads the on-disk store into memory. Used after an iCloud restore
    /// overwrites `book_sources.json` so the live UI reflects it without a relaunch.
    func reloadFromDisk() {
        load()
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BookSource].self, from: data)
        else { return }
        // Clean up any duplicates a previous buggy sync may have persisted to disk.
        sources = Self.dedupedByURL(decoded)
    }

    // MARK: Errors

    enum ImportError: LocalizedError {
        case invalidData
        case parseError
        case parseErrorDetail(String)
        case encryptedFormat(String)

        var errorDescription: String? {
            switch self {
            case .invalidData: return "Invalid data format"
            case .parseError: return "Unable to parse book source JSON"
            case .parseErrorDetail(let detail):
                return "Unable to parse book source JSON: \(detail)"
            case .encryptedFormat(let fmt):
                return "\(fmt) format uses proprietary encryption and is not supported for direct import. Please use the corresponding app to export as JSON/TXT format."
            }
        }
    }
}
