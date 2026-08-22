import Foundation
import Testing
@testable import yuedu_app

@Suite("Source API Error Envelope")
struct SourceAPIErrorLogTests {
    @Test("chapter error envelopes are rejected without swallowing JSON prose")
    func chapterErrorEnvelopeClassification() {
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(#"{"error":"Unauthorized"}"#) == "Unauthorized")
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            #"{"code":401,"message":"token expired","data":null}"#
        ) == "token expired")
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            #"{"status":"failed","message":"upstream unavailable"}"#
        ) == "upstream unavailable")

        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            #"{"code":0,"message":"ok"}"#
        ) == nil)
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            #"{"error":"a character's mistake","content":"This is the chapter prose."}"#
        ) == nil)
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            #"{"code":500,"message":"part of the story","data":{"content":"正文"}}"#
        ) == nil)
    }

    @Test("transport error pages cannot become chapter prose")
    func chapterTransportFailureClassification() {
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            "Request failed: Web server is down Error code 522 Visit cloudflare.com"
        ) == "Cloudflare 522")
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            "请求失败: 所有接口均请求失败 undefined is not an object"
        )?.contains("所有接口均请求失败") == true)
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            "她望着屏幕上的 Cloudflare 介绍，说：Web server is down 只是文章标题。"
        ) == nil)
        #expect(SourceAPIErrorLog.chapterErrorEnvelopeMessage(
            "第522章 她排查了服务器错误，故事仍在继续。"
        ) == nil)
    }
}
