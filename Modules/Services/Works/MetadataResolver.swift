import Foundation

/// Unified library 1d: each field's effective value, and where it came from (design §8.1,
/// D6). Pure; the caller passes the copy's own value, the sidecar's values and the decisions.
enum MetadataResolver {
    /// Where an effective value came from.
    enum Provenance: Hashable, Sendable {
        /// The reader typed it (`WorkDecision.override`).
        case override(decidedAt: Date)
        /// Frozen by a lock. For title and authors the value is the copy's own.
        case lock(decidedAt: Date)
        /// The reader picked this record's value (`WorkDecision.chooseCandidate`).
        case chosen(SourceItemKey)
        /// The copy itself (`ReadingBook`).
        case copy
        /// A place's value from the sidecar.
        case provider(SourceInstanceKey, sourceItem: SourceItemKey?, fetchedAt: Date)
    }

    struct Resolved: Hashable, Sendable {
        var value: MetadataPayload
        var provenance: Provenance
    }

    /// Fields `ReadingBook` holds. Its own value comes before any place's (design §8.1:
    /// title and authors never fill in from elsewhere; a cover only from a bibliographic
    /// database, and only when the copy has none).
    static let copyHeldFields: Set<MetadataField> = [.title, .authors, .cover]

    /// The precedence: override > lock > chosen candidate > field priority > the copy.
    ///
    /// - `anchor`: the copy's key (`SourceItemKey.copy`), so decisions survive 換源.
    /// - `copyValue`: what `ReadingBook` holds for the field, if anything.
    /// - `values`: the sidecar's values for this copy.
    /// - `bibliographicIsALevel`: whether a bibliographic database's record matched this
    ///   copy by identifier. Only then may its values fill in (design §8.1); nothing in
    ///   Phase 1 produces them.
    static func resolve(
        _ field: MetadataField,
        anchor: SourceItemKey,
        copySource: SourceInstanceKey,
        copyValue: MetadataPayload?,
        values: [MetadataValue],
        decisions: [WorkDecision],
        bibliographicIsALevel: Bool = false
    ) -> Resolved? {
        for decision in decisions {
            if case .override(let a, let f, let value, let at) = decision, a == anchor, f == field {
                return Resolved(value: value, provenance: .override(decidedAt: at))
            }
        }
        for decision in decisions {
            guard case .lock(let a, let f, let frozen, let at) = decision, a == anchor, f == field else { continue }
            if field == .title || field == .authors {
                // The automatic paths never write a locked copy, so its value is the frozen one.
                return copyValue.map { Resolved(value: $0, provenance: .lock(decidedAt: at)) }
            }
            return frozen.map { Resolved(value: $0, provenance: .lock(decidedAt: at)) }
        }
        for decision in decisions {
            guard case .chooseCandidate(let a, let f, let from, _) = decision, a == anchor, f == field else { continue }
            let chosen = values
                .filter { $0.field == field && $0.sourceItem == from }
                .max { $0.fetchedAt < $1.fetchedAt }
            if let chosen { return Resolved(value: chosen.value, provenance: .chosen(from)) }
            // The chosen record's value is gone (removed, or not fetched yet): fall through.
        }

        if copyHeldFields.contains(field), let copyValue {
            return Resolved(value: copyValue, provenance: .copy)
        }
        if field == .title || field == .authors { return nil }

        let ranked = values
            .filter { $0.field == field && (bibliographicIsALevel || $0.provider.type != .bibliographic) }
            .sorted { rank($0, copySource: copySource) < rank($1, copySource: copySource) }
        if let best = ranked.first {
            return Resolved(value: best.value, provenance: .provider(best.provider, sourceItem: best.sourceItem, fetchedAt: best.fetchedAt))
        }
        return copyValue.map { Resolved(value: $0, provenance: .copy) }
    }

    /// What the copy's own file said, then the place the copy came from, then other places,
    /// then bibliographic databases; within one rank the newest value, then the place's key.
    private static func rank(_ value: MetadataValue, copySource: SourceInstanceKey) -> (Int, Double, String) {
        let tier: Int
        if value.provider == .localLibrary { tier = 0 }
        else if value.provider == copySource { tier = 1 }
        else if value.provider.type == .bibliographic { tier = 3 }
        else { tier = 2 }
        return (tier, -value.fetchedAt.timeIntervalSinceReferenceDate, "\(value.provider.type.rawValue)\u{1F}\(value.provider.id)")
    }
}

extension WorkDecisionsStore {
    /// Locks a field on a copy. For a field `ReadingBook` does not hold, the value in effect
    /// now is frozen into the lock.
    func lock(_ field: MetadataField, anchor: SourceItemKey, effective: MetadataResolver.Resolved?, at date: Date = Date()) {
        let frozen = (field == .title || field == .authors) ? nil : effective?.value
        record(.lock(anchor: anchor, field: field, value: frozen, decidedAt: date))
    }

    func unlock(_ field: MetadataField, anchor: SourceItemKey) {
        remove {
            if case .lock(let a, let f, _, _) = $0 { return a == anchor && f == field }
            return false
        }
    }
}
