import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

/// AI 多角色朗讀: the model labels numbered quotes, the app keeps the text, every name is
/// checked, and voices are matched to characters.
@Suite("AI multi-voice narration")
struct TTSAIDialogueTests {

    private static let chapter = """
    張若塵走進大殿。「你來了。」池瑤沒有回頭。
    「我來了。」
    齊源老道面露無奈，「兩位，」他低聲說，「先坐下吧。」
    門上寫著「天地」二字。
    """

    // MARK: - Request

    @Test("every quote is marked once, in order, inside whole paragraphs")
    func windowsMarkEveryQuote() throws {
        let quotes = AIDialogueAttribution.quotes(in: Self.chapter)
        let windows = AIDialogueAttribution.windows(text: Self.chapter, quotes: quotes)
        #expect(windows.count == 1)
        let body = try #require(windows.first?.body)
        for quote in quotes {
            #expect(body.components(separatedBy: "【\(quote.id)】").count == 2, "\(quote.id)")
        }
        #expect(body.contains("【q1】「你來了。」"))
        #expect(windows.first?.opensChapter == true)
    }

    @Test("a long chapter splits into windows that stay within the limit and keep their lead-in")
    func longChapterSplitsIntoWindows() {
        let paragraph = String(repeating: "敘述。", count: 60) + "「話。」張三道。"
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n")
        let quotes = AIDialogueAttribution.quotes(in: text)
        let windows = AIDialogueAttribution.windows(text: text, quotes: quotes, maxCharacters: 600)
        #expect(windows.count > 1)
        #expect(windows.flatMap(\.quotes).map(\.id) == quotes.map(\.id))
        #expect(windows.dropFirst().allSatisfy { !$0.lead.isEmpty && !$0.opensChapter })
    }

    @Test("book text goes in the user turn, never the system prompt")
    func bookTextStaysInUserTurn() throws {
        let quotes = AIDialogueAttribution.quotes(in: Self.chapter)
        let window = try #require(AIDialogueAttribution.windows(text: Self.chapter, quotes: quotes).first)
        let request = try AIDialogueAttribution.request(
            window: window,
            known: [.init(name: "張若塵", aliases: ["若塵"], gender: .male, age: .young)],
            carry: [.init(speaker: "池瑤", text: "「走。」")],
            includeInstruct: false
        )
        let system = try #require(request.messages.first?.content)
        let user = try #require(request.messages.last?.content)
        #expect(!system.contains("張若塵"))
        #expect(user.contains("張若塵") && user.contains("previousChapterEnding"))
        #expect(request.reasoningEffort == .off)
        #expect(!system.contains("表演指示"))
        let directed = try AIDialogueAttribution.request(window: window, known: [], carry: [], includeInstruct: true)
        #expect(directed.messages.first?.content.contains("表演指示") == true)
    }

    // MARK: - Response

    private func parse(_ json: String, aliases: [String: String] = [:], includeInstruct: Bool = false) throws -> AIDialogueAttribution.Parsed {
        let quotes = AIDialogueAttribution.quotes(in: Self.chapter)
        let window = try #require(AIDialogueAttribution.windows(text: Self.chapter, quotes: quotes).first)
        return try AIDialogueAttribution.parse(
            LLMRawResponse(content: json, provider: "fixture", model: "fixture", finishReason: "stop"),
            window: window,
            text: Self.chapter,
            aliasMap: aliases,
            includeInstruct: includeInstruct
        )
    }

    @Test("speakers are attributed even where the prose never says who spoke")
    func attributesUnmarkedDialogue() throws {
        let parsed = try parse(#"""
        {"lines":{"q1":["池瑤","cold",2],"q2":["張若塵","neutral",1],"q3":["齊源老道","gentle",1],"q4":["齊源老道","whisper",2],"q5":["","neutral",1]},
         "characters":[["池瑤","female","young","清冷"],["張若塵","male","young",""],["齊源老道","male","elder","沉穩"]]}
        """#)
        #expect(parsed.lines["q1"]?.speaker == "池瑤")
        #expect(parsed.lines["q2"]?.speaker == "張若塵")
        #expect(parsed.lines["q5"]?.speaker == nil)
        #expect(parsed.lines["q1"]?.delivery?.emotion == .cold)
        // Neutral lines carry no delivery: nothing for an engine to do.
        #expect(parsed.lines["q2"]?.delivery == nil)
        #expect(parsed.characters.map(\.name) == ["池瑤", "張若塵", "齊源老道"])
        #expect(parsed.characters.first?.gender == .female)
        #expect(parsed.characters.last?.age == .elder)
    }

    @Test("pronouns, narrator words and names the book never wrote read in the narrator's voice")
    func rejectsUnverifiableNames() throws {
        let parsed = try parse(#"{"lines":{"q1":["她","cold",2],"q2":["旁白","neutral",1],"q3":["李逍遙","neutral",1],"q4":["齊源老道","neutral",1]},"characters":[["李逍遙","male","young",""]]}"#)
        #expect(parsed.lines["q1"]?.speaker == nil)
        #expect(parsed.lines["q2"]?.speaker == nil)
        #expect(parsed.lines["q3"]?.speaker == nil)
        #expect(parsed.lines["q4"]?.speaker == "齊源老道")
        #expect(parsed.characters.isEmpty)
    }

    @Test("an alias is folded onto the known name, and the other script is converted back")
    func foldsAliasesAndScripts() throws {
        let parsed = try parse(
            #"{"lines":{"q1":["池瑶","neutral",1],"q2":["若塵","neutral",1]},"characters":[]}"#,
            aliases: ["若塵": "張若塵"]
        )
        #expect(parsed.lines["q1"]?.speaker == "池瑤")
        #expect(parsed.lines["q2"]?.speaker == "張若塵")
    }

    @Test("a reasoning model's think block and a fenced answer still parse")
    func stripsThinkingAndFences() throws {
        let parsed = try parse("<think>先看上下文……</think>\n```json\n{\"lines\":{\"q1\":[\"池瑤\",\"angry\",3]},\"characters\":[]}\n```")
        #expect(parsed.lines["q1"]?.delivery == TTSDelivery(emotion: .angry, intensity: 3))
    }

    @Test("directions are kept only when they were asked for")
    func keepsInstructOnlyWhenRequested() throws {
        let json = #"{"lines":{"q1":["池瑤","cold",2,"壓低聲音"]},"characters":[]}"#
        #expect(try parse(json).lines["q1"]?.delivery?.instruct == nil)
        #expect(try parse(json, includeInstruct: true).lines["q1"]?.delivery?.instruct == "壓低聲音")
    }

    @Test("a truncated or malformed answer is an error, not an empty cast")
    func malformedAnswerThrows() {
        #expect(throws: LLMError.self) { try self.parse("not json") }
        let quotes = AIDialogueAttribution.quotes(in: Self.chapter)
        let window = AIDialogueAttribution.windows(text: Self.chapter, quotes: quotes)[0]
        #expect(throws: LLMError.self) {
            try AIDialogueAttribution.parse(
                LLMRawResponse(content: #"{"lines":{}"#, provider: "f", model: "f", finishReason: "length"),
                window: window, text: Self.chapter, aliasMap: [:], includeInstruct: false
            )
        }
    }

    // MARK: - Chapter and roster

    @Test("narration started part-way keeps only whole lines, shifted to its own coordinates")
    func slicesAttributionsForAStartOffset() {
        let dialogue = TTSChapterDialogue(
            key: "k", chapterIndex: 0, includesInstruct: false,
            lines: [
                .init(location: 2, length: 4, speaker: "甲", delivery: nil),
                .init(location: 10, length: 5, speaker: "乙", delivery: TTSDelivery(emotion: .sad)),
            ],
            provider: "p", model: "m", promptVersion: AIDialogueAttribution.promptVersion
        )
        let sliced = dialogue.attributions(droppingPrefix: 4, textLength: 20) { $0 == "乙" ? "年長女性" : nil }
        #expect(sliced.count == 1)
        #expect(sliced.first?.range == NSRange(location: 6, length: 5))
        #expect(sliced.first?.delivery?.persona == "年長女性")
    }

    @Test("the roster counts lines, keeps the first known gender and bounds the carried endings")
    func rosterMerges() {
        var roster = TTSDialogueRoster()
        let first = TTSChapterDialogue(
            key: "a", chapterIndex: 3, includesInstruct: false,
            lines: [.init(location: 0, length: 2, speaker: "甲", delivery: nil), .init(location: 3, length: 2, speaker: "甲", delivery: nil)],
            provider: "p", model: "m", promptVersion: "v"
        )
        roster.merge(
            chapter: first,
            characters: [.init(name: "甲", aliases: [], gender: .unknown, age: .unknown, voiceNote: nil, lineCount: 0, firstChapter: 0)],
            tail: [], keepingTails: 2
        )
        let second = TTSChapterDialogue(
            key: "b", chapterIndex: 1, includesInstruct: false,
            lines: [.init(location: 0, length: 2, speaker: "甲", delivery: nil)],
            provider: "p", model: "m", promptVersion: "v"
        )
        roster.merge(
            chapter: second,
            characters: [.init(name: "甲", aliases: ["阿甲"], gender: .female, age: .young, voiceNote: "清脆", lineCount: 0, firstChapter: 0)],
            tail: [], keepingTails: 2
        )
        let third = TTSChapterDialogue(key: "c", chapterIndex: 5, includesInstruct: false, lines: [], provider: "p", model: "m", promptVersion: "v")
        roster.merge(chapter: third, characters: [], tail: [], keepingTails: 2)
        let character = roster.character(named: "甲")
        #expect(character?.lineCount == 3)
        #expect(character?.gender == .female)
        #expect(character?.firstChapter == 1)
        #expect(roster.aliasMap["阿甲"] == "甲")
        #expect(Set(roster.tails.keys) == [3, 5])
    }

    // MARK: - Casting

    private static func character(_ name: String, _ gender: TTSVoiceGender, _ age: TTSVoiceAge = .adult, lines: Int) -> TTSDialogueCharacter {
        .init(name: name, aliases: [], gender: gender, age: age, voiceNote: nil, lineCount: lines, firstChapter: 0)
    }

    private static let pool: [TTSVoiceCandidate] = [
        .init(storageValue: "f1", gender: .female, age: .young),
        .init(storageValue: "f2", gender: .female, age: .adult),
        .init(storageValue: "m1", gender: .male, age: .young),
        .init(storageValue: "m2", gender: .male, age: .adult),
        .init(storageValue: "boy", gender: .male, age: .child),
    ]

    @Test("main characters get voices of their own, matched to gender, never the narrator's")
    func castsByGenderAndImportance() {
        let picks = TTSAutoCast.assign(
            characters: [
                Self.character("路人", .male, lines: 1),
                Self.character("張若塵", .male, .young, lines: 40),
                Self.character("池瑤", .female, .young, lines: 30),
                Self.character("老道", .male, .elder, lines: 12),
                Self.character("某人", .unknown, lines: 9),
            ],
            explicit: [:],
            existing: [:],
            candidates: Self.pool,
            narrator: "f2"
        )
        #expect(picks["張若塵"] == "m1")
        #expect(picks["池瑤"] == "f1")
        #expect(picks["老道"] == "m2")
        // Out of male voices for the minor character: shares, never takes the narrator or a child's.
        #expect(["m1", "m2"].contains(picks["路人"] ?? ""))
        #expect(picks["某人"] == nil)
        #expect(!picks.values.contains("f2"))
        #expect(!picks.values.contains("boy"))
    }

    @Test("a child gets a child's voice, and an existing or chosen voice is never moved")
    func keepsExistingVoices() {
        let picks = TTSAutoCast.assign(
            characters: [
                Self.character("小石頭", .male, .child, lines: 5),
                Self.character("甲", .male, lines: 20),
                Self.character("乙", .male, lines: 10),
            ],
            explicit: ["甲": "m2"],
            existing: ["乙": "m1"],
            candidates: Self.pool,
            narrator: nil
        )
        #expect(picks["小石頭"] == "boy")
        #expect(picks["甲"] == nil)
        #expect(picks["乙"] == nil)
    }

    @Test("an imported source's name says its gender and age")
    func readsSourceTraitsFromNames() {
        let female = TTSVoiceCandidates.traits(ofSourceNamed: "曉曉（女）")
        #expect(female.gender == .female && female.age == .unknown)
        let male = TTSVoiceCandidates.traits(ofSourceNamed: "Yunxi-male")
        #expect(male.gender == .male && male.age == .unknown)
        let boy = TTSVoiceCandidates.traits(ofSourceNamed: "童聲・男")
        #expect(boy.gender == .male && boy.age == .child)
        #expect(TTSVoiceCandidates.traits(ofSourceNamed: "MiMo 預設").gender == .unknown)
    }

    // MARK: - Segments

    @Test("a quote read in the narrator's voice stays inside its paragraph; a voiced one is cut out")
    func cutsOnlyWhereTheVoiceChanges() {
        let text = "張三道：「走。」李四點頭：「好。」"
        let quotes = AIDialogueAttribution.quotes(in: text)
        let attributions = [
            TTSSpeakerAnnotator.Attribution(range: quotes[0].range, speaker: "張三", delivery: TTSDelivery(emotion: .angry)),
            TTSSpeakerAnnotator.Attribution(range: quotes[1].range, speaker: "李四"),
        ]
        let segments = TTSPronunciationProjector.segments(
            text, targetLength: 2000, hints: [], multiRole: true,
            precomputed: attributions,
            needsOwnSegment: { TTSRoleVoiceCast.needsOwnSegment($0, voicedSpeakers: ["張三"], rendersDelivery: true) }
        )
        let voiced = segments.filter { $0.speaker != nil }
        #expect(voiced.map(\.text) == ["「走。」"])
        #expect(voiced.first?.delivery?.emotion == .angry)
        #expect(segments.contains { $0.text.contains("李四點頭：「好。」") })
    }

    @Test("prosody approximates an emotion, scaled by intensity, and leaves neutral alone")
    func prosodyApproximation() {
        #expect(TTSProsody.approximating(nil) == .zero)
        #expect(TTSProsody.approximating(TTSDelivery(emotion: .neutral)) == .zero)
        let mild = TTSProsody.approximating(TTSDelivery(emotion: .shout, intensity: 1))
        let strong = TTSProsody.approximating(TTSDelivery(emotion: .shout, intensity: 3))
        #expect(strong.volumePercent > mild.volumePercent && mild.volumePercent > 0)
        #expect(TTSProsody.approximating(TTSDelivery(emotion: .whisper)).volumePercent < 0)
        #expect(EdgeTTSProtocol.rateString(1.0, adjustedBy: 10) == "+120%")
    }

    // MARK: - Voices

    @Test("Azure gets a style the voice really has, a role-play role, and prosody when it has no style")
    func azureSSML() {
        let angry = AzureTTSSSML.document(
            text: "你<敢>？",
            voice: AzureTTSVoiceRef(storage: "zh-CN-XiaomoNeural#Girl"),
            rate: 0.5,
            delivery: TTSDelivery(emotion: .angry, intensity: 3),
            supportedStyles: ["angry", "sad"]
        )
        #expect(angry.contains("role='Girl'") && angry.contains("style='angry'") && angry.contains("styledegree='1.8'"))
        #expect(angry.contains("你&lt;敢&gt;？") && angry.contains("xml:lang='zh-CN'"))
        let noStyle = AzureTTSSSML.document(
            text: "噓。",
            voice: AzureTTSVoiceRef(storage: "zh-TW-HsiaoChenNeural"),
            rate: 0.5,
            delivery: TTSDelivery(emotion: .whisper),
            supportedStyles: []
        )
        #expect(!noStyle.contains("express-as"))
        #expect(noStyle.contains("volume='-35%'"))
    }

    @Test("OpenAI and MiMo are told who speaks and how")
    func instructionFollowingRequests() throws {
        let delivery = TTSDelivery(emotion: .sad, intensity: 2, instruct: "哽咽", persona: "年長女性")
        let openAI = OpenAICompatibleTTSAudioProvider(
            configuration: .init(service: .openAI, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-tts", key: "k"),
            voice: "coral",
            delivery: delivery
        )
        let speech = try openAI.request(text: "別走。")
        #expect(speech.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(speech.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try #require(try JSONSerialization.jsonObject(with: speech.httpBody ?? Data()) as? [String: Any])
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("年長女性") && instructions.contains("明顯悲傷") && instructions.contains("哽咽"))

        let mimo = OpenAICompatibleTTSAudioProvider(
            configuration: .init(service: .mimo, baseURL: "https://api.xiaomimimo.com/v1/", model: "mimo-v2.5-tts", key: "k"),
            voice: "冰糖"
        )
        let chat = try mimo.request(text: "旁白。")
        #expect(chat.url?.absoluteString == "https://api.xiaomimimo.com/v1/chat/completions")
        #expect(chat.value(forHTTPHeaderField: "api-key") == "k")
        let wav = Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["audio": ["data": wav.base64EncodedString()]]]]])
        #expect(try OpenAICompatibleTTSAudioProvider.miMoAudio(from: response) == wav)
    }

    @Test("an imported source's template receives the line's emotion and direction")
    func importedTemplateReceivesDelivery() throws {
        let template = "https://tts.example/speak?t={{text}}&e={{emotion}}&i={{instruct}}"
        #expect(CustomHTTPProvider.templateTakesDelivery(template))
        let url = try #require(CustomHTTPProvider.buildURL(
            template: template, text: "走", title: "", rate: 0.5,
            delivery: TTSDelivery(emotion: .angry, intensity: 3)
        ))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "e" }?.value == "angry")
        #expect(items.first { $0.name == "i" }?.value?.contains("強烈生氣") == true)
        let narration = try #require(CustomHTTPProvider.buildURL(template: template, text: "走", title: "", rate: 0.5))
        #expect(narration.absoluteString.contains("e=neutral"))
    }
}

/// The service end to end, with a scripted model and a temporary store.
@MainActor
@Suite("AI multi-voice narration service")
struct AIDialogueCastServiceTests {
    private actor ScriptedProvider: LLMProviding {
        let identifier = "dialogue-fixture"
        let defaultModel = "fixture"
        private(set) var calls = 0
        private let failing: Bool

        init(failing: Bool = false) { self.failing = failing }

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            calls += 1
            if failing { throw LLMError.networkError("fixture") }
            let payload = request.messages.last?.content ?? ""
            let ids = payload.matches(of: /【(q\d+)】/).map { String($0.1) }
            var lines: [String: Any] = [:]
            for (index, id) in ids.enumerated() {
                lines[id] = [index.isMultiple(of: 2) ? "池瑤" : "張若塵", index == 0 ? "angry" : "neutral", 2]
            }
            let json = try JSONSerialization.data(withJSONObject: [
                "lines": lines,
                "characters": [["池瑤", "female", "young", "清冷"], ["張若塵", "male", "young", ""]],
            ])
            return .init(content: String(decoding: json, as: UTF8.self), provider: identifier, model: defaultModel, finishReason: "stop")
        }

        nonisolated func stream(_ request: LLMGenerationRequest, model: String?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static let text = "池瑤看著他。「你來了。」\n「我來了。」張若塵笑道。\n「坐。」"

    private func temporaryStore() -> (AIDialogueCastStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dialogue-\(UUID().uuidString)")
        return (AIDialogueCastStore(directory: directory), directory)
    }

    @Test("one analysis per chapter, shared by concurrent callers, kept on disk for the next launch")
    func analysesOnceAndPersists() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ScriptedProvider()
        let service = AIDialogueCastService(store: store, provider: provider)
        let book = UUID()
        let request = AIDialogueCastService.Request(bookID: book, chapterIndex: 2, text: Self.text, includeInstruct: false)
        #expect(service.readiness(request) == .needsAnalysis)

        async let first = service.analyze(request)
        async let second = service.analyze(request)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(await provider.calls == 1)
        #expect(a.speakers == ["池瑤", "張若塵"])
        #expect(a.lines.first?.delivery?.emotion == .angry)
        guard case .ready = service.readiness(request) else {
            Issue.record("analysed chapter must be ready")
            return
        }
        #expect(service.roster(forBook: book).character(named: "池瑤")?.gender == .female)
        #expect(service.characters(forBook: book, through: 1).isEmpty)
        #expect(service.characters(forBook: book, through: 2).count == 2)

        let relaunched = AIDialogueCastService(store: store, provider: provider)
        let reloaded = try await relaunched.analyze(request)
        #expect(reloaded == a)
        #expect(await provider.calls == 1)
        #expect(relaunched.roster(forBook: book).characters.count == 2)
    }

    @Test("a failed analysis is remembered for that text, so playback does not wait on it again")
    func failureFallsBackToTheProse() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AIDialogueCastService(store: store, provider: ScriptedProvider(failing: true))
        let request = AIDialogueCastService.Request(bookID: UUID(), chapterIndex: 0, text: Self.text, includeInstruct: false)
        await #expect(throws: LLMError.self) { try await service.analyze(request) }
        #expect(service.readiness(request) == .unavailable)
    }

    @Test("automatic voices are assigned once and survive later chapters")
    func autoVoicesStick() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AIDialogueCastService(store: store, provider: ScriptedProvider())
        let book = UUID()
        try await service.analyze(.init(bookID: book, chapterIndex: 0, text: Self.text, includeInstruct: false))
        let pool = TTSVoiceCandidates.Pool(
            candidates: [
                .init(storageValue: "edge:f", gender: .female, age: .young),
                .init(storageValue: "edge:m", gender: .male, age: .young),
                .init(storageValue: "edge:n", gender: .female, age: .adult),
            ],
            narrator: "edge:n"
        )
        service.assignAutoVoices(forBook: book, family: .edge, explicit: [:], pool: pool)
        #expect(service.autoVoices(forBook: book, family: .edge) == ["池瑤": "edge:f", "張若塵": "edge:m"])
        service.assignAutoVoices(forBook: book, family: .edge, explicit: ["池瑤": "edge:n"], pool: pool)
        #expect(service.autoVoices(forBook: book, family: .edge)["張若塵"] == "edge:m")
        #expect(service.autoVoices(forBook: book, family: .system).isEmpty)
    }
}

/// Consecutive chunks follow each other on one node, with no gap.
@MainActor
@Suite("TTS chunk gapless queue")
struct TTSChunkGaplessTests {
    private final class Recorder: TTSChunkAudioPlayerDelegate {
        var advances = 0
        var finishes = 0
        func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool) { finishes += 1 }
        func chunkAudioPlayerDidAdvanceToQueuedChunk(_ player: TTSChunkAudioPlayer) { advances += 1 }
    }

    /// Mono 16-bit PCM WAV of a constant-amplitude tone, so silence anywhere is a gap.
    private static func tone(seconds: Double, frequency: Double, sampleRate: Int = 24_000) -> Data {
        let samples = (0..<Int(Double(sampleRate) * seconds)).map {
            Int16(8_000 * sin(2 * Double.pi * frequency * Double($0) / Double(sampleRate)))
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + size); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(size)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return data
    }

    @Test("the queued chunk is rendered right behind the current one")
    func queuedChunkFollowsWithoutGap() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let player = TTSChunkAudioPlayer(manualRenderingFormat: format)
        try player.load(data: Self.tone(seconds: 1.0, frequency: 440))
        player.rate = 1
        #expect(try player.enqueue(data: Self.tone(seconds: 1.0, frequency: 660)))
        #expect(player.play())

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        var rendered: [Float] = []
        while rendered.count < 44_000 {
            #expect(try player.engine.renderOffline(2_400, to: buffer) == .success)
            rendered += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            try await Task.sleep(for: .milliseconds(1))
        }
        // A tone crosses zero, but never stays near it for long: 5 ms of quiet is a gap.
        var quietRun = 0, longestQuiet = 0
        for sample in rendered[2_400..<44_000] {
            quietRun = abs(sample) < 0.001 ? quietRun + 1 : 0
            longestQuiet = max(longestQuiet, quietRun)
        }
        #expect(longestQuiet < 120, "longest silence \(longestQuiet) frames")
        player.clear()
    }

    @Test("a chunk in another format is not queued; it loads at the boundary instead")
    func mismatchedFormatIsNotQueued() throws {
        let player = TTSChunkAudioPlayer()
        try player.load(data: Self.tone(seconds: 0.2, frequency: 440, sampleRate: 24_000))
        #expect(try player.enqueue(data: Self.tone(seconds: 0.2, frequency: 440, sampleRate: 16_000)) == false)
        #expect(!player.hasQueuedChunk)
        player.clear()
    }

    @Test("on the real output the player advances once, then finishes once")
    func advancesThenFinishes() async throws {
        let player = TTSChunkAudioPlayer()
        let recorder = Recorder()
        player.delegate = recorder
        try player.load(data: Self.tone(seconds: 0.6, frequency: 440))
        #expect(try player.enqueue(data: Self.tone(seconds: 0.6, frequency: 660)))
        #expect(player.play())
        let deadline = ContinuousClock.now + .seconds(10)
        while recorder.finishes == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recorder.advances == 1)
        #expect(recorder.finishes == 1)
        #expect(!player.hasQueuedChunk)
        player.clear()
    }
}
