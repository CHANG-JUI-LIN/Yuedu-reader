import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import yuedu_app

/// `TTSChunkAudioPlayer` decodes HTTP TTS chunks from memory and plays them through one
/// reusable graph. Build 143 staged every chunk in tmp first (310 MB of a 1.07 GB MetricKit
/// disk-write exception in a day); 回饋中心 #134 heard noise on every voice. The fixture is a
/// real Edge chunk (zh-CN-XiaoxiaoNeural, audio-24khz-48kbitrate-mono-mp3, 13.8 s).
@MainActor
@Suite("TTS chunk audio player")
struct TTSChunkAudioPlayerTests {
    private static let chunkURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TTS/tts-edge-xiaoxiao-24k-48kbps.mp3")

    @Test("loading a chunk writes nothing to the temporary directory")
    func loadWritesNoTemporaryFile() throws {
        let data = try Data(contentsOf: Self.chunkURL)
        let before = try Self.temporaryEntries()
        let player = TTSChunkAudioPlayer()
        try player.load(data: data)
        #expect(player.hasLoadedAudio)
        #expect(try Self.temporaryEntries().subtracting(before).isEmpty)
        player.clear()
    }

    @Test("the in-memory decode matches AVAudioFile sample for sample")
    func decoderMatchesAVAudioFile() throws {
        let reference = try Self.reference()
        let decoder = try TTSChunkDecoder(data: Data(contentsOf: Self.chunkURL))
        let file = try AVAudioFile(forReading: Self.chunkURL)
        #expect(decoder.processingFormat == file.processingFormat)
        #expect(decoder.length == file.length)

        var decoded: [Float] = []
        while let buffer = try decoder.read(frameCapacity: 4096) {
            decoded += Self.channel0(buffer)
        }
        #expect(decoded.count == reference.count)
        let worst = zip(decoded, reference).map { abs($0 - $1) }.max() ?? 1
        #expect(worst == 0)
    }

    @Test("a non-audio body fails to load with the OSStatus AVAudioFile reported")
    func nonAudioBodyThrows() {
        let player = TTSChunkAudioPlayer()
        #expect(throws: NSError.self) {
            try player.load(data: Data("{\"code\":429,\"msg\":\"quota exceeded\"}".utf8))
        }
        #expect(!player.hasLoadedAudio)
    }

    /// What a listener hears at 1× is the decoded chunk, unaltered — this is the A/B for #134
    /// on iOS's own AudioToolbox, with the time-pitch unit in the graph as it is for every
    /// chunk. Measured 234.5 dB against the source: bit-exact, so the unit is not the noise.
    @Test("the whole chunk plays back unaltered at 1x")
    func wholeChunkPlaysUnaltered() async throws {
        let reference = try Self.reference()
        let player = TTSChunkAudioPlayer(manualRenderingFormat: try Self.sourceFormat())
        try player.load(data: Data(contentsOf: Self.chunkURL))
        player.rate = 1
        #expect(player.play())

        let rendered = try await Self.render(player, frames: reference.count)
        let snr = Self.snr(reference, rendered)
        print("⏱ TTSChunkAudioPlayer 1x vs source SNR=\(String(format: "%.1f", snr.db)) dB lag=\(snr.lag)")
        #expect(snr.db > 90)
    }

    /// Offline rendering never reports `.dataPlayedBack`, so the end of a chunk is checked on
    /// the real output, with a chunk short enough to wait for.
    @Test("a chunk reports its end once, after it has played")
    func chunkReportsEndOnce() async throws {
        let player = TTSChunkAudioPlayer()
        let delegate = FinishRecorder()
        player.delegate = delegate
        try player.load(data: Self.toneWAV(seconds: 2.5))
        #expect(abs(player.duration - 2.5) < 0.001)
        #expect(player.play())

        let deadline = ContinuousClock.now + .seconds(10)
        while delegate.finishes == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(delegate.finishes == 1)
        #expect(delegate.lastFlag == true)
        #expect(!player.isPlaying)
        try await Task.sleep(for: .milliseconds(300))
        #expect(delegate.finishes == 1)
        player.clear()
    }

    @Test("seeking plays from the new position")
    func seekPlaysFromNewPosition() async throws {
        let reference = try Self.reference()
        let format = try Self.sourceFormat()
        let player = TTSChunkAudioPlayer(manualRenderingFormat: format)
        try player.load(data: Data(contentsOf: Self.chunkURL))
        player.rate = 1
        player.currentTime = 5
        #expect(abs(player.currentTime - 5) < 0.001)
        #expect(player.play())

        let rendered = try await Self.render(player, frames: Int(format.sampleRate * 2))
        let start = Int(format.sampleRate * 5)
        let expected = Array(reference[start..<(start + rendered.count)])
        // The MP3 decoder re-primes after a seek (ExtAudioFile, as AVAudioFile did): the first
        // few milliseconds differ inaudibly (73 dB), and from 100 ms on it is bit-exact.
        let settled = Int(format.sampleRate * 0.1)
        #expect(Self.snr(expected, rendered).db > 60)
        #expect(Self.snr(Array(expected[settled...]), Array(rendered[settled...])).db > 90)
        #expect(abs(player.currentTime - 7) < 0.1)
    }

    /// The device mixes the 24 kHz chunk up to the hardware rate. Images of the speech above
    /// 12 kHz would be noise that grows with volume; measured here, at a typical 48 kHz route.
    @Test("upsampling to a 48 kHz stereo route adds no audible images or clipping")
    func hardwareRateOutputIsClean() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let player = TTSChunkAudioPlayer(manualRenderingFormat: output)
        try player.load(data: Data(contentsOf: Self.chunkURL))
        player.rate = 1
        #expect(player.play())

        let rendered = try await Self.render(player, frames: 48_000 * 10)
        let images = try Self.energyAbove(12_200, in: rendered, sampleRate: 48_000)
        let peak = rendered.map(abs).max() ?? 0
        print("⏱ TTSChunkAudioPlayer 48k route: energy above 12 kHz=\(String(format: "%.1f", images)) dB peak=\(peak)")
        #expect(images < -60)
        #expect(peak < 1)
    }

    /// 回饋中心 #134's other voice is an imported 小米 MiMo source: `java.setResponseBase64`
    /// hands over the base64 WAV from `choices[0].message.audio.data`. MiMo's docs give no
    /// sample rate, so every rate a TTS server plausibly uses, in every header shape a WAV
    /// writer emits: an extra `LIST` chunk, a `fmt ` with `cbSize`, WAVE_FORMAT_EXTENSIBLE,
    /// the 0xFFFFFFFF sizes a streaming writer leaves, a `data` size past the end of the body,
    /// and an odd-sized chunk with its pad byte. A misread header would turn speech into noise.
    @Test(
        "a MiMo-shaped PCM16 WAV decodes bit-exact under every header variant",
        arguments: [16_000, 22_050, 24_000, 44_100, 48_000]
    )
    func wavHeaderVariantsDecodeBitExact(sampleRate: Int) throws {
        let pcm = Self.speechLikePCM16(frames: sampleRate * 3 + 777, sampleRate: sampleRate)
        for variant in WAVVariant.allCases {
            let decoder = try TTSChunkDecoder(data: Self.wav(pcm, sampleRate: sampleRate, variant: variant))
            #expect(decoder.processingFormat.sampleRate == Double(sampleRate), "\(variant)")
            #expect(decoder.processingFormat.channelCount == 1, "\(variant)")
            var decoded: [Float] = []
            while let buffer = try decoder.read(frameCapacity: AVAudioFrameCount(sampleRate)) {
                decoded += Self.channel0(buffer)
            }
            #expect(decoded.count == pcm.count, "\(variant)")
            let worst = zip(decoded, pcm).map { abs($0 - Float($1) / 32_768) }.max() ?? 1
            #expect(worst == 0, "\(variant) at \(sampleRate) Hz: worst sample error \(worst)")
        }
    }

    /// The same WAV through the whole graph a listener hears — time-pitch at 1×, the mixer's
    /// mono→stereo upmix and its resample to a 48 kHz route. THD+N of a 1 kHz tone isolates
    /// in-band noise, which the >12 kHz image check above cannot see. A 16-bit source's own
    /// quantization floor is about −98 dB at 0.9 full scale.
    @Test("a MiMo-shaped WAV reaches a 48 kHz stereo route at the 16-bit noise floor")
    func wavThroughGraphIsAtNoiseFloor() async throws {
        let sampleRate = 24_000
        let pcm = (0..<(sampleRate * 4)).map {
            Int16((0.9 * 32_767 * sin(2 * Double.pi * 1_000 * Double($0) / Double(sampleRate))).rounded())
        }
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let player = TTSChunkAudioPlayer(manualRenderingFormat: output)
        try player.load(data: Self.wav(pcm, sampleRate: sampleRate, variant: .canonical))
        player.rate = 1
        #expect(player.play())

        let (left, right) = try await Self.renderStereo(player, frames: 48_000 * 3)
        // Skip the resampler's start-up; measure two settled seconds.
        let window = 24_000..<120_000
        let thdnLeft = Self.thdn(Array(left[window]), frequency: 1_000, sampleRate: 48_000)
        let thdnRight = Self.thdn(Array(right[window]), frequency: 1_000, sampleRate: 48_000)
        print("⏱ TTSChunkAudioPlayer MiMo-shaped WAV 24k→48k stereo THD+N L=\(String(format: "%.1f", thdnLeft)) dB R=\(String(format: "%.1f", thdnRight)) dB")
        #expect(thdnLeft < -90)
        #expect(thdnRight < -90)
        #expect((left.map(abs).max() ?? 0) < 1)
    }

    // MARK: - Helpers

    private final class FinishRecorder: TTSChunkAudioPlayerDelegate {
        var finishes = 0
        var lastFlag: Bool?
        func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool) {
            finishes += 1
            lastFlag = flag
        }
    }

    private static func temporaryEntries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
    }

    /// A mono 16-bit 24 kHz 440 Hz tone in a RIFF/WAVE container, as a TTS server could send.
    private static func toneWAV(seconds: Double) -> Data {
        let sampleRate = 24_000
        let samples = (0..<Int(Double(sampleRate) * seconds)).map {
            Int16(8_000 * sin(2 * Double.pi * 440 * Double($0) / Double(sampleRate)))
        }
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + size); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(size)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return data
    }

    enum WAVVariant: CaseIterable {
        case canonical, listChunk, fmtWithCbSize, extensible, streamingSizes, oversizedData, oddChunkPadding
    }

    /// Speech-band tones plus a little noise, near full scale, so a byte-misaligned or
    /// mis-scaled decode cannot hide.
    private static func speechLikePCM16(frames: Int, sampleRate: Int) -> [Int16] {
        var seed: UInt64 = 0x134
        return (0..<frames).map { i in
            let t = Double(i) / Double(sampleRate)
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(Int64(bitPattern: seed >> 11) % 1_000) / 1_000
            let v = 0.9 * (0.5 * sin(2 * .pi * 180 * t) + 0.3 * sin(2 * .pi * 1_234 * t)
                + 0.15 * sin(2 * .pi * 3_700 * t) + 0.05 * noise)
            return Int16(max(-32_768, min(32_767, (v * 32_767).rounded())))
        }
    }

    private static func wav(_ pcm: [Int16], sampleRate: Int, variant: WAVVariant) -> Data {
        func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func u16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func chunk(_ id: String, _ body: [UInt8], size: UInt32? = nil) -> [UInt8] {
            Array(id.utf8) + u32(size ?? UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
        }
        let samples = pcm.flatMap { u16(UInt16(bitPattern: $0)) }
        var fmt = u16(variant == .extensible ? 0xFFFE : 1) + u16(1) + u32(UInt32(sampleRate))
            + u32(UInt32(sampleRate * 2)) + u16(2) + u16(16)
        switch variant {
        case .fmtWithCbSize: fmt += u16(0)
        case .extensible:
            // cbSize 22, 16 valid bits, front-centre, KSDATAFORMAT_SUBTYPE_PCM.
            fmt += u16(22) + u16(16) + u32(4)
                + [0x01, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
        default: break
        }
        var body = Array("WAVE".utf8) + chunk("fmt ", fmt)
        switch variant {
        case .listChunk: body += chunk("LIST", Array("INFOISFT".utf8) + u32(14) + Array("Lavf61.7.100\0\0".utf8))
        case .oddChunkPadding: body += chunk("junk", [1, 2, 3])
        default: break
        }
        switch variant {
        case .streamingSizes: body += chunk("data", samples, size: 0xFFFF_FFFF)
        case .oversizedData: body += chunk("data", samples, size: UInt32(samples.count + 10_000))
        default: body += chunk("data", samples)
        }
        let riffSize: UInt32 = variant == .streamingSizes ? 0xFFFF_FFFF : UInt32(body.count)
        return Data(Array("RIFF".utf8) + u32(riffSize) + body)
    }

    /// Total harmonic distortion plus noise: the least-squares fundamental removed, the
    /// residual's energy relative to the whole, in dB.
    private static func thdn(_ samples: [Float], frequency: Double, sampleRate: Double) -> Double {
        var s = 0.0, c = 0.0, ss = 0.0, cc = 0.0, sc = 0.0
        for (i, v) in samples.enumerated() {
            let w = 2 * Double.pi * frequency * Double(i) / sampleRate
            let a = sin(w), b = cos(w)
            s += Double(v) * a; c += Double(v) * b; ss += a * a; cc += b * b; sc += a * b
        }
        let det = ss * cc - sc * sc
        let sinGain = (s * cc - c * sc) / det, cosGain = (c * ss - s * sc) / det
        var residual = 0.0, total = 0.0
        for (i, v) in samples.enumerated() {
            let w = 2 * Double.pi * frequency * Double(i) / sampleRate
            let r = Double(v) - sinGain * sin(w) - cosGain * cos(w)
            residual += r * r
            total += Double(v) * Double(v)
        }
        return 10 * log10(max(residual, 1e-30) / max(total, 1e-30))
    }

    private static func renderStereo(
        _ player: TTSChunkAudioPlayer,
        frames: Int
    ) async throws -> (left: [Float], right: [Float]) {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096))
        var left: [Float] = [], right: [Float] = []
        while left.count < frames {
            let status = try player.engine.renderOffline(AVAudioFrameCount(min(4096, frames - left.count)), to: buffer)
            #expect(status == .success)
            let count = Int(buffer.frameLength)
            left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)
            right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)
            try await Task.sleep(for: .milliseconds(1))
        }
        return (left, right)
    }

    private static func sourceFormat() throws -> AVAudioFormat {
        try AVAudioFile(forReading: chunkURL).processingFormat
    }

    private static func reference() throws -> [Float] {
        let file = try AVAudioFile(forReading: chunkURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return channel0(buffer)
    }

    private static func channel0(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Pulls `frames` from the engine, yielding between slices so the player's main-queue
    /// refills and completion run as they would on a device.
    private static func render(
        _ player: TTSChunkAudioPlayer,
        frames: Int
    ) async throws -> [Float] {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: player.engine.manualRenderingFormat, frameCapacity: 4096))
        var output: [Float] = []
        while output.count < frames {
            let status = try player.engine.renderOffline(AVAudioFrameCount(min(4096, frames - output.count)), to: buffer)
            #expect(status == .success)
            output += channel0(buffer)
            try await Task.sleep(for: .milliseconds(1))
        }
        return output
    }

    /// Signal-to-residual ratio of `rendered` against `reference`, at the best lag and gain.
    private static func snr(_ reference: [Float], _ rendered: [Float]) -> (db: Double, lag: Int) {
        var best = (db: -Double.infinity, lag: 0)
        for lag in 0..<2048 {
            let n = min(reference.count, rendered.count - lag)
            guard n > 0 else { break }
            let x = Array(reference[0..<n]), y = Array(rendered[lag..<(lag + n)])
            let yy = Double(vDSP.dot(y, y))
            guard yy > 0 else { continue }
            let gain = Double(vDSP.dot(x, y)) / yy
            let residual = vDSP.subtract(x, vDSP.multiply(Float(gain), y))
            let db = 10 * log10(Double(vDSP.dot(x, x)) / max(Double(vDSP.dot(residual, residual)), 1e-20))
            if db > best.db { best = (db, lag) }
            if db > 120 { break }
        }
        return best
    }

    /// Energy above `cutoff` Hz relative to all energy, in dB, over Hann-windowed frames.
    private static func energyAbove(_ cutoff: Double, in samples: [Float], sampleRate: Double) throws -> Double {
        let n = 4096
        let dft = try vDSP.DiscreteFourierTransform(
            previous: nil, count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self
        )
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: n)
        var high = 0.0, all = 0.0
        var start = 0
        while start + n <= samples.count {
            let frame = vDSP.multiply(Array(samples[start..<(start + n)]), window)
            let (re, im) = dft.transform(real: frame, imaginary: zeros)
            for k in 1..<(n / 2) {
                let real = Double(re[k]), imaginary = Double(im[k])
                let power = real * real + imaginary * imaginary
                all += power
                if Double(k) * sampleRate / Double(n) > cutoff { high += power }
            }
            start += n / 2
        }
        return 10 * log10(max(high, 1e-30) / max(all, 1e-30))
    }
}
