import Foundation
import Testing
@testable import yuedu_app

/// A TTS provider that answers HTTP 200 with something other than audio — a rate-limit
/// notice, a quota page, a truncated body — used to have those bytes cached as a segment and
/// only fail minutes later inside `AVAudioFile(forReading:)` as `kAudioFileError_InvalidFile`
/// ('dta?', 1685348671). Three of those in a row ends the listening session, which is how it
/// reached the user: 朗讀失敗：第 N 段語音無法下載.
@Suite("TTS audio payload")
struct TTSAudioPayloadTests {

    @Test("recognised containers are accepted")
    func recognisedContainersAreAccepted() {
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.riffWAV))
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.id3MP3))
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.bareMPEGFrame))
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.m4a))
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.flac))
        #expect(TTSAudioPayload.looksLikeAudioContainer(Self.ogg))
    }

    @Test("error pages and JSON bodies are rejected")
    func nonAudioBodiesAreRejected() {
        #expect(!TTSAudioPayload.looksLikeAudioContainer(Self.data("<!DOCTYPE html><html><body>429</body></html>")))
        #expect(!TTSAudioPayload.looksLikeAudioContainer(Self.data("{\"code\":429,\"msg\":\"quota exceeded\"}")))
        #expect(!TTSAudioPayload.looksLikeAudioContainer(Self.data("rate limit reached, try later")))
    }

    @Test("a body too short to identify is rejected")
    func truncatedBodyIsRejected() {
        // A body cut off mid-transfer cannot be decoded either, and accepting it defers the
        // failure to playback where the cause is unrecoverable from the error alone.
        #expect(!TTSAudioPayload.looksLikeAudioContainer(Data([0xFF, 0xFB, 0x90])))
        #expect(!TTSAudioPayload.looksLikeAudioContainer(Data()))
    }

    @Test("the diagnostic head reports size, hex and printable text")
    func diagnosticHeadDescribesPayload() {
        let head = TTSAudioPayload.diagnosticHead(of: Self.data("{\"code\":429}"))
        #expect(head.contains("bytes=12"))
        #expect(head.contains("hex=7b22636f6465223a3432397d"))
        #expect(head.contains("ascii={\"code\":429}"))
    }

    // MARK: - Fixtures

    private static func data(_ string: String) -> Data { Data(string.utf8) }
    private static func padded(_ prefix: [UInt8]) -> Data {
        Data(prefix + [UInt8](repeating: 0, count: max(0, 12 - prefix.count)))
    }

    private static let riffWAV = padded(Array("RIFF".utf8))
    private static let id3MP3 = padded(Array("ID3".utf8))
    private static let bareMPEGFrame = padded([0xFF, 0xFB, 0x90, 0x00])
    private static let m4a = padded([0x00, 0x00, 0x00, 0x20] + Array("ftyp".utf8))
    private static let flac = padded(Array("fLaC".utf8))
    private static let ogg = padded(Array("OggS".utf8))
}
