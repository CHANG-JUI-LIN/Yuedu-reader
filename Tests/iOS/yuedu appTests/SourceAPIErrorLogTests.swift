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
}
