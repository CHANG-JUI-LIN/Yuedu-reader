import Foundation
import Testing
@testable import yuedu_app

/// 圖片解碼腳本（`coverDecodeJs`／`ruleContent.imageDecode`）拿到的 `result` 是位元組陣列，
/// 同時也要像 java.io.InputStream 一樣能讀。
///
/// 反饋 #135：🥝猕猴桃漫画 的封面解碼呼叫 `result.readAllBytes()`——legado-E／Sigma／MD3 把封面下載的
/// `byteStream()` 交給 `coverDecodeJs`——我們的 `result` 是純數字陣列，腳本拋 TypeError，
/// 封面一律是加密的原始位元組、畫不出來。
@Suite("Image decode result reads as a stream", .serialized)
@MainActor
struct ImageDecodeResultStreamTests {

    private static let plain = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
    private static let xored = Data(plain.map { $0 ^ 0x5A })

    @Test("a rule that XORs result.readAllBytes() decodes the image")
    func readAllBytesXOR() {
        let script = """
            var bytes = result.readAllBytes();
            for (var i = 0; i < bytes.length; i++) bytes[i] = bytes[i] ^ 0x5a;
            bytes
            """
        #expect(JSCoreEngine().evaluateBytes(script, data: Self.xored) == Self.plain)
    }

    @Test("readAllBytes() is a copy: the rule can still index and rewrite result itself")
    func readAllBytesIsACopy() {
        let script = """
            var copy = result.readAllBytes();
            copy[0] = 0;
            for (var i = 0; i < result.length; i++) result[i] = result[i] ^ 0x5a;
            result
            """
        #expect(JSCoreEngine().evaluateBytes(script, data: Self.xored) == Self.plain)
    }

    @Test("read, readNBytes, available and skip follow java.io.InputStream")
    func streamReads() {
        let script = """
            var out = [result.available(), result.read()];
            out.push(result.readNBytes(2)[1]);
            out.push(result.available(), result.skip(10), result.read(), result.readAllBytes().length);
            result.close();
            out
            """
        // read() at the end is -1, which a byte array carries as 255.
        #expect(JSCoreEngine().evaluateBytes(script, data: Data([9, 8, 7, 6])) == Data([4, 9, 7, 1, 1, 255, 0]))
    }

    @Test("the stream methods are invisible to JSON and live on result alone")
    func methodsAreNonEnumerableAndLocal() {
        let script = """
            JSON.stringify(result) === '[1,2,3]'
                && Object.keys(result).length === 3
                && typeof [].readAllBytes === 'undefined' ? result : null
            """
        #expect(JSCoreEngine().evaluateBytes(script, data: Data([1, 2, 3])) == Data([1, 2, 3]))
    }

    @Test("a coverDecodeJs that reads result as a stream decodes through the source's session")
    func coverRuleThroughSession() async {
        let source = BookSource(
            bookSourceUrl: "https://readallbytes-\(UUID().uuidString).test",
            bookSourceName: "readAllBytes stub"
        )
        let rule = "@js:var b = result.readAllBytes(); for (var i = 0; i < b.length; i++) b[i] ^= 0x5a; b"
        let decoded = await SourceImageDecoder.decode(
            Self.xored, src: "https://cdn.example.test/cover.jpg", ruleJs: rule, source: source
        )
        #expect(decoded == Self.plain)
    }

    @Test("the imageDecode side-effect hook binds the same result, so a stream read does not throw")
    func decodeHookReadsStream() {
        var source = BookSource(
            bookSourceUrl: "https://readallbytes-hook-\(UUID().uuidString).test",
            bookSourceName: "readAllBytes hook"
        )
        source.ruleContent.imageDecode = "@js:result.readAllBytes(); result.available(); result"
        let bridge = ModernParserBridge(source: source)
        bridge.runImageDecodeHook(src: "https://cdn.example.test/page.jpg", ruleJs: source.ruleContent.imageDecode)
        // An empty byte array is no image, so the engine notes that; what must not be there is
        // the rule's own TypeError.
        #expect(bridge.lastSourceScriptError?.contains("TypeError") != true)
    }
}
