@testable import YueduCoreText
import Foundation
import Testing
@testable import yuedu_app

@Suite("Multi-role TTS speaker annotation")
struct TTSSpeakerAnnotatorTests {

    // MARK: - Attribution

    @Test("attributes a quote to the name that leads into it")
    func attributesLeadIn() {
        let text = "張若塵道：「你先走。」"
        let attributions = TTSSpeakerAnnotator.attributions(in: text)
        #expect(attributions.count == 1)
        #expect(attributions.first?.speaker == "張若塵")
        #expect((text as NSString).substring(with: attributions[0].range) == "「你先走。」")
    }

    @Test("attributes a quote to the name that follows it")
    func attributesTrailer() {
        let attributions = TTSSpeakerAnnotator.attributions(in: "「你先走。」池瑤冷冷地說。")
        #expect(attributions.map(\.speaker) == ["池瑤"])
    }

    /// `「甲，」某某面露無奈，「乙。」` — one speech interrupted by its own beat.
    /// Both halves belong to that speaker, and the beat carries no speech verb.
    @Test("gives both halves of an interrupted line the same speaker")
    func attributesSharedBeat() {
        let attributions = TTSSpeakerAnnotator.attributions(
            in: "「我知道，」齊源老道面露無奈，「但他不肯聽。」"
        )
        #expect(attributions.count == 2)
        #expect(attributions.allSatisfy { $0.speaker == "齊源老道" })
    }

    /// Two people taking turns must not collapse into one speaker.
    @Test("keeps separate speakers when two characters take turns")
    func separatesTurnTaking() {
        let attributions = TTSSpeakerAnnotator.attributions(
            in: "「甲。」張三道。「乙。」李四道。"
        )
        #expect(attributions.map(\.speaker) == ["張三", "李四"])
    }

    @Test("leaves the speaker unset when the narration does not attribute the line")
    func leavesUnattributedLineToTheNarrator() {
        let attributions = TTSSpeakerAnnotator.attributions(in: "屋裡很安靜。「有人嗎？」")
        #expect(attributions.count == 1)
        #expect(attributions[0].speaker == nil)
    }

    @Test("returns nothing for a chapter with no quoted speech")
    func returnsNothingWithoutDialogue() {
        #expect(TTSSpeakerAnnotator.attributions(in: "他沿著河岸走了很久。").isEmpty)
        #expect(TTSSpeakerAnnotator.attributions(in: "").isEmpty)
    }

    /// The whole point of the AI character roster: one person under several names
    /// must not become several voices.
    @Test("folds aliases onto the canonical character name")
    func foldsAliasesOntoOneSpeaker() {
        let text = "張若塵道：「走。」\n若塵道：「快。」\n塵哥道：「別停。」"
        let attributions = TTSSpeakerAnnotator.attributions(
            in: text,
            aliases: ["若塵": "張若塵", "塵哥": "張若塵"]
        )
        #expect(attributions.count == 3)
        #expect(Set(attributions.compactMap(\.speaker)) == ["張若塵"])
    }

    // MARK: - Segmentation

    @Test("splits a narrated paragraph so each segment carries one voice")
    func splitsSpeechOutOfNarration() {
        let text = "他說「好」，轉身走了。"
        let segments = TTSPronunciationProjector.segments(
            text,
            targetLength: 2000,
            hints: [],
            multiRole: true
        )
        // The quote is its own segment; the narration around it is not attributed.
        #expect(segments.count > 1)
        let quoted = segments.filter { $0.text.contains("好") && $0.text.contains("「") }
        #expect(quoted.count == 1)
        #expect(segments.filter { $0.speaker != nil }.count == 1)
    }

    @Test("every segment's sourceRange still addresses its own text")
    func sourceRangesRoundTrip() {
        let text = "張若塵道：「你先走。」他沒有回頭。\n池瑤沒有說話。"
        let ns = text as NSString
        let segments = TTSPronunciationProjector.segments(
            text,
            targetLength: 2000,
            hints: [],
            multiRole: true
        )
        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(ns.substring(with: segment.sourceRange) == segment.text)
        }
    }

    /// Single-voice playback must keep the coarse paragraph chunks: they are fewer
    /// requests on the network engine and gap-free on the system one.
    @Test("leaves chunking untouched when multi-role is off")
    func doesNotSplitWhenSingleVoice() {
        let text = "張若塵道：「你先走。」他沒有回頭。"
        let single = TTSPronunciationProjector.segments(text, targetLength: 2000, hints: [])
        let multi = TTSPronunciationProjector.segments(
            text,
            targetLength: 2000,
            hints: [],
            multiRole: true
        )
        #expect(single.count == 1)
        #expect(single.allSatisfy { $0.speaker == nil })
        #expect(multi.count > single.count)
    }

    /// A cut at a quote edge can strand punctuation on its own. An empty utterance
    /// still costs a network request on the HTTP engine, so it must not be emitted.
    @Test("drops pieces a split leaves with nothing to speak")
    func dropsUnspeakablePieces() {
        let segments = TTSPronunciationProjector.segments(
            "「走。」　　「好。」",
            targetLength: 2000,
            hints: [],
            multiRole: true
        )
        #expect(segments.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    /// A ruby base is substituted whole; cutting through one would make the
    /// synthesizer speak the reading twice.
    @Test("never cuts through a ruby base")
    func protectsRubyBases() {
        let text = "他說「漢字」，然後走了。"
        let ruby = TTSPronunciationHint(
            range: (text as NSString).range(of: "「漢字」"),
            reading: "かんじ"
        )
        let segments = TTSPronunciationProjector.segments(
            text,
            targetLength: 2000,
            hints: [ruby],
            multiRole: true
        )
        for segment in segments {
            let intersection = NSIntersectionRange(segment.sourceRange, ruby.range)
            #expect(intersection.length == 0 || intersection.length == ruby.range.length)
        }
    }

    // MARK: - Manner adverbs are not characters

    /// Seen in the 多角色朗讀 cast list on a real chapter: 小聲 / 低聲 / 朗聲 sat there as
    /// characters, because `小聲道：「…」` leaves 小聲 exactly where a name would be.
    @Test("how someone spoke is not who spoke")
    func mannerAdverbsAreNotSpeakers() {
        let text = """
        他小聲道：「別吵。」
        她低聲說：「知道了。」
        老道朗聲笑道：「好！」
        """
        let speakers = Set(TTSSpeakerAnnotator.attributions(in: text).compactMap(\.speaker))
        #expect(!speakers.contains("小聲"))
        #expect(!speakers.contains("低聲"))
        #expect(!speakers.contains("朗聲"))
    }

    /// `的景象` came out of the same chapter — a fragment of description, not a person.
    @Test("a phrase that starts with a particle is not a name")
    func leadingParticlesAreStripped() {
        let text = "眼前的景象讓他愣住，他道：「怎麼會。」"
        let speakers = Set(TTSSpeakerAnnotator.attributions(in: text).compactMap(\.speaker))
        #expect(!speakers.contains("的景象"))
    }

    /// The fix must not cost real attributions.
    @Test("ordinary names still attribute")
    func realNamesSurvive() {
        let text = """
        張若塵道：「我知道了。」
        齊源老道笑道：「不急。」
        """
        let speakers = Set(TTSSpeakerAnnotator.attributions(in: text).compactMap(\.speaker))
        #expect(speakers.contains("張若塵"))
        #expect(speakers.contains("齊源老道"))
    }
}
