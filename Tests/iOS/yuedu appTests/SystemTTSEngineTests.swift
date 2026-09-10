import AVFoundation
import CoreGraphics
import Testing
@testable import yuedu_app

struct SystemTTSEngineTests {

    @Test func cancelledActiveUtteranceCanRecover() {
        #expect(
            SystemTTSEngine.shouldRecoverFromCancelledUtterance(
                isPlaying: true,
                isPaused: false,
                hasActiveUtterance: true,
                afterMediaServicesReset: true
            )
        )
    }

    @Test func cancelledUtteranceIsIgnoredAfterStopOrPause() {
        #expect(
            !SystemTTSEngine.shouldRecoverFromCancelledUtterance(
                isPlaying: false,
                isPaused: false,
                hasActiveUtterance: true,
                afterMediaServicesReset: true
            )
        )
        #expect(
            !SystemTTSEngine.shouldRecoverFromCancelledUtterance(
                isPlaying: true,
                isPaused: true,
                hasActiveUtterance: true,
                afterMediaServicesReset: true
            )
        )
        #expect(
            !SystemTTSEngine.shouldRecoverFromCancelledUtterance(
                isPlaying: true,
                isPaused: false,
                hasActiveUtterance: false,
                afterMediaServicesReset: true
            )
        )
        #expect(
            !SystemTTSEngine.shouldRecoverFromCancelledUtterance(
                isPlaying: true,
                isPaused: false,
                hasActiveUtterance: true,
                afterMediaServicesReset: false
            )
        )
    }

    // MARK: - TTSTextChunker

    @Test func chunkerKeepsSentencesTogetherWithinParagraph() {
        // Sentence terminators no longer split — a single paragraph is read as one
        // continuous, gap-free chunk.
        let chunks = TTSTextChunker.split("第一句。第二句！第三句？", targetChunkLength: 120)
        #expect(chunks == ["第一句。第二句！第三句？"])
    }

    @Test func chunkerSplitsOnParagraphBoundaries() {
        // Paragraph boundaries (newlines) are the natural break between chunks.
        let chunks = TTSTextChunker.split("第一段。\n第二段。", targetChunkLength: 120)
        #expect(chunks == ["第一段。", "第二段。"])
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

    @Test func chunkerOmitsDecorativeParagraphsWithoutChangingSourceOffsets() {
        let separator = String(repeating: "=", count: 58)
        let text = "Preface\n\(separator)\n更多精校小说\n\(separator)\n正文開始。"
        let chunks = TTSTextChunker.splitWithRanges(text, targetChunkLength: 120)
        #expect(chunks.map(\.text) == ["Preface", "更多精校小说", "正文開始。"])
        for chunk in chunks {
            #expect((text as NSString).substring(with: chunk.sourceRange) == chunk.text)
        }
    }

    @Test func chunkerPreservesPunctuationSplitWithinSameParagraph() {
        let chunks = TTSTextChunker.split("你好啊！……\n下一段。", targetChunkLength: 3)
        #expect(chunks == ["你好啊！……", "下一段。"])
    }

    @Test func chunkerOmitsLongSeparatorsAcrossLengthCaps() {
        let text = "章節一\n" + String(repeating: "*", count: 160) + "\n章節二"
        #expect(TTSTextChunker.split(text, targetChunkLength: 30) == ["章節一", "章節二"])
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

    // MARK: - Voice selection

    @Test func chineseTextSelectsChineseVoice() {
        let text = "今天天氣很好"

        #expect(SystemTTSEngine.preferredLanguage(for: text).hasPrefix("zh"))
        #expect(SystemTTSEngine.preferredVoice(for: text)?.language.hasPrefix("zh") == true)
    }

    @Test func nonChineseTextUsesCurrentSystemLanguage() {
        let text = "This is an English sentence."

        #expect(
            SystemTTSEngine.preferredLanguage(for: text)
                == AVSpeechSynthesisVoice.currentLanguageCode()
        )
    }
}
