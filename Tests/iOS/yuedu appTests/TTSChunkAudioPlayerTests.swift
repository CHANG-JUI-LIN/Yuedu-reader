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
