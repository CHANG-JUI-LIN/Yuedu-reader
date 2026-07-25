import AVFoundation
import Foundation

protocol TTSChunkAudioPlayerDelegate: AnyObject {
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool)
}

/// Plays one in-memory TTS audio chunk with pitch-preserving rate control.
///
/// Replaces `AVAudioPlayer` in `HTTPTTSEngine`. `AVAudioPlayer.rate` is documented to
/// span only 0.5–2.0, so every speech rate above 200% saturated silently — the exact
/// complaint that prompted raising the slider to 500%. `AVAudioUnitTimePitch` covers
/// 1/32–32× and preserves pitch, so 5× stays intelligible instead of turning into
/// chipmunk audio.
///
/// The surface mirrors the `AVAudioPlayer` API the engine already used (`play`,
/// `pause`, `stop`, `currentTime`, `duration`, `rate`, `isPlaying`, `delegate`), so the
/// engine's chunk queue, preloading and resume-with-seek logic are unchanged.
///
/// One `AVAudioEngine` per chunk: a chunk is a whole paragraph (~300 characters, on the
/// order of 10–20 seconds), so graph setup happens rarely enough not to matter, and a
/// per-chunk graph keeps the lifetime identical to the `AVAudioPlayer` it replaces.
/// `@unchecked Sendable` for the same reason as `HTTPTTSEngine`, which owns it: the
/// AVFoundation types here are not `Sendable`, and every mutation is funnelled to the
/// main queue by the engine and by this class's own completion handlers.
final class TTSChunkAudioPlayer: @unchecked Sendable {
    weak var delegate: TTSChunkAudioPlayerDelegate?

    /// Source duration in seconds — unaffected by `rate`, matching `AVAudioPlayer.duration`.
    let duration: TimeInterval

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let file: AVAudioFile
    private let fileURL: URL
    private let sampleRate: Double
    private let totalFrames: AVAudioFramePosition

    /// Source frame the current schedule started at. `currentTime` is this plus whatever
    /// the node has rendered since; a seek restarts the schedule and resets it.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    /// Invalidates the completion handler of a schedule that a seek/stop superseded, so a
    /// superseded chunk can't report "finished" and advance the queue.
    private var scheduleToken = UUID()
    private var hasStarted = false
    /// Position captured at `pause`. `engine.pause()` halts the render loop, after which
    /// `playerNode.lastRenderTime` can go nil — without this, `currentTime` would fall back
    /// to the segment start and the engine's resume-mid-sentence seek would replay the
    /// whole paragraph.
    private var pausedTime: TimeInterval?

    private(set) var isPlaying = false

    /// Wall-clock length at the current rate — what the Now Playing elapsed clock needs.
    /// (`AVAudioPlayer.duration` never accounted for `rate`, so this is also a fix for the
    /// lock-screen scrubber drifting whenever client-side speed was not 1.0×.)
    var effectiveDuration: TimeInterval {
        duration / Double(max(rate, 0.01))
    }

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = Self.clampRate(newValue) }
    }

    /// Source-domain playback position. Reading mirrors `AVAudioPlayer.currentTime`;
    /// writing seeks, which reschedules from the new frame.
    var currentTime: TimeInterval {
        get {
            if let pausedTime { return pausedTime }
            guard hasStarted,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
            else {
                return frameToSeconds(scheduleStartFrame)
            }
            // `playerTime.sampleTime` counts frames pulled from the *source*, so it stays
            // in the source domain no matter what the time-pitch unit is doing downstream.
            return min(max(frameToSeconds(scheduleStartFrame + playerTime.sampleTime), 0), duration)
        }
        set {
            seek(to: newValue)
        }
    }

    init(data: Data) throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yd-tts-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: data))
        try data.write(to: fileURL, options: .atomic)
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        sampleRate = file.processingFormat.sampleRate
        totalFrames = file.length
        duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        playerNode.stop()
        engine.stop()
        try? FileManager.default.removeItem(at: fileURL)
    }

    @discardableResult
    func play() -> Bool {
        guard totalFrames > 0 else { return false }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            ttsLog("[TTS][ChunkPlayer] engine start failed error=\(error.localizedDescription)")
            return false
        }
        if !hasStarted {
            scheduleFromCurrentStartFrame()
        }
        playerNode.play()
        pausedTime = nil
        hasStarted = true
        isPlaying = true
        return true
    }

    func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime          // capture before the render loop stops
        playerNode.pause()
        engine.pause()
        isPlaying = false
    }

    func stop() {
        scheduleToken = UUID()
        playerNode.stop()
        engine.stop()
        pausedTime = nil
        hasStarted = false
        isPlaying = false
    }

    // MARK: - Private

    private func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        scheduleToken = UUID()
        playerNode.stop()
        pausedTime = nil
        hasStarted = false
        isPlaying = false
        scheduleStartFrame = secondsToFrame(min(max(time, 0), duration))
        if wasPlaying {
            _ = play()
        }
    }

    private func scheduleFromCurrentStartFrame() {
        let remaining = totalFrames - scheduleStartFrame
        guard remaining > 0 else { return }
        let token = scheduleToken
        playerNode.scheduleSegment(
            file,
            startingFrame: scheduleStartFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // A seek or stop replaced this schedule; its completion is not the
                // chunk finishing and must not advance the queue.
                guard token == self.scheduleToken, self.isPlaying else { return }
                self.isPlaying = false
                self.delegate?.chunkAudioPlayerDidFinishPlaying(self, successfully: true)
            }
        }
    }

    /// A route change (headphones unplugged, AirPods connected) stops the engine and
    /// invalidates the graph. Rebuild and resume from where playback was, otherwise
    /// listening simply dies mid-sentence.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying else { return }
            let resumeAt = self.currentTime
            ttsLog("[TTS][ChunkPlayer] audio route changed; resuming at \(resumeAt)")
            self.seek(to: resumeAt)
        }
    }

    private func frameToSeconds(_ frame: AVAudioFramePosition) -> TimeInterval {
        sampleRate > 0 ? Double(frame) / sampleRate : 0
    }

    private func secondsToFrame(_ seconds: TimeInterval) -> AVAudioFramePosition {
        sampleRate > 0 ? AVAudioFramePosition(seconds * sampleRate) : 0
    }

    /// `AVAudioUnitTimePitch` documents a 1/32–32 rate range; anything outside is rejected.
    private static func clampRate(_ rate: Float) -> Float {
        min(max(rate, 1.0 / 32.0), 32.0)
    }

    /// `AVAudioFile` opens by URL, so the chunk has to hit disk first. ExtAudioFile sniffs
    /// content, but a matching extension keeps it on the fast path.
    private static func fileExtension(for data: Data) -> String {
        let header = [UInt8](data.prefix(12))
        guard header.count >= 12 else { return "mp3" }
        if header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46 {
            return "wav"           // "RIFF"
        }
        if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 {
            return "m4a"           // "ftyp"
        }
        if header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 {
            return "flac"          // "fLaC"
        }
        if header[0] == 0x4F, header[1] == 0x67, header[2] == 0x67, header[3] == 0x53 {
            return "ogg"           // "OggS" — unsupported by AVAudioFile, same as AVAudioPlayer
        }
        return "mp3"               // ID3 / raw MPEG frames
    }
}
