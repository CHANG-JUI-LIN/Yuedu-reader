import Foundation

/// A voice a character can be cast with, tagged by which engine can actually speak it.
///
/// The two engines draw from disjoint catalogues — `AVSpeechSynthesisVoice.identifier`
/// for the on-device voice, `EdgeTTSVoice.id` for 微軟線上語音 — and only one engine runs
/// at a time. Storing the tag rather than a bare string means a cast made under one engine
/// is *recognisably* unusable under the other, so the cast screen can say so instead of the
/// character silently reading in the narrator's voice with no explanation.
enum TTSRoleVoice: Equatable, Hashable {
    case system(identifier: String)
    case edge(voiceID: String)
    /// One of the reader's imported voice sources, by `ImportedTTSSource.id`.
    ///
    /// A source bakes its voice into the URL it was imported with, so one source is one
    /// voice — and a pack of them is a cast. Voice packs ship exactly that way: a 小米 MiMo
    /// or 阿里 TTS JSON is usually a list with one entry per speaker.
    case bookSource(sourceID: String)
    /// An Azure voice, possibly acting a role (`AzureTTSVoiceRef.storage`).
    case azure(voice: String)
    case openAI(voice: String)
    case mimo(voice: String)

    private static let systemPrefix = "system:"
    private static let edgePrefix = "edge:"
    private static let sourcePrefix = "source:"
    private static let azurePrefix = "azure:"
    private static let openAIPrefix = "openai:"
    private static let mimoPrefix = "mimo:"

    var storageValue: String {
        switch self {
        case let .system(identifier): return Self.systemPrefix + identifier
        case let .edge(voiceID): return Self.edgePrefix + voiceID
        case let .bookSource(sourceID): return Self.sourcePrefix + sourceID
        case let .azure(voice): return Self.azurePrefix + voice
        case let .openAI(voice): return Self.openAIPrefix + voice
        case let .mimo(voice): return Self.mimoPrefix + voice
        }
    }

    init?(storageValue: String) {
        let cases: [(String, (String) -> TTSRoleVoice)] = [
            (Self.systemPrefix, { .system(identifier: $0) }),
            (Self.edgePrefix, { .edge(voiceID: $0) }),
            (Self.sourcePrefix, { .bookSource(sourceID: $0) }),
            (Self.azurePrefix, { .azure(voice: $0) }),
            (Self.openAIPrefix, { .openAI(voice: $0) }),
            (Self.mimoPrefix, { .mimo(voice: $0) }),
        ]
        for (prefix, make) in cases where storageValue.hasPrefix(prefix) {
            let value = String(storageValue.dropFirst(prefix.count))
            guard !value.isEmpty else { return nil }
            self = make(value)
            return
        }
        return nil
    }

    /// The catalogue this voice belongs to.
    var family: TTSVoiceFamily {
        switch self {
        case .system: return .system
        case .edge: return .edge
        case .bookSource: return .bookSource
        case .azure: return .azure
        case .openAI: return .openAI
        case .mimo: return .mimo
        }
    }

    /// The cloud voice id for `service`, or `nil` when this voice belongs elsewhere.
    func cloudVoice(for service: CloudTTSService) -> String? {
        switch (self, service) {
        case let (.azure(voice), .azure), let (.openAI(voice), .openAI), let (.mimo(voice), .mimo):
            return voice
        default:
            return nil
        }
    }

    /// The on-device voice identifier, or `nil` when this character is cast with a voice
    /// the system engine cannot speak.
    var systemIdentifier: String? {
        if case let .system(identifier) = self { return identifier }
        return nil
    }

    /// The Edge voice, or `nil` when this character is cast with a voice the network
    /// engine cannot speak — including an Edge id that is no longer in the catalogue.
    var edgeVoice: EdgeTTSVoice? {
        guard case let .edge(voiceID) = self else { return nil }
        return EdgeTTSVoice.voice(id: voiceID)
    }

    /// The imported voice source, or `nil` when this character is cast with something else —
    /// or with a source that has since been deleted.
    @MainActor
    func importedSource(
        in sources: [ImportedTTSSource] = GlobalSettings.shared.importedTTSSources
    ) -> ImportedTTSSource? {
        guard case let .bookSource(sourceID) = self else { return nil }
        return sources.first { $0.id == sourceID }
    }
}

/// Which catalogue the next playback will draw its voices from.
///
/// The cast screen has to offer the voices the running engine can actually speak, and has
/// to be able to say why a character it cannot speak is reading in the narrator's voice.
enum TTSVoiceFamily: String, Equatable, Sendable {
    case system
    case edge
    /// An imported voice source. One source is one voice, because the voice is baked into
    /// the URL — but a reader with a voice pack has several, and those are a cast.
    case bookSource
    case azure
    case openAI
    case mimo

    var cloudService: CloudTTSService? {
        switch self {
        case .azure: return .azure
        case .openAI: return .openAI
        case .mimo: return .mimo
        default: return nil
        }
    }

    /// Whether lines can carry an emotion this family renders as more than prosody — a
    /// speaking style or instructions. Decides whether the AI is asked for a per-line
    /// direction, which costs output tokens and therefore time before a chapter starts.
    var takesInstructions: Bool {
        switch self {
        case .openAI, .mimo: return true
        default: return false
        }
    }

    @MainActor
    static func active(
        useSystemVoice: Bool = GlobalSettings.shared.ttsUseSystemVoice,
        httpTemplate: String = GlobalSettings.shared.httpTtsUrlTemplate
    ) -> TTSVoiceFamily {
        if useSystemVoice { return .system }
        let template = httpTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.isEmpty { return .system }
        if EdgeTTSVoice.isEdgeSource(template) { return .edge }
        switch CloudTTSService.service(forSourceIdentifier: template) {
        case .azure?: return .azure
        case .openAI?: return .openAI
        case .mimo?: return .mimo
        case nil: return .bookSource
        }
    }

    /// Whether a cast can be assigned at all.
    ///
    /// The on-device and 微軟線上 catalogues always have more than one voice. An imported
    /// source has exactly one, so multi-role needs at least two of them imported — which is
    /// what a voice pack gives you, since those ship one entry per speaker.
    ///
    /// This used to be a flat `self != .bookSource`, which locked the feature away from
    /// every reader using an imported pack even when they had a dozen voices sitting in
    /// the list.
    @MainActor
    func supportsMultiRole(
        importedSourceCount: Int = GlobalSettings.shared.importedTTSSources.count
    ) -> Bool {
        switch self {
        case .system, .edge, .azure, .openAI, .mimo: return true
        case .bookSource: return importedSourceCount >= 2
        }
    }
}

/// Stores and reads the 多角色朗讀 cast — which voice reads which character.
///
/// The cast is per book: `張三` in one novel is not `張三` in another, and a voice
/// assigned in one should never leak into the other. It is still kept as one flat
/// UserDefaults dictionary rather than a nested one, because a nested dictionary is
/// not a plist type and would need encoding — the same reason
/// `GlobalSettings.ttsSystemVoiceIdentifiers` is flat.
enum TTSRoleVoiceCast {
    /// ASCII Unit Separator: cannot appear in a UUID and will not appear in a name read
    /// out of prose, so a key never splits in the wrong place.
    private static let separator = "\u{1F}"

    /// "Read this character in the narrator's voice", chosen on purpose. Distinct from no
    /// entry, which hands the character to automatic casting. Not a `TTSRoleVoice`, so every
    /// engine reads it as the narrator without knowing it exists.
    static let narratorChoice = "narrator:"

    static func key(bookID: UUID, speaker: String) -> String {
        "\(bookID.uuidString)\(separator)\(speaker)"
    }

    /// Every speaker cast for this book, as the engines want it: speaker → voice id.
    static func cast(forBook bookID: UUID, in stored: [String: String]) -> [String: String] {
        let prefix = "\(bookID.uuidString)\(separator)"
        var result: [String: String] = [:]
        for (key, voice) in stored where key.hasPrefix(prefix) && !voice.isEmpty {
            let speaker = String(key.dropFirst(prefix.count))
            guard !speaker.isEmpty else { continue }
            result[speaker] = voice
        }
        return result
    }

    /// Returns `stored` with `speaker` cast as `voiceIdentifier`, or uncast when it is
    /// `nil` — an uncast character reads in the narrator's voice, which is also what an
    /// unattributed line gets, so removing the entry is the whole of "reset to default".
    static func setting(
        voiceIdentifier: String?,
        forSpeaker speaker: String,
        bookID: UUID,
        in stored: [String: String]
    ) -> [String: String] {
        var updated = stored
        let key = key(bookID: bookID, speaker: speaker)
        if let voiceIdentifier, !voiceIdentifier.isEmpty {
            updated[key] = voiceIdentifier
        } else {
            updated.removeValue(forKey: key)
        }
        return updated
    }

    /// Whether this cast contains anything the given engine can actually speak.
    ///
    /// This is what decides whether a chapter gets split at quote boundaries at all. A cast
    /// made entirely of 微軟線上語音 is worth nothing to the on-device engine: splitting for
    /// it would produce many more utterances that all sound identical. Asking per engine,
    /// rather than just "is the cast non-empty", keeps that cost tied to an audible result.
    @MainActor
    static func containsSpeakableVoice(
        in cast: [String: String],
        family: TTSVoiceFamily,
        sources: [ImportedTTSSource] = GlobalSettings.shared.importedTTSSources
    ) -> Bool {
        cast.values.contains { stored in
            guard let voice = TTSRoleVoice(storageValue: stored) else { return false }
            return isSpeakable(voice, family: family, sources: sources)
        }
    }

    /// The speakers in `cast` whose voice the engine running `family` can speak — the ones
    /// that sound different from the narrator.
    @MainActor
    static func speakersWithSpeakableVoices(
        in cast: [String: String],
        family: TTSVoiceFamily,
        sources: [ImportedTTSSource] = GlobalSettings.shared.importedTTSSources
    ) -> Set<String> {
        Set(cast.compactMap { speaker, stored in
            guard let voice = TTSRoleVoice(storageValue: stored),
                  isSpeakable(voice, family: family, sources: sources) else { return nil }
            return speaker
        })
    }

    /// Whether a quoted run must be its own segment: it is read in a voice of its own, or with
    /// an emotion the engine can render. Anything else stays inside its paragraph.
    nonisolated static func needsOwnSegment(
        _ attribution: TTSSpeakerAnnotator.Attribution,
        voicedSpeakers: Set<String>,
        rendersDelivery: Bool
    ) -> Bool {
        if let speaker = attribution.speaker, voicedSpeakers.contains(speaker) { return true }
        return rendersDelivery && attribution.delivery?.isNeutral == false
    }

    /// Whether the engine running `family` can speak `voice`.
    @MainActor
    static func isSpeakable(
        _ voice: TTSRoleVoice,
        family: TTSVoiceFamily,
        sources: [ImportedTTSSource] = GlobalSettings.shared.importedTTSSources
    ) -> Bool {
        switch family {
        case .system: return voice.systemIdentifier != nil
        case .edge: return voice.edgeVoice != nil
        case .bookSource: return voice.importedSource(in: sources) != nil
        case .azure, .openAI, .mimo:
            return family.cloudService.flatMap(voice.cloudVoice(for:)) != nil
        }
    }

    /// Drops every entry for a book. Used when its cast is reset, and when a book is
    /// deleted — otherwise the assignments outlive the book and the dictionary only
    /// ever grows.
    static func clearing(bookID: UUID, in stored: [String: String]) -> [String: String] {
        let prefix = "\(bookID.uuidString)\(separator)"
        return stored.filter { !$0.key.hasPrefix(prefix) }
    }
}
