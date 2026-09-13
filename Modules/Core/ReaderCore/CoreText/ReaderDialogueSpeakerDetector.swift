import Foundation

/// Works out who is speaking a quoted line, from the narration around it.
///
/// Web fiction attributes speech in a handful of shapes — `張若塵道：「…」`,
/// `「…」張若塵冷冷地說`, `「…」齊源老道面露無奈` — so the name is read off the
/// narration that the bubble was split away from, never typed in by hand.
/// Nothing here is a parser: it is a reader's heuristic, and it says `nil` the
/// moment the sentence stops looking like an attribution.
enum ReaderDialogueSpeakerDetector {
    /// Verbs that mark the word before them as a speaker. Longest first, so
    /// `說道` is stripped before `說`.
    private static let speechVerbs = [
        "說道", "说道", "問道", "问道", "答道", "喊道", "叫道", "吼道", "喝道",
        "笑道", "嘆道", "叹道", "回道", "應道", "应道", "開口", "开口",
        "說", "说", "道", "問", "问", "答", "喊", "叫", "吼", "笑", "嘆", "叹",
    ]

    /// Manner adverbs and particles that sit between the name and its verb.
    private static let modifiers: Set<Character> = [
        "地", "的", "得", "大", "小", "又", "才", "便", "就", "也", "還", "还",
        "忙", "急", "連", "连", "冷", "淡", "微", "輕", "轻", "緩", "缓", "沉",
        "低", "高", "笑", "怒", "哼", "一", "再", "接", "著", "着", "續", "续",
    ]

    /// Particles that lead a manner phrase rather than a name — `的景象` is what the
    /// scene looked like, not who spoke.
    private static let leadingParticles: Set<Character> = ["的", "地", "得", "著", "着", "了"]

    /// A candidate ending in one of these is *how* someone spoke, not *who*: 小聲道,
    /// 低聲說, 朗聲笑 all left 小聲 / 低聲 / 朗聲 standing where a name should be, and the
    /// 多角色朗讀 cast list filled up with them.
    ///
    /// A name genuinely ending in 聲 exists (雷聲 as a nickname) but is far rarer than the
    /// adverb, and the cost is asymmetric: a missed attribution reads in the narrator's
    /// voice, while a bogus one puts a manner adverb in the cast.
    private static let mannerSuffixes: Set<Character> = ["聲", "声", "氣", "气", "音"]

    /// Words a name never contains; they mark the candidate as a clause.
    private static let functionWords: Set<Character> = [
        "沒", "没", "無", "无", "不", "這", "这", "那", "誰", "谁", "們", "们",
        "裡", "里", "中", "上", "下", "外", "有", "是", "了", "個", "个", "都",
    ]

    private static let separators = CharacterSet(charactersIn: "，,。.！!？?；;：:、…—－-·　 \t\n\r「」『』“”\"'()（）")

    /// Long enough for 齊源老道, short enough that a whole clause never becomes a
    /// label.
    private static let maximumNameLength = 4

    /// How far into the trailing narration an attribution may start.
    private static let searchWindow = 10

    /// - Parameters:
    ///   - before: narration immediately preceding the quote, in the same
    ///     paragraph. Usually where the attribution lives in Chinese fiction.
    ///   - after: narration immediately following it.
    /// - Parameter beforeIsSharedBeat: the narration before this quote sits
    ///   *between* two quotes of the same paragraph — `「甲，」某某說，「乙。」`.
    ///   Both halves are then the same person speaking, and the beat is known to
    ///   be the attribution even when it carries no speech verb at all
    ///   (`「甲，」齊源老道面露無奈，「乙。」`).
    static func speaker(
        before: String,
        after: String,
        beforeIsSharedBeat: Bool = false,
        afterIsSharedBeat: Bool = false
    ) -> String? {
        if beforeIsSharedBeat, let name = speakerFromActionBeat(before) { return name }
        // The same beat attributes the half *before* it too: in
        // `「甲，」齊源老道面露無奈，「乙。」` both quotes are his, so the first one
        // has to read the beat that follows it, not just the second.
        if afterIsSharedBeat, let name = speakerFromActionBeat(after) { return name }
        if let name = speakerFromLeadIn(before) { return name }
        return speakerFromTrailer(after)
    }

    /// A beat already known to be the attribution: the name is simply what it
    /// opens with, no verb required.
    private static func speakerFromActionBeat(_ text: String) -> String? {
        var body = text
        while let first = body.unicodeScalars.first, separators.contains(first) {
            body.removeFirst()
        }
        var name = ""
        for character in body {
            guard isNameCharacter(character), name.count < maximumNameLength else { break }
            name.append(character)
        }
        return validated(name)
    }

    /// `張若塵道：` / `齊源老道說道：` — the attribution runs into the quote, so the
    /// verb is at the very end and the name sits right before it.
    private static func speakerFromLeadIn(_ text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = body.unicodeScalars.last, separators.contains(last) {
            body.removeLast()
        }
        guard !body.isEmpty,
              let verb = speechVerbs.first(where: { body.hasSuffix($0) }) else {
            return nil
        }
        return name(in: String(body.dropLast(verb.count)))
    }

    /// `「…」張若塵道。` / `「…」池瑤冷冷地說。` — the attribution follows, so the
    /// name runs up to the first speech verb.
    private static func speakerFromTrailer(_ text: String) -> String? {
        var body = text
        while let first = body.unicodeScalars.first, separators.contains(first) {
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }
        // Only the opening of the sentence can carry the attribution; a verb
        // further in belongs to something else the narration is saying.
        let head = String(body.prefix(searchWindow))
        guard let verbStart = firstVerbStart(in: head), verbStart > head.startIndex else {
            return nil
        }
        return name(in: String(head[head.startIndex..<verbStart]))
    }

    /// Where the first speech verb begins, or `nil` if the window has none.
    ///
    /// A one-character verb only counts when the clause ends right after it.
    /// `道` is a verb in `張三道。` and a name in `齊源老道面露無奈` — without this
    /// the second one gets cut into "齊源老".
    private static func firstVerbStart(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            for verb in speechVerbs where rest.hasPrefix(verb) {
                let after = rest.dropFirst(verb.count)
                guard verb.count == 1 else { return index }
                if let next = after.first {
                    if !isNameCharacter(next) { return index }
                } else {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Trims the manner adverbs between the name and its verb (`冷冷地`, `大`),
    /// then accepts what is left only if it still looks like a name.
    private static func name(in candidate: String) -> String? {
        var characters = Array(candidate)
        while let last = characters.last, modifiers.contains(last) {
            characters.removeLast()
        }
        while let last = characters.last, !isNameCharacter(last) {
            characters.removeLast()
        }
        var name: [Character] = []
        for character in characters.reversed() {
            guard isNameCharacter(character) else { break }
            name.insert(character, at: 0)
        }
        return validated(String(name))
    }

    /// A real attribution names someone in a few characters. Anything longer is
    /// a clause that happens to contain a speech verb — `屋裡沒有人回答`.
    private static func validated(_ name: String) -> String? {
        var characters = Array(name)
        // Leading particles belong to the phrase, not the name.
        while let first = characters.first, leadingParticles.contains(first) {
            characters.removeFirst()
        }
        guard !characters.isEmpty, characters.count <= maximumNameLength else { return nil }
        guard let last = characters.last, !mannerSuffixes.contains(last) else { return nil }
        guard !characters.contains(where: { functionWords.contains($0) }) else { return nil }
        return String(characters)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return true   // CJK
        case 0x00B7, 0x2022: return true                     // ·
        default: return false
        }
    }

    private static func normalized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1, trimmed.count <= maximumNameLength else { return nil }
        return trimmed
    }
}
