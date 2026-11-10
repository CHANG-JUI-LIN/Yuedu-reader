import Foundation

/// What a character sounds like, as far as choosing a voice for them goes.
enum TTSVoiceGender: String, Codable, Sendable, CaseIterable {
    case male, female, unknown
}

enum TTSVoiceAge: String, Codable, Sendable, CaseIterable {
    case child, young, adult, elder, unknown
}

/// The emotion one quoted line is spoken with.
///
/// Each engine renders it as well as it can: Azure as a real speaking style, OpenAI and
/// MiMo as words in their instructions, an imported source through `{{emotion}}`, and the
/// engines that cannot act (Microsoft's free voice, the on-device one) as rate, pitch and
/// volume — audible, but an approximation.
enum TTSEmotion: String, Codable, Sendable, CaseIterable {
    case neutral, happy, sad, angry, fearful, surprised, gentle, cold, whisper, shout, serious, playful
}

/// How one line is delivered: the emotion, how strongly, and what the voices that follow
/// instructions are told.
struct TTSDelivery: Codable, Equatable, Hashable, Sendable {
    var emotion: TTSEmotion
    /// 1 mild, 2 clear, 3 strong.
    var intensity: Int
    /// A one-line direction in the book's language, for voices that take instructions.
    var instruct: String?
    /// Who is speaking ("年長男性，沉穩低沉"), for voices that act a persona from words.
    var persona: String?

    init(emotion: TTSEmotion, intensity: Int = 2, instruct: String? = nil, persona: String? = nil) {
        self.emotion = emotion
        self.intensity = min(max(intensity, 1), 3)
        self.instruct = instruct
        self.persona = persona
    }

    /// Nothing for an engine to do: no emotion, nothing to say about the line.
    var isNeutral: Bool {
        emotion == .neutral && (instruct?.isEmpty ?? true)
    }

    /// The emotion in words, for instruction-following voices and `{{emotion}}`.
    var emotionDescription: String {
        let strength: String
        switch intensity {
        case 1: strength = "輕微"
        case 3: strength = "強烈"
        default: strength = "明顯"
        }
        let name: String
        switch emotion {
        case .neutral: return "平靜自然"
        case .happy: name = "開心"
        case .sad: name = "悲傷"
        case .angry: name = "生氣"
        case .fearful: name = "害怕"
        case .surprised: name = "驚訝"
        case .gentle: name = "溫柔"
        case .cold: name = "冷淡"
        case .whisper: name = "低聲耳語"
        case .shout: name = "大聲喊叫"
        case .serious: name = "嚴肅"
        case .playful: name = "俏皮"
        }
        return "\(strength)\(name)"
    }
}

/// Rate, pitch and volume offsets in percent, for engines that cannot act an emotion.
struct TTSProsody: Equatable, Sendable {
    var ratePercent: Int
    var pitchPercent: Int
    var volumePercent: Int

    static let zero = TTSProsody(ratePercent: 0, pitchPercent: 0, volumePercent: 0)

    /// The closest prosody to `delivery`. Deliberately modest: past about ±15% a neural
    /// voice stops sounding like a person being angry and starts sounding broken.
    static func approximating(_ delivery: TTSDelivery?) -> TTSProsody {
        guard let delivery else { return .zero }
        let base: (rate: Double, pitch: Double, volume: Double)
        switch delivery.emotion {
        case .neutral: return .zero
        case .happy: base = (6, 6, 5)
        case .sad: base = (-10, -6, -10)
        case .angry: base = (8, 4, 15)
        case .fearful: base = (10, 8, -5)
        case .surprised: base = (6, 12, 8)
        case .gentle: base = (-6, -2, -8)
        case .cold: base = (-4, -6, -5)
        case .whisper: base = (-10, -4, -35)
        case .shout: base = (10, 10, 25)
        case .serious: base = (-4, -4, 0)
        case .playful: base = (6, 8, 3)
        }
        let scale: Double
        switch delivery.intensity {
        case 1: scale = 0.5
        case 3: scale = 1.5
        default: scale = 1
        }
        return TTSProsody(
            ratePercent: Int((base.rate * scale).rounded()),
            pitchPercent: Int((base.pitch * scale).rounded()),
            volumePercent: Int((base.volume * scale).rounded())
        )
    }
}

/// One character the AI found speaking in a book.
struct TTSDialogueCharacter: Codable, Equatable, Sendable {
    let name: String
    /// Other spellings the model mapped onto `name`, as the book writes them.
    var aliases: [String]
    var gender: TTSVoiceGender
    var age: TTSVoiceAge
    /// A few words about the voice ("沉穩低沉"), from the prose.
    var voiceNote: String?
    /// Lines attributed so far. Decides who gets a voice of their own first.
    var lineCount: Int
    /// Chapter the character first spoke in. The cast screen only lists characters from
    /// chapters already reached, so analysing ahead never spoils who appears next.
    var firstChapter: Int

    /// Words an instruction-following voice can act from.
    var persona: String? {
        var parts: [String] = []
        switch (age, gender) {
        case (.child, .male): parts.append("小男孩")
        case (.child, .female): parts.append("小女孩")
        case (.young, .male): parts.append("年輕男性")
        case (.young, .female): parts.append("年輕女性")
        case (.adult, .male): parts.append("成年男性")
        case (.adult, .female): parts.append("成年女性")
        case (.elder, .male): parts.append("年長男性")
        case (.elder, .female): parts.append("年長女性")
        case (_, .male): parts.append("男性")
        case (_, .female): parts.append("女性")
        default: break
        }
        if let voiceNote, !voiceNote.isEmpty { parts.append(voiceNote) }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
}

/// A line that closed a chapter, carried into the next chapter's request so dialogue that
/// runs across the boundary keeps its speakers.
struct TTSDialogueTailLine: Codable, Equatable, Sendable {
    let speaker: String?
    let text: String
}

/// Everything the AI has worked out about one book's cast.
struct TTSDialogueRoster: Codable, Equatable, Sendable {
    var characters: [TTSDialogueCharacter] = []
    /// `"<family>\u{1F}<name>"` → `TTSRoleVoice.storageValue`. Kept apart from the reader's own
    /// choices (`GlobalSettings.ttsRoleVoices`): an automatic pick is replaced the moment the
    /// reader chooses, and clearing the book's AI data must not touch what they chose.
    var autoVoices: [String: String] = [:]
    var tails: [Int: [TTSDialogueTailLine]] = [:]

    static func autoVoiceKey(family: String, speaker: String) -> String {
        "\(family)\u{1F}\(speaker)"
    }

    func character(named name: String) -> TTSDialogueCharacter? {
        characters.first { $0.name == name }
    }

    /// alias → canonical name, from what the model has mapped so far.
    var aliasMap: [String: String] {
        var map: [String: String] = [:]
        for character in characters {
            map[character.name] = character.name
            for alias in character.aliases where map[alias] == nil {
                map[alias] = character.name
            }
        }
        return map
    }

    /// Folds one analysed chapter into the roster.
    ///
    /// A character keeps the gender and age it was first given unless that was unknown — a
    /// later chapter that cannot tell must not erase what an earlier one could.
    mutating func merge(
        chapter: TTSChapterDialogue,
        characters found: [TTSDialogueCharacter],
        tail: [TTSDialogueTailLine],
        keepingTails maximumTails: Int = 24
    ) {
        var counts: [String: Int] = [:]
        for line in chapter.lines {
            guard let speaker = line.speaker else { continue }
            counts[speaker, default: 0] += 1
        }
        for name in chapter.speakers {
            let incoming = found.first { $0.name == name }
            if let index = characters.firstIndex(where: { $0.name == name }) {
                var existing = characters[index]
                existing.lineCount += counts[name] ?? 0
                if existing.gender == .unknown, let gender = incoming?.gender { existing.gender = gender }
                if existing.age == .unknown, let age = incoming?.age { existing.age = age }
                if existing.voiceNote?.isEmpty ?? true { existing.voiceNote = incoming?.voiceNote }
                for alias in incoming?.aliases ?? [] where alias != name && !existing.aliases.contains(alias) {
                    existing.aliases.append(alias)
                }
                existing.firstChapter = min(existing.firstChapter, chapter.chapterIndex)
                characters[index] = existing
            } else {
                characters.append(TTSDialogueCharacter(
                    name: name,
                    aliases: incoming?.aliases.filter { $0 != name } ?? [],
                    gender: incoming?.gender ?? .unknown,
                    age: incoming?.age ?? .unknown,
                    voiceNote: incoming?.voiceNote,
                    lineCount: counts[name] ?? 0,
                    firstChapter: chapter.chapterIndex
                ))
            }
        }
        tails[chapter.chapterIndex] = tail
        if tails.count > maximumTails {
            for key in tails.keys.sorted().dropLast(maximumTails) { tails.removeValue(forKey: key) }
        }
    }
}

/// One chapter, as the AI attributed it.
struct TTSChapterDialogue: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable {
        /// UTF-16 range in the chapter's full narration text.
        let location: Int
        let length: Int
        /// `nil`: narration voice — the model could not tell, or the quote is not speech.
        let speaker: String?
        let delivery: TTSDelivery?
    }

    /// Digest of the narration text and the recipe; a different text is a different chapter.
    let key: String
    let chapterIndex: Int
    let includesInstruct: Bool
    let lines: [Line]
    let provider: String
    let model: String
    let promptVersion: String

    /// Speakers in the order they first speak.
    var speakers: [String] {
        var seen: Set<String> = []
        return lines.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }

    var attributedLineCount: Int { lines.filter { $0.speaker != nil }.count }

    /// The lines as the engines want them, for a narration that may start part-way into the
    /// chapter (`startCharOffset`). A line cut by the start is dropped rather than half-voiced.
    func attributions(
        droppingPrefix offset: Int = 0,
        textLength: Int,
        persona: (String) -> String? = { _ in nil }
    ) -> [TTSSpeakerAnnotator.Attribution] {
        lines.compactMap { line in
            guard line.location >= offset else { return nil }
            let range = NSRange(location: line.location - offset, length: line.length)
            guard range.length > 0, NSMaxRange(range) <= textLength else { return nil }
            var delivery = line.delivery
            if let speaker = line.speaker, let persona = persona(speaker) {
                if delivery == nil { delivery = TTSDelivery(emotion: .neutral, intensity: 1) }
                delivery?.persona = persona
            }
            return TTSSpeakerAnnotator.Attribution(range: range, speaker: line.speaker, delivery: delivery)
        }
    }

    /// The last few lines, for the next chapter's request.
    func tail(in text: String, count: Int = 3) -> [TTSDialogueTailLine] {
        let ns = text as NSString
        return lines.suffix(count).compactMap { line in
            let range = NSRange(location: line.location, length: line.length)
            guard NSMaxRange(range) <= ns.length else { return nil }
            return TTSDialogueTailLine(speaker: line.speaker, text: String(ns.substring(with: range).prefix(60)))
        }
    }
}
