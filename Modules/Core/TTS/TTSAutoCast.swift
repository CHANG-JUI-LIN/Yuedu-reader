import AVFoundation
import Foundation

/// A voice automatic casting may hand a character.
struct TTSVoiceCandidate: Equatable, Sendable {
    /// `TTSRoleVoice.storageValue`.
    let storageValue: String
    let gender: TTSVoiceGender
    /// `.unknown` when the catalogue does not say.
    let age: TTSVoiceAge
}

/// Picks voices for the characters nobody cast.
enum TTSAutoCast {
    /// New picks only. A character that already has a voice — chosen by the reader or picked
    /// earlier — keeps it: a voice that changes between chapters is worse than one that is
    /// merely imperfect.
    ///
    /// Characters with the most lines choose first, so the main cast gets voices of its own and
    /// sharing, when the catalogue runs out, falls on minor characters. A character whose gender
    /// the book never made clear gets nothing and stays with the narrator, which is better than
    /// a coin-flip voice. The narrator's own voice is never handed out.
    static func assign(
        characters: [TTSDialogueCharacter],
        explicit: [String: String],
        existing: [String: String],
        candidates: [TTSVoiceCandidate],
        narrator: String?
    ) -> [String: String] {
        let available = Set(candidates.map(\.storageValue))
        var usage: [String: Int] = [:]
        for value in explicit.values where available.contains(value) {
            usage[value, default: 0] += 1
        }
        for (name, value) in existing where explicit[name] == nil && available.contains(value) {
            usage[value, default: 0] += 1
        }

        let order = characters.enumerated().sorted { lhs, rhs in
            if lhs.element.lineCount != rhs.element.lineCount {
                return lhs.element.lineCount > rhs.element.lineCount
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var assigned: [String: String] = [:]
        for character in order {
            guard explicit[character.name] == nil, character.gender != .unknown else { continue }
            if let current = existing[character.name], available.contains(current) { continue }
            var pool = candidates.filter { $0.gender == character.gender && $0.storageValue != narrator }
            // A child's voice is for children only; a child gets one whenever there is one.
            if character.age == .child, pool.contains(where: { $0.age == .child }) {
                pool = pool.filter { $0.age == .child }
            } else {
                pool = pool.filter { $0.age != .child }
            }
            guard let chosen = pool.enumerated().min(by: { lhs, rhs in
                let leftUse = usage[lhs.element.storageValue, default: 0]
                let rightUse = usage[rhs.element.storageValue, default: 0]
                if leftUse != rightUse { return leftUse < rightUse }
                let leftMatch = lhs.element.age == character.age
                let rightMatch = rhs.element.age == character.age
                if leftMatch != rightMatch { return leftMatch }
                return lhs.offset < rhs.offset
            })?.element else { continue }
            assigned[character.name] = chosen.storageValue
            usage[chosen.storageValue, default: 0] += 1
        }
        return assigned
    }
}

/// The voices of the running engine that can share a cast with its narrator.
@MainActor
enum TTSVoiceCandidates {
    struct Pool: Equatable {
        let candidates: [TTSVoiceCandidate]
        /// The narrator's voice as a `TTSRoleVoice.storageValue`, never handed to a character.
        let narrator: String?
    }

    /// - Parameter sampleText: the chapter's text, which decides the on-device narrator voice
    ///   (the system engine picks it per language).
    static func make(family: TTSVoiceFamily, sampleText: String) -> Pool {
        let settings = GlobalSettings.shared
        switch family {
        case .system:
            let narrator = SystemTTSEngine.preferredVoice(for: sampleText)
            let group = TTSLanguageGroup.of(locale: narrator?.language ?? "")
            let voices = SystemTTSVoiceCatalog.installedVoices()
                .filter { TTSLanguageGroup.of(locale: $0.language) == group }
                .filter { !SystemTTSVoiceCatalog.isNoveltyVoice($0) && !SystemTTSVoiceCatalog.isPersonalVoice($0) }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }
            return Pool(
                candidates: voices.map { voice in
                    TTSVoiceCandidate(
                        storageValue: TTSRoleVoice.system(identifier: voice.identifier).storageValue,
                        gender: gender(of: voice),
                        age: .unknown
                    )
                },
                narrator: narrator.map { TTSRoleVoice.system(identifier: $0.identifier).storageValue }
            )
        case .edge:
            let narrator = EdgeTTSVoice.voice(sourceIdentifier: settings.httpTtsUrlTemplate)
            let group = narrator?.languageGroup ?? "cmn"
            return Pool(
                candidates: EdgeTTSVoice.voices.filter { $0.languageGroup == group }.map {
                    TTSVoiceCandidate(
                        storageValue: TTSRoleVoice.edge(voiceID: $0.id).storageValue,
                        gender: $0.gender,
                        age: $0.age
                    )
                },
                narrator: narrator.map { TTSRoleVoice.edge(voiceID: $0.id).storageValue }
            )
        case .azure:
            let narrator = AzureTTSVoiceRef(storage: CloudTTSService.voiceID(inSourceIdentifier: settings.httpTtsUrlTemplate))
            let group = TTSLanguageGroup.of(locale: narrator.locale)
            let voices = AzureTTSVoiceCatalog.shared.voices.filter { $0.languageGroup == group }
            // Plain voices first: two distinct voices sound more different than one voice
            // acting two roles, so role-play fills in after them, and for children and the
            // elderly where it is often the only option.
            var candidates = voices.map {
                TTSVoiceCandidate(
                    storageValue: TTSRoleVoice.azure(voice: $0.shortName).storageValue,
                    gender: $0.gender,
                    age: .unknown
                )
            }
            for voice in voices {
                for role in voice.roles {
                    let traits = AzureTTSRole.traits(role)
                    guard traits.gender != .unknown else { continue }
                    candidates.append(TTSVoiceCandidate(
                        storageValue: TTSRoleVoice.azure(voice: AzureTTSVoiceRef(shortName: voice.shortName, role: role).storage).storageValue,
                        gender: traits.gender,
                        age: traits.age
                    ))
                }
            }
            return Pool(candidates: candidates, narrator: TTSRoleVoice.azure(voice: narrator.storage).storageValue)
        case .openAI, .mimo:
            let service: CloudTTSService = family == .mimo ? .mimo : .openAI
            let options = family == .mimo ? MiMoTTSVoices.all : OpenAITTSVoices.all
            let narrator = CloudTTSService.voiceID(inSourceIdentifier: settings.httpTtsUrlTemplate)
            let make: (String) -> TTSRoleVoice = { service == .mimo ? .mimo(voice: $0) : .openAI(voice: $0) }
            return Pool(
                candidates: options.map {
                    TTSVoiceCandidate(storageValue: make($0.id).storageValue, gender: $0.gender, age: $0.age)
                },
                narrator: narrator.isEmpty ? nil : make(narrator).storageValue
            )
        case .bookSource:
            return Pool(
                candidates: settings.importedTTSSources.map { source in
                    let traits = traits(ofSourceNamed: source.name)
                    return TTSVoiceCandidate(
                        storageValue: TTSRoleVoice.bookSource(sourceID: source.id).storageValue,
                        gender: traits.gender,
                        age: traits.age
                    )
                },
                narrator: settings.activeTTSSource.map { TTSRoleVoice.bookSource(sourceID: $0.id).storageValue }
            )
        }
    }

    private static func gender(of voice: AVSpeechSynthesisVoice) -> TTSVoiceGender {
        switch voice.gender {
        case .male: return .male
        case .female: return .female
        default: return .unknown
        }
    }

    /// An imported source names its voice, usually with the gender in it (「曉曉（女）」,
    /// "Yunxi-male"). Only a name that says so is cast; the rest wait for the reader.
    nonisolated static func traits(ofSourceNamed name: String) -> (gender: TTSVoiceGender, age: TTSVoiceAge) {
        let lower = name.lowercased()
        let gender: TTSVoiceGender
        if lower.contains("女") || lower.contains("female") || lower.contains("woman") || lower.contains("girl") {
            gender = .female
        } else if lower.contains("男") || lower.contains("male") || lower.contains("man") || lower.contains("boy") {
            gender = .male
        } else {
            gender = .unknown
        }
        let age: TTSVoiceAge
        if ["童", "孩", "娃", "child", "kid", "boy", "girl"].contains(where: lower.contains) {
            age = .child
        } else if ["老", "爺", "爷", "奶", "婆", "elder", "old"].contains(where: lower.contains) {
            age = .elder
        } else if ["少女", "少年", "青年", "年輕", "年轻", "young"].contains(where: lower.contains) {
            age = .young
        } else {
            age = .unknown
        }
        return (gender, age)
    }
}
