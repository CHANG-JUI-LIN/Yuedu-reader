import Foundation

/// Turns the dialogue heuristic's raw output into a roster of actual people.
///
/// The heuristic reads a name by stripping a speech verb off the end of the narration, which
/// is right often enough to be useful and wrong in ways no stop-list can fix: `試探道` leaves
/// 試探, `一邊道` leaves 一邊, `劉癩子苦笑道` leaves 劉癩子苦. Chinese has hundreds of these
/// shapes, and every character added to a blocklist is one specific novel patched.
///
/// So the judgement is handed to the model, which is the one component here that actually
/// knows what a Chinese name looks like. It answers two questions at once:
/// - is this candidate a person at all?
/// - if it is a person under a slightly mangled or shortened form, what is their real name?
///
/// The result is one map, used everywhere a speaker is resolved: 試探 → dropped,
/// 劉癩子苦 → 劉癩子, 若塵 → 張若塵.
enum AISpeakerRoster {
    static let promptVersion = "yuedu.roster.v1"

    /// A candidate, with one line of the prose it was read out of.
    ///
    /// The context is what lets the model tell 一邊 (an adverb swallowed by `一邊道`) from a
    /// genuine two-character name — the candidate alone is ambiguous.
    struct Candidate: Sendable, Equatable {
        let name: String
        let lineCount: Int
        /// A short excerpt containing the attribution, trimmed by the caller.
        let sample: String
    }

    static let task = """
    下面是從一本中文小說裡，用「把說話動詞從敘述尾巴剝掉」的方式自動抓出來的說話人候選詞。
    這個方法會抓錯：「試探道」會留下「試探」、「一邊道」會留下「一邊」、「劉癩子苦笑道」會留下「劉癩子苦」。

    請判斷每個候選詞：
    - 不是人（是動詞、副詞、狀態、場景、殘缺片段）→ 值填空字串 ""。
    - 是人但名字被切壞或只是簡稱 → 值填這本書裡的完整正式名字。
    - 是人而且候選詞本身就是正式名字 → 值填它自己。
    同一個人的不同稱呼（全名、小名、綽號）要指向同一個正式名字。

    只輸出**純 JSON**（不要程式碼區塊標記、不要解釋）：
    {"names":{"候選詞":"正式名字或空字串", ...}}
    每個候選詞都要出現在結果裡。
    """

    private struct Answer: Decodable {
        let names: [String: String]?
    }

    static func request(candidates: [Candidate]) -> LLMGenerationRequest {
        let listing = candidates
            .map { "\($0.name)（\($0.lineCount) 句）：\($0.sample)" }
            .joined(separator: "\n")
        return LLMGenerationRequest(
            messages: [
                LLMMessage(role: .system, content: task),
                // The candidates and their prose are book text, so they go in the user role.
                LLMMessage(role: .user, content: listing),
            ],
            maxTokens: 2048,
            temperature: 0,
            topP: 1.0
        )
    }

    /// Parses the model's answer into candidate → canonical name.
    ///
    /// A candidate the model did not mention is **kept as itself** rather than dropped: a
    /// truncated or lazy answer must not silently delete characters the reader already cast.
    static func parse(_ answer: String, candidates: [String]) -> [String: String] {
        let cleaned = AIJSONFencing.stripFences(answer)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Answer.self, from: data),
              let names = decoded.names
        else {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0, $0) })
        }
        var roster: [String: String] = [:]
        for candidate in candidates {
            guard let verdict = names[candidate] else {
                roster[candidate] = candidate
                continue
            }
            let canonical = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty verdict is the model saying "not a person" — the entry is left out,
            // and that name then reads in the narrator's voice.
            guard !canonical.isEmpty else { continue }
            roster[candidate] = canonical
        }
        return roster
    }

    /// Builds the roster in one call.
    static func build(
        candidates: [Candidate],
        provider: any LLMProviding
    ) async throws -> [String: String] {
        guard !candidates.isEmpty else { return [:] }
        let raw = try await provider.generate(request(candidates: candidates))
        try raw.validateCompletion()
        let cleaned = AIJSONFencing.stripFences(raw.content)
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Answer.self, from: data),
              let names = decoded.names, candidates.allSatisfy({ names[$0.name] != nil }) else {
            AIDiagnostics.current?.event("rosterParsing", ["result": "invalidSchema"])
            throw LLMError.invalidSchema
        }
        AIDiagnostics.current?.event("rosterParsing", ["result": "valid", "candidates": "\(candidates.count)"])
        return parse(raw.content, candidates: candidates.map(\.name))
    }
}
