import Foundation
import Testing
@testable import yuedu_app

/// Legado decodes Base64 with `android.util.Base64` (`java.base64DecodeToByteArray`, `data:`
/// URLs) and hutool (`java.base64Decode`); each expectation is what that decoder gives.
@Suite("Legado Base64")
struct LegadoBase64Tests {
    private func bytes(_ data: Data?) -> [UInt8]? { data.map(Array.init) }

    @Test("雨鹿小说: padding is optional")
    func paddingOptional() {
        #expect(bytes(LegadoBase64.androidDecode("QQ")) == [0x41])
        #expect(bytes(LegadoBase64.androidDecode("QUI")) == [0x41, 0x42])
        #expect(bytes(LegadoBase64.androidDecode("QQ==")) == [0x41])
        #expect(bytes(LegadoBase64.androidDecode("QUI=")) == [0x41, 0x42])
        #expect(bytes(LegadoBase64.androidDecode("")) == [])
    }

    @Test("a character outside the alphabet is passed over")
    func skipsOtherCharacters() {
        #expect(bytes(LegadoBase64.androidDecode("QU\nJD\r\n")) == [0x41, 0x42, 0x43])
        #expect(bytes(LegadoBase64.androidDecode(#"a\/8="#)) == [0x6B, 0xFF])
        #expect(bytes(LegadoBase64.androidDecode("QUJD中")) == [0x41, 0x42, 0x43])
        // android's DEFAULT alphabet has no `-`/`_`: they are passed over too.
        #expect(bytes(LegadoBase64.androidDecode("-QUJD_")) == [0x41, 0x42, 0x43])
    }

    @Test("what android calls bad base-64")
    func badBase64() {
        #expect(LegadoBase64.androidDecode("Q") == nil)
        #expect(LegadoBase64.androidDecode("=QQ") == nil)
        #expect(LegadoBase64.androidDecode("Q=Q") == nil)
        #expect(LegadoBase64.androidDecode("QQ=") == nil)
        #expect(LegadoBase64.androidDecode("QQ==QQ") == nil)
        #expect(LegadoBase64.androidDecode("QUI==") == nil)
    }

    @Test("hutool reads both alphabets and never refuses")
    func hutool() {
        #expect(Array(LegadoBase64.hutoolDecode("-_-_")) == [0xFB, 0xFF, 0xBF])
        #expect(Array(LegadoBase64.hutoolDecode("+/+/")) == [0xFB, 0xFF, 0xBF])
        #expect(Array(LegadoBase64.hutoolDecode("QQ")) == [0x41])
        #expect(Array(LegadoBase64.hutoolDecode("Q")) == [])
        #expect(Array(LegadoBase64.hutoolDecode("Q=Q=")) == [0x41])
        #expect(String(decoding: LegadoBase64.hutoolDecode("5Lit5paH"), as: UTF8.self) == "中文")
    }

    @Test("java.base64DecodeToByteArray reads unpadded text")
    func bridgeByteArray() {
        let bridge = LegadoJSBridge()
        #expect(bridge.base64DecodeToByteArray("AH+A/w") == [0, 127, 128, 255])
        #expect(bridge.base64Decode("5Lit5paH") == "中文")
    }
}
