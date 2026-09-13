//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Assistant/CharacterProfile.swift and
// Sources/ChatBookCore/Assistant/AssistantJSONFencing.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Strips the ``` fences a model puts around JSON when it was asked not to.
enum AIJSONFencing {
    static func stripFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let newline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: newline)...])
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A character card: who someone is, who they know, and — the part multi-role narration needs
/// — what else the book calls them.
///
/// **`aliasCandidates` is the only place the AI and the TTS work meet.** The dialogue
/// attribution heuristic cannot know that 張若塵, 若塵 and 塵哥 are one person, so without
/// this it casts three voices for one character. Everything else here is for the reader.
///
/// Source scope is persisted; only verified cards within the reading boundary supply safe aliases.
struct AICharacterProfile: Sendable, Equatable, Codable {
    let name: String
    /// First appearance, as the model summarised it from passages; `nil` when unsupported.
    let firstAppearance: String?
    let role: String?
    let relationships: [String]
    /// Other names the book uses for this character — fed back to 多角色朗讀 so they share
    /// one voice. Never includes `name` itself.
    let aliasCandidates: [String]
    let summary: String
    /// Chunks the card was built from, so every claim can be jumped back to.
    let citationChunkIDs: [String]
    let provider: String
    let model: String
    /// Prompt version this particular card was made with, so a later recipe change can tell
    /// old cards apart instead of silently mixing them.
    let promptVersion: String

    var sourceBoundary: AIReadingBoundary? = nil
    var maximumEvidencePosition: AIChunkLocation? = nil
    var retrievedEvidenceIDs: [String]? = nil

    func isSafe(at boundary: AIReadingBoundary) -> Bool {
        guard let sourceBoundary, let maximumEvidencePosition,
              !sourceBoundary.wholeBook, boundary.contains(sourceBoundary),
              retrievedEvidenceIDs?.isEmpty == false else { return false }
        return boundary.allows(maximumEvidencePosition)
    }

    static let currentPromptVersion = "yuedu.character.v2"

    /// The task, with the character's name kept **out** of it.
    ///
    /// The name arrives as a separate user message. Splicing user- or book-supplied text into
    /// the system role would let a novel containing something shaped like an instruction
    /// rewrite the rules it is being read under.
    static let task = """
    整理指定人物在本書中的檔案。可用工具 retrieve(query) 檢索本書片段（進度範圍 [0, 1.0]＝全書）。
    規則：不要透露該人物的最終結局或生死；可以說明身分、人物關係、首次登場。只依據檢索到的片段，不要編造；沒有依據的欄位留空。
    資訊足夠後 action=finish，並把**純 JSON**（不要加程式碼區塊標記）放進 answer：
    {"firstAppearance":string,"role":string,"relationships":[string],"aliasCandidates":[string],"summary":string}
    - summary：繁體中文檔案（不含結局）。
    - aliasCandidates：本書中可能指同一人的別稱（不含人物名本身）。
    """

    private struct Fields: Decodable {
        let firstAppearance: String?
        let role: String?
        let relationships: [String]
        let aliasCandidates: [String]
        let summary: String
    }

    /// Invalid schemas fail before persistence; previous valid cards remain available.
    static func parse(
        fromAnswer answer: String,
        name: String,
        gatheredChunkIDs: [String],
        provider: String,
        model: String,
        citedChunkIDs: [String] = []
    ) throws -> AICharacterProfile {
        let started = Date()
        defer { AIDiagnostics.current?.event("characterParseDuration", ["elapsedMs": "\(Date().timeIntervalSince(started) * 1000)"]) }
        let cleaned = AIJSONFencing.stripFences(answer)
        if let data = cleaned.data(using: .utf8),
           let fields = try? JSONDecoder().decode(Fields.self, from: data),
           !fields.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AICharacterProfile(
                name: name,
                firstAppearance: fields.firstAppearance?.nilIfBlank,
                role: fields.role?.nilIfBlank,
                relationships: fields.relationships.compactMap(\.nilIfBlank),
                aliasCandidates: Self.normalizedAliases(fields.aliasCandidates, excluding: name),
                summary: fields.summary,
                citationChunkIDs: Array(Set(citedChunkIDs).intersection(gatheredChunkIDs)).sorted(),
                provider: provider,
                model: model,
                promptVersion: currentPromptVersion
            )
        }
        AIDiagnostics.current?.event("characterParsing", ["result": "invalidSchema"])
        throw LLMError.invalidSchema
    }

    /// Trims, de-duplicates, and drops the character's own name — models return it often, and
    /// keeping it would make the name an alias of itself.
    static func normalizedAliases(_ raw: [String], excluding name: String) -> [String] {
        let own = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = [own]
        var out: [String] = []
        for candidate in raw {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Every name this character answers to, the canonical one first.
    var allNames: [String] { [name] + aliasCandidates }
}

/// Folds a book's character cards into the alias table 多角色朗讀 casts voices against.
///
/// The map is alias → canonical name, so `TTSSpeakerAnnotator` can resolve whatever the
/// prose calls someone back to the character the user cast.
enum AICharacterAliasTable {
    /// - Note: when two characters claim the same alias it is dropped from both. Guessing
    ///   would put two people on one voice, which is worse than leaving the ambiguous name
    ///   attributed to nobody and read by the narrator.
    static func aliasMap(for profiles: [AICharacterProfile]) -> [String: String] {
        var owners: [String: Set<String>] = [:]
        for profile in profiles {
            for alias in profile.allNames {
                owners[alias, default: []].insert(profile.name)
            }
        }
        var map: [String: String] = [:]
        for (alias, claimants) in owners where claimants.count == 1 {
            guard let owner = claimants.first else { continue }
            map[alias] = owner
        }
        return map
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
