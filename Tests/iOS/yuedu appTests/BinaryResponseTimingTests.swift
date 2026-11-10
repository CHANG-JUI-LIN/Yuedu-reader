import Foundation
import Testing
@testable import yuedu_app

/// What 番茄听书 (YCK1330) does with a chapter's audio, stage by stage, timed: the audio
/// comes down as `url,{"type":"hex"}` (the hex of its bytes), `HexUtil.decodeHex` turns it into
/// a Java `byte[]`, every audio sample is decrypted in place (`Arrays.copyOfRange` →
/// `Cipher.doFinal` → `System.arraycopy`), the first 400 000 bytes are scanned for boxes to
/// rename, `HexUtil.encodeHexStr` makes hex again and `java.downloadFile(hex, …m4a)` writes it.
/// A source script has 30 s (`JSCoreEngine.jsTimeout`) for all of it. Each stage runs as its
/// own evaluation so one that runs out of time is named; the bytes stay on `globalThis`.
///
/// 11-09, 8 000 000 bytes, simulator, before: the request 5326 ms, `decodeHex` 270, a sample
/// 34 ms (`Arrays.copyOfRange` read the whole array: about 1470 s for the file), the scan 3,
/// `encodeHexStr` 617, `downloadFile` 1617. After (8 749 871 bytes): the request 308 ms,
/// `decodeHex` 278, a sample 46 µs (≈ 2.1 s for the file), `encodeHexStr` 38, `downloadFile`
/// 354 — about 3.1 s in all; 22 MB about 7.3 s.
@Suite("Binary response timing", .serialized)
struct BinaryResponseTimingTests {
    /// How many bytes an audio sample holds (AAC at 44.1 kHz is about 43 frames a second, so
    /// 8.7 MB at 64 kbit/s is about 18 minutes and 46 000 samples), and how many are timed.
    static let sampleBytes = 190
    static let measuredSamples = 2_000

    /// 8 749 871 bytes is a chapter's audio that the 8 MiB page limit refused (11-09); 22 MB is
    /// the most the source allows itself.
    @Test(.timeLimit(.minutes(10)), arguments: [8_749_871, 22_000_000])
    func fanqieAudioStages(audioBytes: Int) async throws {
        BinaryPayloadURLProtocol.payload = Self.payload(count: audioBytes)
        let source = BookSource(
            bookSourceUrl: "https://\(BinaryPayloadURLProtocol.host)/source#\(UUID().uuidString)",
            bookSourceName: "Binary timing"
        )
        let host = SourceScriptHost(bridgeFor: source, requestSession: BinaryPayloadURLProtocol.session())
        let audioURL = "https://\(BinaryPayloadURLProtocol.host)/audio.m4a"

        func stage(_ name: String, _ script: String) async -> (String?, Int) {
            let clock = ContinuousClock()
            let start = clock.now
            let result = await host.run { $0.evaluateSourceScript(script) }
            let elapsed = clock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            print("⏱ binary \(audioBytes) \(name): \(ms) ms → \(result.map { String($0.prefix(120)) } ?? "nil")")
            return (result, ms)
        }

        // The request stage's Swift share: the hex the script gets, and the text decode
        // `LegadoHTTPResult.make` runs on every response.
        let clock = ContinuousClock()
        let payload = BinaryPayloadURLProtocol.payload
        var hexCount = 0
        let hexTime = clock.measure { hexCount = LegadoJSBridge.hexString(payload).utf8.count }
        var textCount = 0
        let textTime = clock.measure { textCount = LegadoJSBridge.decodeData(payload, response: nil).utf16.count }
        print("⏱ binary \(audioBytes) swift hexString: \(hexTime) (\(hexCount)), decodeData as text: \(textTime) (\(textCount))")

        let (hexLength, _) = await stage("ajax type:hex", """
            globalThis.__bt = { hex: String(java.ajax('\(audioURL),{"headers":{},"type":"hex"}')) };
            String(globalThis.__bt.hex.length)
            """)
        #expect(hexLength == String(audioBytes * 2))

        let (decoded, _) = await stage("HexUtil.decodeHex", """
            globalThis.__bt.bytes = Packages.cn.hutool.core.util.HexUtil.decodeHex(globalThis.__bt.hex);
            globalThis.__bt.hex = '';
            String(globalThis.__bt.bytes.length)
            """)
        #expect(decoded == String(audioBytes))

        let (_, decryptMs) = await stage("decrypt \(Self.measuredSamples) samples", """
            var bytes = globalThis.__bt.bytes;
            var CS = Packages.java.nio.charset.Charset.forName('ISO-8859-1');
            function S2B(x) { return new Packages.java.lang.String(String(x)).getBytes(CS); }
            var sk = new Packages.javax.crypto.spec.SecretKeySpec(S2B('0123456789abcdef'), 'AES');
            var C = Packages.javax.crypto.Cipher;
            var cp = C.getInstance('AES/CTR/NoPadding');
            var Arr = Packages.java.util.Arrays, Sys = Packages.java.lang.System, Iv = Packages.javax.crypto.spec.IvParameterSpec;
            var off = 1000, sz = \(Self.sampleBytes);
            for (var k = 0; k < \(Self.measuredSamples); k++) {
                var s16 = '';
                for (var i = 0; i < 8; i++) s16 += String.fromCharCode(bytes[off + i] & 255);
                for (var i = 0; i < 8; i++) s16 += String.fromCharCode(0);
                cp.init(C.DECRYPT_MODE, sk, new Iv(S2B(s16)));
                Sys.arraycopy(cp.doFinal(Arr.copyOfRange(bytes, off, off + sz)), 0, bytes, off, sz);
                off += sz;
            }
            String(bytes.length)
            """)
        let samples = audioBytes / Self.sampleBytes
        print("⏱ binary \(audioBytes) decrypt: \(decryptMs * 1000 / Self.measuredSamples) µs a sample, ≈ \(decryptMs * samples / max(1, Self.measuredSamples)) ms for the \(samples) samples of the whole file")

        _ = await stage("scan 400000 bytes", """
            var bytes = globalThis.__bt.bytes, hits = 0;
            var mend = Math.min(bytes.length, 400000);
            for (var q = 0; q + 4 <= mend; q++) {
                var c0 = bytes[q] & 255, c1 = bytes[q + 1] & 255, c2 = bytes[q + 2] & 255, c3 = bytes[q + 3] & 255;
                if (c0 === 0x65 && c1 === 0x6e && c2 === 0x63 && c3 === 0x61) hits++;
            }
            String(hits)
            """)

        let (encodedLength, _) = await stage("HexUtil.encodeHexStr", """
            globalThis.__bt.out = String(Packages.cn.hutool.core.util.HexUtil.encodeHexStr(globalThis.__bt.bytes));
            globalThis.__bt.bytes = null;
            String(globalThis.__bt.out.length)
            """)
        #expect(encodedLength == String(audioBytes * 2))

        let (path, _) = await stage("downloadFile hex", """
            var path = String(java.downloadFile(globalThis.__bt.out, 'https://x/fa0_\(UUID().uuidString.prefix(8)).m4a,{"type":"m4a"}'));
            globalThis.__bt = null;
            path
            """)
        #expect(path?.hasSuffix(".m4a") == true)
    }

    /// Bytes that are not text: every value 0–255, in no repeating order a decoder could
    /// shortcut.
    static func payload(count: Int) -> Data {
        var data = Data(count: count)
        var state: UInt32 = 2_463_534_242
        data.withUnsafeMutableBytes { raw in
            for index in 0..<count {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                raw[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        return data
    }
}

/// Answers `binary-payload.test` with `payload`, as an audio file.
private final class BinaryPayloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "binary-payload.test"
    nonisolated(unsafe) static var payload = Data()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BinaryPayloadURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "audio/mp4", "Content-Length": "\(Self.payload.count)"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
