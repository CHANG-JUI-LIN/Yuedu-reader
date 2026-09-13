import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

@Suite("Multi-role TTS cast")
struct TTSRoleVoiceCastTests {

    private let bookA = UUID()
    private let bookB = UUID()

    @Test("a voice assigned in one book never reads in another")
    func castIsScopedPerBook() {
        var stored: [String: String] = [:]
        stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.a").storageValue, forSpeaker: "張三", bookID: bookA, in: stored
        )
        stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.b").storageValue, forSpeaker: "張三", bookID: bookB, in: stored
        )
        #expect(TTSRoleVoiceCast.cast(forBook: bookA, in: stored) == ["張三": TTSRoleVoice.system(identifier: "voice.a").storageValue])
        #expect(
            TTSRoleVoiceCast.cast(forBook: bookB, in: stored)
                == ["張三": TTSRoleVoice.system(identifier: "voice.b").storageValue]
        )
    }

    @Test("clearing a voice removes the entry rather than storing an empty one")
    func clearingRemovesEntry() {
        var stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.a").storageValue, forSpeaker: "張三", bookID: bookA, in: [:]
        )
        stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: nil, forSpeaker: "張三", bookID: bookA, in: stored
        )
        #expect(stored.isEmpty)
        #expect(TTSRoleVoiceCast.cast(forBook: bookA, in: stored).isEmpty)
    }

    /// The dictionary is global and would otherwise grow forever as books come and go.
    @Test("clearing a book drops only that book's cast")
    func clearingBookLeavesOthers() {
        var stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.a").storageValue, forSpeaker: "張三", bookID: bookA, in: [:]
        )
        stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.b").storageValue, forSpeaker: "李四", bookID: bookB, in: stored
        )
        let cleared = TTSRoleVoiceCast.clearing(bookID: bookA, in: stored)
        #expect(TTSRoleVoiceCast.cast(forBook: bookA, in: cleared).isEmpty)
        #expect(TTSRoleVoiceCast.cast(forBook: bookB, in: cleared) == ["李四": TTSRoleVoice.system(identifier: "voice.b").storageValue])
    }

    /// A name read out of prose can contain almost anything; the key must still split
    /// back at the right place.
    @Test("a speaker name with punctuation survives a storage round trip")
    func handlesAwkwardSpeakerNames() {
        let speaker = "齊源·老道"
        let stored = TTSRoleVoiceCast.setting(
            voiceIdentifier: TTSRoleVoice.system(identifier: "voice.a").storageValue, forSpeaker: speaker, bookID: bookA, in: [:]
        )
        #expect(TTSRoleVoiceCast.cast(forBook: bookA, in: stored) == [speaker: TTSRoleVoice.system(identifier: "voice.a").storageValue])
    }

    @Test("entries stored with an empty voice are ignored")
    func ignoresEmptyVoiceValues() {
        let stored = [TTSRoleVoiceCast.key(bookID: bookA, speaker: "張三"): ""]
        #expect(TTSRoleVoiceCast.cast(forBook: bookA, in: stored).isEmpty)
    }

    // MARK: - Voice selection

    /// Narration, and quoted speech the detector would not commit to, both read in the
    /// narrator's voice.
    @Test("an uncast or unattributed segment reads in the narrator's voice")
    func fallsBackToNarrator() {
        let narrator = SystemTTSEngine.preferredVoice(for: "他走進門。")
        #expect(
            SystemTTSEngine.preferredVoice(for: "他走進門。", speaker: nil, roleVoices: ["張三": TTSRoleVoice.system(identifier: "x").storageValue])
                == narrator
        )
        #expect(
            SystemTTSEngine.preferredVoice(for: "他走進門。", speaker: "李四", roleVoices: ["張三": TTSRoleVoice.system(identifier: "x").storageValue])
                == narrator
        )
    }

    /// The voice the user cast may have been deleted since. `speakChunk` treats a nil
    /// voice as a playback failure and ends the whole session, so this must degrade to
    /// the narrator rather than to nothing.
    @Test("a cast voice that no longer exists degrades to the narrator, not to silence")
    func unresolvableVoiceDegradesToNarrator() {
        let voice = SystemTTSEngine.preferredVoice(
            for: "「你先走。」",
            speaker: "張三",
            roleVoices: ["張三": TTSRoleVoice.system(identifier: "com.example.voice.that.does.not.exist").storageValue]
        )
        #expect(voice != nil)
        #expect(voice == SystemTTSEngine.preferredVoice(for: "「你先走。」"))
    }

    @Test("a cast voice that resolves is used for that speaker")
    func usesCastVoiceWhenItResolves() throws {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let narrator = SystemTTSEngine.preferredVoice(for: "「你先走。」")
        // Pick any installed voice that is not the one narration would already use, so
        // the assertion cannot pass by accident.
        guard let other = installed.first(where: { $0.identifier != narrator?.identifier }) else {
            return
        }
        let voice = SystemTTSEngine.preferredVoice(
            for: "「你先走。」",
            speaker: "張三",
            roleVoices: ["張三": TTSRoleVoice.system(identifier: other.identifier).storageValue]
        )
        #expect(voice?.identifier == other.identifier)
    }

    // MARK: - Engine-specific catalogues

    /// The two engines draw from disjoint catalogues and only one runs at a time. A cast
    /// made for one must be recognisably unusable by the other, not silently half-applied.
    @Test("a voice tag survives a storage round trip")
    func voiceTagRoundTrips() {
        for voice: TTSRoleVoice in [.system(identifier: "com.apple.x"), .edge(voiceID: "zh-TW-HsiaoChenNeural")] {
            #expect(TTSRoleVoice(storageValue: voice.storageValue) == voice)
        }
        #expect(TTSRoleVoice(storageValue: "no-prefix") == nil)
        #expect(TTSRoleVoice(storageValue: "system:") == nil)
        #expect(TTSRoleVoice(storageValue: "edge:") == nil)
    }

    @Test("each engine sees only the voices it can speak")
    func tagsAreEngineSpecific() {
        let system = TTSRoleVoice.system(identifier: "com.apple.x")
        let edge = TTSRoleVoice.edge(voiceID: EdgeTTSVoice.defaultVoice.id)
        #expect(system.systemIdentifier == "com.apple.x")
        #expect(system.edgeVoice == nil)
        #expect(edge.edgeVoice?.id == EdgeTTSVoice.defaultVoice.id)
        #expect(edge.systemIdentifier == nil)
    }

    /// An Edge id that is no longer in the shipped catalogue must not resolve.
    @Test("an unknown Edge voice does not resolve")
    func unknownEdgeVoiceDoesNotResolve() {
        #expect(TTSRoleVoice.edge(voiceID: "zh-XX-NotAVoiceNeural").edgeVoice == nil)
    }

    /// This gate is what keeps a chapter from being split into many more utterances for a
    /// cast the running engine cannot speak — on the network engine that is real requests.
    @Test("splitting is gated on a cast the running engine can actually speak")
    func speakableGateIsPerEngine() {
        let systemOnly = ["張三": TTSRoleVoice.system(identifier: "com.apple.x").storageValue]
        let edgeOnly = ["張三": TTSRoleVoice.edge(voiceID: EdgeTTSVoice.defaultVoice.id).storageValue]
        let sourceOnly = ["張三": TTSRoleVoice.bookSource(sourceID: "mimo-a").storageValue]
        let sources = [Self.makeSource(id: "mimo-a"), Self.makeSource(id: "mimo-b")]

        #expect(TTSRoleVoiceCast.containsSpeakableVoice(in: systemOnly, family: .system, sources: sources))
        #expect(!TTSRoleVoiceCast.containsSpeakableVoice(in: systemOnly, family: .edge, sources: sources))
        #expect(TTSRoleVoiceCast.containsSpeakableVoice(in: edgeOnly, family: .edge, sources: sources))
        #expect(!TTSRoleVoiceCast.containsSpeakableVoice(in: edgeOnly, family: .system, sources: sources))
        #expect(TTSRoleVoiceCast.containsSpeakableVoice(in: sourceOnly, family: .bookSource, sources: sources))
        #expect(!TTSRoleVoiceCast.containsSpeakableVoice(in: sourceOnly, family: .system, sources: sources))
        #expect(!TTSRoleVoiceCast.containsSpeakableVoice(in: [:], family: .system, sources: sources))
        #expect(!TTSRoleVoiceCast.containsSpeakableVoice(in: ["張三": "garbage"], family: .system, sources: sources))
    }

    // MARK: - Imported voice sources

    /// The bug this fixes: a reader listening through an imported 小米 MiMo pack had the
    /// 多角色朗讀 toggle greyed out, because the whole family was written off as
    /// "one voice baked into a URL". One *source* is one voice — a pack is a cast.
    @Test("multi-role turns on once a second voice source is imported")
    func importedSourcesEnableMultiRole() {
        #expect(TTSVoiceFamily.bookSource.supportsMultiRole(importedSourceCount: 2))
        #expect(TTSVoiceFamily.bookSource.supportsMultiRole(importedSourceCount: 9))
        // One source really is one voice; there is nothing to switch between.
        #expect(!TTSVoiceFamily.bookSource.supportsMultiRole(importedSourceCount: 1))
        #expect(!TTSVoiceFamily.bookSource.supportsMultiRole(importedSourceCount: 0))
        // The on-device and 微軟 catalogues always have more than one.
        #expect(TTSVoiceFamily.system.supportsMultiRole(importedSourceCount: 0))
        #expect(TTSVoiceFamily.edge.supportsMultiRole(importedSourceCount: 0))
    }

    @Test("a source voice survives a storage round trip and resolves to its source")
    func sourceVoiceRoundTrips() {
        let voice = TTSRoleVoice.bookSource(sourceID: "mimo-a")
        #expect(TTSRoleVoice(storageValue: voice.storageValue) == voice)
        #expect(TTSRoleVoice(storageValue: "source:") == nil)
        let sources = [Self.makeSource(id: "mimo-a"), Self.makeSource(id: "mimo-b")]
        #expect(voice.importedSource(in: sources)?.id == "mimo-a")
        // Deleting a source must not resolve to a different one.
        #expect(voice.importedSource(in: [Self.makeSource(id: "mimo-b")]) == nil)
        #expect(voice.systemIdentifier == nil)
        #expect(voice.edgeVoice == nil)
    }

    /// Each engine sees only what it can speak, now in three directions rather than two.
    @Test("an imported-source cast means nothing to the other two engines")
    func sourceVoiceIsEngineSpecific() {
        let sources = [Self.makeSource(id: "mimo-a")]
        #expect(TTSRoleVoice.system(identifier: "x").importedSource(in: sources) == nil)
        #expect(TTSRoleVoice.edge(voiceID: EdgeTTSVoice.defaultVoice.id).importedSource(in: sources) == nil)
    }

    private static func makeSource(id: String) -> ImportedTTSSource {
        ImportedTTSSource(
            name: id,
            urlTemplate: "https://example.com/tts?text={{speakText}}&voice=\(id)",
            sourceID: id
        )
    }
}
