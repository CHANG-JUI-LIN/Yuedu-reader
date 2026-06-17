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

    @Test func mimoTTSExtractsAudioFromBodyFunctionLoginCheck() async throws {
        let json = """
        [
          {
            "name": "小米MiMo TTS (终极完全体-修正版)",
            "url": "@js:(function(){var info=source.getLoginInfoMap();var apiKey=info.get('apiKey')||'';var model=info.get('model')||'mimo-v2.5-tts';var voice=info.get('voice')||'mimo_default';var style=info.get('style')||'';var voicePrompt=info.get('voicePrompt')||'';var speedStyles=[];var sp=(typeof speakSpeed!=='undefined'?speakSpeed:10);if(sp>14)speedStyles.push('语速很快');else if(sp>10)speedStyles.push('语速加快');else if(sp<6)speedStyles.push('语速很慢');else if(sp<10)speedStyles.push('语速放慢');if(style)speedStyles.push(style);var text=speakText;if(speedStyles.length>0)text='<style>'+speedStyles.join(' ')+'</style>'+text;source.putLoginHeader(JSON.stringify({'api-key':apiKey}));var msgs=[];if(model==='mimo-v2.5-tts-voicedesign'&&voicePrompt){msgs.push({role:'user',content:voicePrompt});}msgs.push({role:'assistant',content:text});var reqBody={model:model,messages:msgs,audio:{format:'wav'}};if(model==='mimo-v2.5-tts'){reqBody.audio.voice=voice;}var config={method:'POST',body:JSON.stringify(reqBody),headers:{'Content-Type':'application/json'}};return 'https://api.xiaomimimo.com/v1/chat/completions,'+JSON.stringify(config);})();",
            "contentType": "audio/.*",
            "loginCheckJs": "if(result.code()==200){try{var body=JSON.parse(result.body().string());if(body.choices&&body.choices[0]&&body.choices[0].message&&body.choices[0].message.audio){java.setResponseBase64(body.choices[0].message.audio.data,'audio/wav');}else if(body.error){java.log('MiMo TTS error: '+JSON.stringify(body.error));}}catch(e){java.log('MiMo TTS parse error: '+e);}}",
            "loginUi": "[{\\"name\\":\\"apiKey\\",\\"viewName\\":\\"'1. API Key'\\",\\"type\\":\\"text\\",\\"chars\\":[\\"请输入您的密钥\\"]},{\\"name\\":\\"model\\",\\"viewName\\":\\"'2. 核心模型选择'\\",\\"type\\":\\"select\\",\\"chars\\":[\\"mimo-v2.5-tts\\",\\"mimo-v2.5-tts-voicedesign\\"],\\"default\\":\\"mimo-v2.5-tts\\"},{\\"name\\":\\"voice\\",\\"viewName\\":\\"'3. 预设音色(模式1用)'\\",\\"type\\":\\"select\\",\\"chars\\":[\\"mimo_default\\",\\"冰糖\\",\\"茉莉\\",\\"苏打\\",\\"Chloe\\"],\\"default\\":\\"茉莉\\"}]",
            "concurrentRate": "1/1000"
          }
        ]
        """
        let sources = try TTSSourceJSONParser.parse(data: Data(json.utf8))
        let source = try #require(sources.first)

        let gs = GlobalSettings.shared
        let previousTemplate = gs.httpTtsUrlTemplate
        let previousHeaders = gs.httpTtsHeaders
        let previousSources = gs.importedTTSSources
        let previousUseSystemVoice = gs.ttsUseSystemVoice
        defer {
            gs.httpTtsUrlTemplate = previousTemplate
            gs.httpTtsHeaders = previousHeaders
            gs.importedTTSSources = previousSources
            gs.ttsUseSystemVoice = previousUseSystemVoice
            LoginManager.shared.clearLogin(sourceUrl: source.id)
            MimoTTSTestURLProtocol.reset()
        }

        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00])
        let responseJSON = """
        {
          "choices": [
            {
              "message": {
                "audio": {
                  "data": "\(audio.base64EncodedString())"
                }
              }
            }
          ]
        }
        """
        MimoTTSTestURLProtocol.responseData = Data(responseJSON.utf8)
        URLProtocol.registerClass(MimoTTSTestURLProtocol.self)
        defer { URLProtocol.unregisterClass(MimoTTSTestURLProtocol.self) }

        gs.importedTTSSources = [source]
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = [:]
        gs.ttsUseSystemVoice = false
        LoginManager.shared.storeLoginInfo(
            sourceUrl: source.id,
            info: [
                "apiKey": "test-key",
                "model": "mimo-v2.5-tts",
                "voice": "茉莉",
                "style": "开心"
            ]
        )

        let data = try await CustomHTTPProvider().audioData(for: "你好", title: "測試", rate: 1.0)

        #expect(data == audio)
        #expect(MimoTTSTestURLProtocol.lastRequest?.url?.absoluteString == "https://api.xiaomimimo.com/v1/chat/completions")
        #expect(MimoTTSTestURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MimoTTSTestURLProtocol.lastRequest?.value(forHTTPHeaderField: "api-key") == "test-key")
        #expect(MimoTTSTestURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let requestBody = try #require(MimoTTSTestURLProtocol.lastRequestBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == "mimo-v2.5-tts")
        let requestAudio = try #require(body["audio"] as? [String: Any])
        #expect(requestAudio["format"] as? String == "wav")
        #expect(requestAudio["voice"] as? String == "茉莉")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["role"] == "assistant")
        #expect(messages.last?["content"] == "<style>开心</style>你好")
    }
}

private final class MimoTTSTestURLProtocol: URLProtocol {
    static var responseData = Data()
    static var lastRequest: URLRequest?
    static var lastRequestBody: Data?

    static func reset() {
        responseData = Data()
        lastRequest = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.xiaomimimo.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBody)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
