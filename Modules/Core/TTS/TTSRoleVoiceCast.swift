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

    private static let systemPrefix = "system:"
    private static let edgePrefix = "edge:"

    var storageValue: String {
        switch self {
        case let .system(identifier): return Self.systemPrefix + identifier
        case let .edge(voiceID): return Self.edgePrefix + voiceID
        }
    }

    init?(storageValue: String) {
        if storageValue.hasPrefix(Self.systemPrefix) {
            let identifier = String(storageValue.dropFirst(Self.systemPrefix.count))
            guard !identifier.isEmpty else { return nil }
            self = .system(identifier: identifier)
        } else if storageValue.hasPrefix(Self.edgePrefix) {
            let voiceID = String(storageValue.dropFirst(Self.edgePrefix.count))
            guard !voiceID.isEmpty else { return nil }
            self = .edge(voiceID: voiceID)
        } else {
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
}

/// Which catalogue the next playback will draw its voices from.
///
/// The cast screen has to offer the voices the running engine can actually speak, and has
/// to be able to say why a character it cannot speak is reading in the narrator's voice.
enum TTSVoiceFamily: Equatable {
    case system
    case edge
    /// A book-source template. Its voice is baked into the URL the user imported, so there
    /// is no second voice to switch to and 多角色朗讀 cannot apply at all.
    case bookSource

    static func active(
        useSystemVoice: Bool = GlobalSettings.shared.ttsUseSystemVoice,
        httpTemplate: String = GlobalSettings.shared.httpTtsUrlTemplate
    ) -> TTSVoiceFamily {
        if useSystemVoice { return .system }
        let template = httpTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.isEmpty { return .system }
        return EdgeTTSVoice.isEdgeSource(template) ? .edge : .bookSource
    }

    var supportsMultiRole: Bool { self != .bookSource }
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
    static func containsSpeakableVoice(in cast: [String: String], system: Bool) -> Bool {
        cast.values.contains { stored in
            guard let voice = TTSRoleVoice(storageValue: stored) else { return false }
            return system ? voice.systemIdentifier != nil : voice.edgeVoice != nil
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
