import Foundation
import Combine

// MARK: - Pin State

/// Where a user explicitly pinned a source (置頂／置底). Unlike a plain move, a pin is a
/// deliberate claim on the head/tail region: the list shows a pin icon, and 取消置頂／取消置底
/// drops the pin and puts the source back where it was.
enum SourcePinPosition: String, Codable, Equatable {
    case top
    case bottom
}

struct SourcePinRecord: Codable, Equatable {
    var position: SourcePinPosition
    /// The source's array index when it was pinned, so unpinning can restore it
    /// (clamped to the current list size — later insertions/deletions shift everything).
    var originalIndex: Int
    /// When the pin was set, newest-first within each pin group. Pre-multi-pin files
    /// carry no timestamp and decode as `.distantPast`, sorting last — i.e. bottom of
    /// their pin group — instead of jumping the order.
    var pinnedAt: Date

    init(position: SourcePinPosition, originalIndex: Int, pinnedAt: Date = Date()) {
        self.position = position
        self.originalIndex = originalIndex
        self.pinnedAt = pinnedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(SourcePinPosition.self, forKey: .position)
        originalIndex = try container.decode(Int.self, forKey: .originalIndex)
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt) ?? .distantPast
    }
}

// MARK: - Book Source Management (ObservableObject)

class BookSourceStore: ObservableObject {
    static let shared = BookSourceStore()

    @Published var sources: [BookSource] = []

    /// Persisted 置頂／置底 pin state, keyed by source id. Kept OUT of `BookSource` (and thus
    /// out of the exported/synced source JSON) so pinning never looks like a content edit:
    /// it must not advance `lastUpdateTime` or churn the sync merge (same contract as the
    /// ordering — array position is the display order, and pins are management state).
    @Published private(set) var pinRecords: [UUID: SourcePinRecord] = [:]

    private let fileName = "book_sources.json"

    private var pinsFileURL: URL {
        StorageLocations.support.appendingPathComponent("book_source_pins.json")
    }

    /// Under Application Support, not Documents: Documents is user-visible in the
    /// Files app and this is app-internal. `StorageMigration` moves the legacy file.
    private var fileURL: URL {
        StorageLocations.bookSourcesFile
    }

    private init() {
        loadPins()
        load()
    }

    // MARK: CRUD

    func add(_ source: BookSource) {
        var stamped = source
        // Stamp the local-modification clock so this creation wins the iCloud sync merge
        // (see importSources for why lastUpdateTime doubles as the last-write-wins clock).
        stamped.lastUpdateTime = Self.currentMillis()
        // New sources appear at the head of the list — but below the whole 置頂 group,
        // or the pin markers would no longer match the head region.
        if let lastTopPinned = sources.lastIndex(where: { pinRecords[$0.id]?.position == .top }) {
            sources.insert(stamped, at: lastTopPinned + 1)
        } else {
            sources.insert(stamped, at: 0)
        }
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
            for id in ids {
                pinRecords.removeValue(forKey: id)
            }
            savePins()
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

    /// Moves a source to the head of the list and marks it 置頂. Any number of sources can
    /// be pinned: the 置頂 group orders newest-first, so a re-pin refreshes the timestamp
    /// and moves the source to the group's head. The management list and `enabledSources`
    /// both render `sources` in array order — there is no sort key, so array position *is*
    /// the display and search order (Legado's `customOrder` field is only mirrored to the
    /// JS bridge, never consulted here).
    ///
    /// Deliberately does NOT advance `lastUpdateTime`: position isn't part of a source's
    /// content, the sync merge hashes the encoded source, and seeding the merge from the
    /// local array already preserves this device's order — so a reorder must not register
    /// as an edit and churn the sync.
    func pinToTop(id: UUID) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        let originalIndex = pinRecords[id]?.originalIndex ?? idx
        let source = sources.remove(at: idx)
        if let firstTop = sources.firstIndex(where: { pinRecords[$0.id]?.position == .top }) {
            sources.insert(source, at: firstTop)
        } else {
            sources.insert(source, at: 0)
        }
        pinRecords[id] = SourcePinRecord(position: .top, originalIndex: originalIndex)
        savePins()
        save()
    }

    /// Moves a source to the tail of the list and marks it 置底. Newest-first like 置頂:
    /// the newest bottom pin sits at the group's head, right against the rest of the list.
    /// See `pinToTop(id:)` for the ordering and sync-clock contract.
    func pinToBottom(id: UUID) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        let originalIndex = pinRecords[id]?.originalIndex ?? idx
        let source = sources.remove(at: idx)
        if let firstBottom = sources.firstIndex(where: { pinRecords[$0.id]?.position == .bottom }) {
            sources.insert(source, at: firstBottom)
        } else {
            sources.append(source)
        }
        pinRecords[id] = SourcePinRecord(position: .bottom, originalIndex: originalIndex)
        savePins()
        save()
    }

    /// 取消置頂／取消置底: drops the pin and returns the source to the position it held when
    /// pinned — inserted before the first unpinned source at or after the recorded index,
    /// or after the last unpinned source when everything else is pinned. Pins ahead in the
    /// array shift indices, so the position clamps naturally when the list shrank meanwhile.
    func unpin(id: UUID) {
        guard let record = pinRecords[id],
              let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        pinRecords.removeValue(forKey: id)
        let source = sources.remove(at: idx)

        var insertIndex: Int?
        for (index, candidate) in sources.enumerated() {
            guard pinRecords[candidate.id] == nil, index >= record.originalIndex else { continue }
            insertIndex = index
            break
        }
        if let insertIndex {
            sources.insert(source, at: insertIndex)
        } else if let lastUnpinned = sources.lastIndex(where: { pinRecords[$0.id] == nil }) {
            sources.insert(source, at: lastUnpinned + 1)
        } else if let firstBottom = sources.firstIndex(where: { pinRecords[$0.id]?.position == .bottom }) {
            sources.insert(source, at: firstBottom)
        } else {
            sources.append(source)
        }
        savePins()
        save()
    }

    func pinRecord(for id: UUID) -> SourcePinRecord? {
        pinRecords[id]
    }

    // MARK: Pin Persistence

    private func savePins() {
        if let data = try? JSONEncoder().encode(pinRecords) {
            try? data.write(to: pinsFileURL)
        }
    }

    private func loadPins() {
        guard let data = try? Data(contentsOf: pinsFileURL),
              let decoded = try? JSONDecoder().decode([UUID: SourcePinRecord].self, from: data)
        else { return }
        pinRecords = decoded
    }

    /// Drops pins whose source no longer exists (deleted locally, deduped by sync, etc.).
    private func prunePins() {
        let liveIDs = Set(sources.map(\.id))
        let staleIDs = pinRecords.keys.filter { !liveIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        for id in staleIDs {
            pinRecords.removeValue(forKey: id)
        }
        savePins()
    }

    /// Records the health checker's measured response time (ms), which doubles as the
    /// adaptive request timeout (Legado semantics: elapsed on success, timeout+elapsed on
    /// failure). Deliberately does NOT advance `lastUpdateTime`: an automated measurement
    /// shouldn't win the sync merge (same contract as `setEnabled`).
    func setRespondTime(id: UUID, ms: Int64) {
        if let idx = sources.firstIndex(where: { $0.id == id }), sources[idx].respondTime != ms {
            sources[idx].respondTime = ms
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

    /// Bulk enable/disable driven by the user (全部啟用／停用, 啟用選中, and the group menu).
    /// Advances `lastUpdateTime` exactly like `toggle(id:)` — a deliberate user action has to
    /// win the iCloud sync merge — and saves once instead of once per source, which is what
    /// separates it from the health checker's `setEnabled(id:enabled:)`.
    func setEnabledByUser(ids: Set<UUID>, enabled: Bool) {
        guard !ids.isEmpty else { return }
        let now = Self.currentMillis()
        var changed = false
        for idx in sources.indices
        where ids.contains(sources[idx].id) && sources[idx].enabled != enabled {
            sources[idx].enabled = enabled
            sources[idx].lastUpdateTime = now
            changed = true
        }
        if changed { save() }
    }

    /// Rewrites `bookSourceGroup` for a set of sources (重命名分組 / 合併到其他分組). An empty
    /// `group` clears the field, which returns those sources to the built-in default group.
    /// Group membership is source content, so this advances the sync clock — otherwise the
    /// last-write-wins merge would resurrect the old group name from another device.
    func setGroup(_ group: String, ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Self.currentMillis()
        var changed = false
        for idx in sources.indices
        where ids.contains(sources[idx].id) && sources[idx].bookSourceGroup != trimmed {
            sources[idx].bookSourceGroup = trimmed
            sources[idx].lastUpdateTime = now
            changed = true
        }
        if changed { save() }
    }

    /// Every distinct non-empty `bookSourceGroup`, in first-appearance order — the merge
    /// targets offered by the group menu.
    var groupNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for source in sources {
            let name = source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
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
                // New imports append at the tail — but above the whole 置底 group,
                // so the pin markers keep matching the tail region.
                if let bottomPinnedIndex = sources.firstIndex(where: { pinRecords[$0.id]?.position == .bottom }) {
                    sources.insert(added, at: bottomPinnedIndex)
                } else {
                    sources.append(added)
                }
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
        prunePins()
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
        prunePins()
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
