import Foundation

// Unified library Phase 3: a copy's empty fields fill themselves from the reader's book
// sources and from Open Library, with no screen to confirm them (maintainer, 2026-10-14:
// 「全自動的吧」). Plan: docs/superpowers/plans/2026-10-14-metadata-phase-3.md.
//
// - Only empty fields, never title or authors (design §8.1).
// - Only the sidecar (design §8.2): `ReadingBook` and its sync hash do not change.
// - A field the reader overrode (to nothing, too) or locked is never filled, so removing a
//   filled value sticks.

/// How a provider's record was matched to the copy (design §7).
enum MetadataMatchGrade: Sendable {
    /// By an identifier (ISBN…): the record is the copy's. Its identifiers may be kept, and it
    /// may give a missing cover.
    case a
    /// By title and authors. Values only: an identifier from a same-name book would merge two
    /// works in the index (`WorkIndexService`), and a cover from one would be on the shelf.
    case b
}

/// What a provider is asked.
struct MetadataFillQuery: Hashable, Sendable {
    var copyID: UUID
    var title: String
    var authors: [String]
    var identifiers: [ExternalIdentifier]
    /// The fields to look for; a provider may ignore the rest.
    var missing: Set<MetadataField>
}

/// What a provider found. Empty values mean it had nothing for this copy.
struct MetadataFillResult: Hashable, Sendable {
    /// A cover is a file name in `Caches/Works/covers`, saved by the provider.
    var values: [MetadataField: MetadataPayload]
    var identifiers: [ExternalIdentifier] = []
    /// The provider's record, kept on each value written.
    var sourceItem: SourceItemKey?
}

@MainActor
protocol MetadataFillProvider: AnyObject {
    var key: SourceInstanceKey { get }
    var grade: MetadataMatchGrade { get }
    /// Whether the copy can be looked up at all (Open Library needs an ISBN). A copy that
    /// cannot is not asked and leaves no ledger entry.
    func canLookUp(_ query: MetadataFillQuery) -> Bool
    /// Throws when the lookup failed (network, server); returns an empty result when the
    /// provider has no record of the copy.
    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult
}

/// One shelf copy, as the filler sees it.
struct MetadataFillCandidate: Hashable, Sendable {
    var copyID: UUID
    var title: String
    var authors: [String]
    /// The copy's own and its sidecar's.
    var identifiers: [ExternalIdentifier]
    /// The place the copy came from (`SourceRecord.key.instance`).
    var copySource: SourceInstanceKey
    /// The sidecar's record of the copy's source, kept when a value is written (a sidecar
    /// write replaces it).
    var sidecarSourceItem: SourceItemKey
    /// The copy has artwork of its own (`ReadingBook.coverImagePath` or a catalog cover).
    var hasOwnCover: Bool
    var values: [MetadataValue]
    var decisions: [WorkDecision]

    var anchor: SourceItemKey { .copy(copyID) }

    /// What the ledger compares: a copy whose title, authors or identifiers changed is a
    /// different question.
    var inputs: String {
        ([title] + authors + ["|"] + identifiers.map { "\($0.scheme.rawValue):\($0.value)" }.sorted())
            .joined(separator: "\u{1F}")
    }

    /// The fields worth looking for: empty, and with no decision of the reader's on them.
    var missing: Set<MetadataField> {
        Set(MetadataFillRunner.fillable.filter { field in
            let decided = decisions.contains {
                switch $0 {
                case .override(let a, let f, _, _), .lock(let a, let f, _, _): return a == anchor && f == field
                default: return false
                }
            }
            if decided { return false }
            if field == .cover && hasOwnCover { return false }
            let resolved = MetadataResolver.resolve(field, anchor: anchor, copySource: copySource, copyValue: nil,
                                                    values: values, decisions: decisions)
            return resolved.map { $0.value.isEmpty } ?? true
        })
    }

    /// The fields present, for `MetadataCompleteness`.
    var present: Set<MetadataField> {
        var present = Set(MetadataCompleteness.weights.keys).subtracting(missing)
        if authors.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { present.remove(.authors) }
        else { present.insert(.authors) }
        if hasOwnCover { present.insert(.cover) }
        return present
    }
}

extension MetadataPayload {
    var isEmpty: Bool {
        switch self {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .texts(let texts): texts.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .number, .date: false
        }
    }
}

/// How complete a copy's metadata is (design §8.3): a constant weight per field present. It
/// only orders the filler, least complete first; it is not shown and does not rank works.
enum MetadataCompleteness {
    static let weights: [MetadataField: Int] = [.cover: 3, .intro: 2, .authors: 2, .tags: 1, .language: 1, .series: 1]
    static var maximum: Int { weights.values.reduce(0, +) }

    static func score(present: Set<MetadataField>) -> Int {
        present.reduce(0) { $0 + (weights[$1] ?? 0) }
    }
}

/// Asks the providers, in order, for each copy's missing fields and writes what they found to
/// the copy's sidecar. A provider's answer is recorded in the ledger, so a copy is asked once
/// per provider (Open Library's terms rule out bulk lookups).
@MainActor
final class MetadataFillRunner {
    /// The fields the filler may write. Title and authors are not among them (design §8.1);
    /// word count and serial status come only from a copy's own source.
    static let fillable: [MetadataField] = [.cover, .intro, .tags, .series, .language, .publisher]

    struct Report: Equatable {
        var asked = 0
        var filled = 0
        var failed = 0
    }

    private let providers: [any MetadataFillProvider]
    private let ledger: MetadataFillLedger
    private let write: @MainActor (ImportedMetadata) -> Void
    private let now: @MainActor () -> Date

    init(providers: [any MetadataFillProvider], ledger: MetadataFillLedger,
         write: @escaping @MainActor (ImportedMetadata) -> Void, now: @escaping @MainActor () -> Date = Date.init) {
        self.providers = providers
        self.ledger = ledger
        self.write = write
        self.now = now
    }

    /// Fills `candidates`, least complete first, until `limit` copies have been asked or the
    /// task is cancelled.
    @discardableResult
    func fill(_ candidates: [MetadataFillCandidate], limit: Int? = nil) async -> Report {
        var report = Report()
        let ordered = candidates.enumerated().sorted {
            let (a, b) = (MetadataCompleteness.score(present: $0.element.present), MetadataCompleteness.score(present: $1.element.present))
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        for copy in ordered {
            if Task.isCancelled { break }
            if let limit, report.asked >= limit { break }
            let outcome = await fill(copy)
            if outcome.asked { report.asked += 1 }
            if outcome.filled { report.filled += 1 }
            if outcome.failed { report.failed += 1 }
        }
        return report
    }

    private func fill(_ copy: MetadataFillCandidate) async -> (asked: Bool, filled: Bool, failed: Bool) {
        var missing = copy.missing
        var asked = false, filled = false, failed = false
        for provider in providers {
            if Task.isCancelled { break }
            var wanted = missing
            if provider.grade == .b { wanted.remove(.cover) }
            guard !wanted.isEmpty else { continue }
            let query = MetadataFillQuery(copyID: copy.copyID, title: copy.title, authors: copy.authors,
                                          identifiers: copy.identifiers, missing: wanted)
            guard provider.canLookUp(query) else { continue }
            if let entry = ledger.entry(copyID: copy.copyID, provider: provider.key),
               !entry.shouldAskAgain(inputs: copy.inputs, now: now()) { continue }

            asked = true
            let result: MetadataFillResult
            do {
                result = try await provider.lookUp(query)
            } catch {
                AppLogger.cache("⟐ metadata lookup failed", error: error,
                                context: ["copy": copy.copyID.uuidString, "provider": "\(provider.key.type.rawValue):\(provider.key.id)"])
                ledger.record(copyID: copy.copyID, provider: provider.key, outcome: .failed, inputs: copy.inputs, at: now())
                failed = true
                continue
            }
            let at = now()
            let values = result.values
                .filter { wanted.contains($0.key) && !$0.value.isEmpty }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { MetadataValue(field: $0.key, value: $0.value, provider: provider.key, sourceItem: result.sourceItem, fetchedAt: at) }
            ledger.record(copyID: copy.copyID, provider: provider.key, outcome: values.isEmpty ? .empty : .found,
                          inputs: copy.inputs, at: at)
            guard !values.isEmpty else { continue }
            write(ImportedMetadata(copyID: copy.copyID, sourceItem: copy.sidecarSourceItem,
                                   identifiers: provider.grade == .a ? result.identifiers : [], values: values))
            missing.subtract(values.map(\.field))
            filled = true
            if missing.isEmpty { break }
        }
        return (asked, filled, failed)
    }
}

/// Which provider has been asked about which copy, and what it answered:
/// `Works/metadata-fill.json` beside the shelf. Derived data: deleting it only means asking
/// again.
@MainActor
final class MetadataFillLedger {
    enum Outcome: String, Codable, Sendable {
        case found, empty, failed
    }

    struct Entry: Hashable, Codable, Sendable {
        var outcome: Outcome
        var at: Date
        /// `MetadataFillCandidate.inputs` when it was asked.
        var inputs: String

        /// A failure is network or server trouble outside the app (an outage, a rate limit):
        /// it is asked again after a week. Found and empty answers stand until the copy's
        /// title, authors or identifiers change.
        func shouldAskAgain(inputs: String, now: Date) -> Bool {
            if inputs != self.inputs { return true }
            return outcome == .failed && now.timeIntervalSince(at) > MetadataFillLedger.failureRetryInterval
        }
    }

    nonisolated static let failureRetryInterval: TimeInterval = 7 * 86_400

    private let file: URL
    /// copy id → "type:id" of the provider → entry.
    private var entries: [String: [String: Entry]] = [:]

    init(worksDirectory: URL) {
        file = worksDirectory.appendingPathComponent("metadata-fill.json")
        load()
    }

    func entry(copyID: UUID, provider: SourceInstanceKey) -> Entry? {
        entries[copyID.uuidString]?[Self.name(provider)]
    }

    func record(copyID: UUID, provider: SourceInstanceKey, outcome: Outcome, inputs: String, at: Date) {
        entries[copyID.uuidString, default: [:]][Self.name(provider)] = Entry(outcome: outcome, at: at, inputs: inputs)
        save()
    }

    /// Drops the entries of copies no longer on the shelf.
    func keep(only copyIDs: Set<UUID>) {
        let kept = entries.filter { UUID(uuidString: $0.key).map(copyIDs.contains) ?? false }
        guard kept.count != entries.count else { return }
        entries = kept
        save()
    }

    private static func name(_ key: SourceInstanceKey) -> String { "\(key.type.rawValue):\(key.id)" }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            AppLogger.cache("⟐ metadata fill ledger could not be read", error: error)
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([String: [String: Entry]].self, from: data)
        } catch {
            // Kept aside so a later look can tell what went wrong; the fill starts over.
            let backup = file.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: file, to: backup)
                AppLogger.cache("⟐ unreadable metadata fill ledger kept aside as \(backup.lastPathComponent)", error: error)
            } catch let moveError {
                AppLogger.cache("⟐ unreadable metadata fill ledger could not be kept aside", error: moveError)
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch {
            AppLogger.cache("⟐ metadata fill ledger could not be saved", error: error)
        }
    }
}
