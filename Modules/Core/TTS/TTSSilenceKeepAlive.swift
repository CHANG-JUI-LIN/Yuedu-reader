import AVFoundation
import Foundation

/// Looped-silence player that keeps the audio session emitting samples during gaps where a
/// TTS engine is logically "playing" but has no real audio to output — an HTTP chunk still
/// downloading, or a chapter boundary waiting on the next chapter's content.
///
/// Without it there is no active audio output, and iOS suspends the app while backgrounded
/// or locked: playback stalls mid-book with the mini-player still showing "playing" until the
/// device is unlocked. Extracted from `HTTPTTSEngine`, where it was proven against that bug,
/// so `SystemTTSEngine` — which has no audio player of its own between utterances — can share
/// the one implementation instead of growing a second copy.
final class TTSSilenceKeepAlive {

    private var player: AVAudioPlayer?

    /// PCM silence (1 second, mono 16-bit 44.1kHz) in a minimal WAV container, built once and
    /// looped for as long as the engine has no real audio to emit.
    private static let silenceWAV: Data = {
        let sampleRate: UInt32 = 44_100
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        let frames: UInt32 = sampleRate // 1 second
        let dataSize: UInt32 = frames * UInt32(blockAlign)

        var d = Data()
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func tag(_ s: String) {
            s.utf8.forEach { d.append($0) }
        }
        tag("RIFF"); u32(36 + dataSize); tag("WAVE")
        tag("fmt "); u32(16); u16(1) // PCM
        u16(numChannels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        tag("data"); u32(dataSize)
        d.append(Data(repeating: 0, count: Int(dataSize)))
        return d
    }()

    private func ensurePlayer() {
        if player != nil { return }
        guard let p = try? AVAudioPlayer(data: Self.silenceWAV) else {
            ttsLog("[TTS][SilenceKeepAlive] init failed — audio-session keep-alive disabled")
            return
        }
        p.numberOfLoops = -1
        p.volume = 0.0
        p.prepareToPlay()
        player = p
    }

    /// Start emitting looped silence. Idempotent.
    func start() {
        ensurePlayer()
        if player?.isPlaying == false {
            _ = player?.play()
        }
    }

    /// Stop the silence. Called when real audio begins, and on pause / stop / reset.
    func stop() {
        player?.pause()
    }
}
