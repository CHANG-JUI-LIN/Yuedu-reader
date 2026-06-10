import Testing
import Foundation
@testable import yuedu_app

struct TTSCoordinatorTests {

    // MARK: - CustomHTTPProvider.buildURL

    @Test func buildURL_replacesAllPlaceholders() {
        let template = "https://tts.example.com/api?text={{text}}&title={{title}}&speed={{speakSpeed}}"
        let url = CustomHTTPProvider.buildURL(template: template, text: "你好世界", title: "第一章", rate: 0.5)
        #expect(url != nil)
        let str = url!.absoluteString
        #expect(str.contains("%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C"))  // "你好世界" URL-encoded
        #expect(str.contains("%E7%AC%AC%E4%B8%80%E7%AB%A0"))            // "第一章" URL-encoded
        #expect(str.contains("%2B0%25"))                                  // Edge TTS rate +0%
    }

    @Test func buildURL_emptyTemplate_returnsNil() {
        let url = CustomHTTPProvider.buildURL(template: "", text: "test", title: "", rate: 0.5)
        #expect(url == nil)
    }

    @Test func buildURL_noPlaceholders_returnsBaseURL() {
        let template = "https://tts.example.com/static.mp3"
        let url = CustomHTTPProvider.buildURL(template: template, text: "anything", title: "", rate: 0.5)
        #expect(url?.absoluteString == template)
    }

    @Test func buildURL_usesEdgeSpeakSpeedFormat() {
        let template = "https://tts.example.com/api?speed={{speakSpeed}}"
        let url = CustomHTTPProvider.buildURL(template: template, text: "", title: "", rate: 0.65)
        #expect(url?.absoluteString.contains("%2B30%25") == true)
    }

    @Test func httpProviderDisplayName() {
        #expect(CustomHTTPProvider().displayName == "網路語音")
    }

    @Test func directChapterAudioResolverAcceptsAudioURL() {
        let request = DirectChapterAudioResolver.request(from: "https://audio.example.com/book/001.mp3")

        #expect(request?.url?.absoluteString == "https://audio.example.com/book/001.mp3")
    }

    @Test func directChapterAudioResolverAcceptsLegadoURLHeaders() {
        let text = #"https://audio.example.com/book/001.m4a,{"headers":{"Referer":"https://book.example.com","User-Agent":"Yuedu"}}"#

        let request = DirectChapterAudioResolver.request(from: text)

        #expect(request?.url?.absoluteString == "https://audio.example.com/book/001.m4a")
        #expect(request?.value(forHTTPHeaderField: "Referer") == "https://book.example.com")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "Yuedu")
    }

    @Test func directChapterAudioResolverExtractsPlaybackLinkLine() {
        let text = """
        本章音訊
        播放直鏈：
        https://cdn.example.com/audio/episode.aac?token=abc
        """

        let request = DirectChapterAudioResolver.request(from: text)

        #expect(request?.url?.absoluteString == "https://cdn.example.com/audio/episode.aac?token=abc")
    }

    @Test func directChapterAudioResolverRejectsNormalChapterText() {
        let request = DirectChapterAudioResolver.request(from: "第一章\n這是一段正常小說內容，裡面沒有音訊。")

        #expect(request == nil)
    }

    @Test func playbackRoutingUsesHTTPForDirectChapterAudioWithoutTemplate() {
        #expect(
            TTSPlaybackRouting.shouldUseHTTP(
                text: "https://audio.example.com/book/001.mp3",
                httpTemplate: "",
                useSystemVoice: false
            )
        )
        #expect(
            !TTSPlaybackRouting.shouldUseHTTP(
                text: "第一章\n普通章節文字",
                httpTemplate: "",
                useSystemVoice: false
            )
        )
    }

    @Test func legadoVoiceSourceJSONParsesNameURLAndNumericID() throws {
        let json = """
        [
          {
            "id": 1641697053905,
            "name": "2.推薦 百度AI 情感杜逍遙",
            "url": "http://ai.baidu.com/aidemo?type=tns&tex={{java.encodeURI(java.encodeURI(speakText))}}",
            "header": ""
          },
          {
            "id": 0,
            "name": "說明",
            "url": ""
          }
        ]
        """

        let sources = try TTSSourceJSONParser.parse(data: Data(json.utf8))

        #expect(sources.count == 1)
        #expect(sources[0].id == "1641697053905")
        #expect(sources[0].name == "2.推薦 百度AI 情感杜逍遙")
        #expect(sources[0].urlTemplate.contains("{{java.encodeURI(java.encodeURI(speakText))}}"))
    }
}
