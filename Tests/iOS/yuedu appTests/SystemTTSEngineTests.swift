import AVFoundation
import Testing
@testable import yuedu_app

struct SystemTTSEngineTests {

    // MARK: - TTSTextChunker

    @Test func chunkerSplitsOnSentenceTerminators() {
        let chunks = TTSTextChunker.split("第一句。第二句！第三句？", targetChunkLength: 120)
        #expect(chunks == ["第一句。", "第二句！", "第三句？"])
    }

    @Test func chunkerBreaksOnLengthWhenNoTerminator() {
        let text = String(repeating: "字", count: 50)
        let chunks = TTSTextChunker.split(text, targetChunkLength: 20)
        #expect(chunks.count == 3)              // 20 + 20 + 10
        #expect(chunks.joined().count == 50)
    }

    @Test func chunkerFoldsPunctuationOnlyFragmentIntoPrevious() {
        // The trailing "……" carries no speakable content, so it merges into the prior chunk
        // instead of becoming a silent chunk.
        let chunks = TTSTextChunker.split("你好。……", targetChunkLength: 120)
        #expect(chunks == ["你好。……"])
    }

    @Test func chunkerDropsLeadingNonSpeakableContent() {
        let chunks = TTSTextChunker.split("。。。", targetChunkLength: 120)
        #expect(chunks.isEmpty)
    }

    // MARK: - Rate mapping

    @Test func utteranceRateMapsNormalToSystemDefault() {
        #expect(SystemTTSEngine.utteranceRate(forUIRate: 0.5) == AVSpeechUtteranceDefaultSpeechRate)
    }

    @Test func utteranceRateClampsToSupportedRange() {
        let slow = SystemTTSEngine.utteranceRate(forUIRate: 0.0)
        let fast = SystemTTSEngine.utteranceRate(forUIRate: 5.0)
        #expect(slow >= AVSpeechUtteranceMinimumSpeechRate)
        #expect(fast <= AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test func utteranceRateIsMonotonic() {
        let slow = SystemTTSEngine.utteranceRate(forUIRate: 0.2)
        let normal = SystemTTSEngine.utteranceRate(forUIRate: 0.5)
        let fast = SystemTTSEngine.utteranceRate(forUIRate: 0.65)
        #expect(slow < normal)
        #expect(normal < fast)
    }

    // MARK: - Language detection

    @Test func chineseTextPicksChineseLanguage() {
        #expect(SystemTTSEngine.preferredLanguage(for: "今天天氣很好").hasPrefix("zh"))
    }

    @Test func chineseLanguageDistinguishesScriptVariant() {
        let lang = SystemTTSEngine.preferredLanguage(for: "繁體中文")
        #expect(lang == "zh-TW" || lang == "zh-CN")
    }
}
