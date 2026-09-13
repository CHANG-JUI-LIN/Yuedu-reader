//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Retrieval/RAGSelfAssessment.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// The model's own verdict on whether the retrieved passages were enough to answer.
///
/// This is what turns a cheap one-shot answer into a bounded agentic one only when it is
/// actually needed, instead of running the expensive path on every question.
struct AISelfAssessment: Sendable, Equatable {
    static let controlPrefix = "[[SELFASSESS:"

    enum State: String, Sendable, Equatable {
        case full
        case partial
        case insufficient
        /// The envelope was present but did not parse — treated as no verdict, never as `full`.
        case malformed
        case absent
    }

    let state: State
    let missing: String?

    init(state: State, missing: String? = nil) {
        self.state = state
        self.missing = missing
    }

    /// The display boundary for non-streaming paths: everything from the control marker on is
    /// diagnostics, never UI.
    static func userVisibleText(_ text: String) -> String {
        guard let marker = text.range(of: controlPrefix) else { return text }
        return String(text[..<marker.lowerBound])
    }
}

/// Strips the private assessment envelope out of a streaming answer without ever letting a
/// sentinel byte reach the UI.
///
/// The hard part is that a marker can be split across two SSE deltas. The parser holds back
/// only the longest suffix that could still be the start of a marker, so text flows as it
/// arrives and `[[SELFASS` never flashes on screen. The nonce makes a collision with book
/// text — a novel that happens to contain `[[SELFASSESS:` — negligible.
struct AISelfAssessmentStreamParser: Sendable {
    private let startMarker: String
    private let endMarker: String
    private var pending = ""
    private var payload = ""
    private var trailing = ""
    private var foundMarker = false
    private var completedMarker = false

    init(nonce: String) {
        startMarker = "[[SELFASSESS:\(nonce)]]"
        endMarker = "[[/SELFASSESS:\(nonce)]]"
    }

    /// Body text that is safe to publish right now.
    mutating func consume(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        if completedMarker {
            trailing += delta
            return ""
        }
        if foundMarker {
            pending += delta
            if let endRange = pending.range(of: endMarker) {
                payload += pending[..<endRange.lowerBound]
                trailing = String(pending[endRange.upperBound...])
                pending = ""
                completedMarker = true
            }
            return ""
        }

        pending += delta
        if let markerRange = pending.range(of: startMarker) {
            let body = String(pending[..<markerRange.lowerBound])
            pending = String(pending[markerRange.upperBound...])
            foundMarker = true
            if let endRange = pending.range(of: endMarker) {
                payload = String(pending[..<endRange.lowerBound])
                trailing = String(pending[endRange.upperBound...])
                pending = ""
                completedMarker = true
            }
            return body
        }

        // A control block with the wrong nonce is still a control block: hide it and let
        // `finish()` call the result malformed, rather than printing it as prose.
        if let markerRange = pending.range(of: AISelfAssessment.controlPrefix) {
            let suffix = pending[markerRange.upperBound...]
            if let openingEnd = suffix.range(of: "]]") {
                let body = String(pending[..<markerRange.lowerBound])
                pending = String(suffix[openingEnd.upperBound...])
                foundMarker = true
                return body
            }
            let body = String(pending[..<markerRange.lowerBound])
            pending = String(pending[markerRange.lowerBound...])
            return body
        }

        let retained = longestMarkerPrefixSuffixLength(in: pending)
        let emitEnd = pending.index(pending.endIndex, offsetBy: -retained)
        let body = String(pending[..<emitEnd])
        pending = String(pending[emitEnd...])
        return body
    }

    /// Flushes the tail and validates the envelope. Call exactly once, when the stream ends.
    mutating func finish() -> (body: String, assessment: AISelfAssessment) {
        guard foundMarker else {
            defer { pending = "" }
            if pending.contains(AISelfAssessment.controlPrefix)
                || (pending.count >= 2 && startMarker.hasPrefix(pending)) {
                return ("", AISelfAssessment(state: .malformed))
            }
            return (pending, AISelfAssessment(state: .absent))
        }
        guard completedMarker else {
            pending = ""
            return ("", AISelfAssessment(state: .malformed))
        }
        guard trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.contains(startMarker),
              payload.utf8.count <= 240,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["sufficient", "missing"]),
              let rawState = object["sufficient"] as? String,
              let state = AISelfAssessment.State(rawValue: rawState),
              state != .malformed, state != .absent
        else {
            return ("", AISelfAssessment(state: .malformed))
        }
        guard object["missing"] == nil || object["missing"] is String else {
            return ("", AISelfAssessment(state: .malformed))
        }
        let missing = (object["missing"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (missing?.count ?? 0) <= 40 else {
            return ("", AISelfAssessment(state: .malformed))
        }
        return ("", AISelfAssessment(state: state, missing: missing?.isEmpty == true ? nil : missing))
    }

    private func longestMarkerPrefixSuffixLength(in text: String) -> Int {
        let maximum = min(text.count, max(0, startMarker.count - 1))
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) where
            text.suffix(length) == startMarker.prefix(length) {
            return length
        }
        return 0
    }
}
