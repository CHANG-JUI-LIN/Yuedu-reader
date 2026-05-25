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
