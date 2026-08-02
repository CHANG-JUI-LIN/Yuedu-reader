import AVFoundation
import Foundation

protocol TTSChunkAudioPlayerDelegate: AnyObject {
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool)
}

/// A reusable audio graph for HTTP TTS chunks.
///
/// The player node and engine live for the whole TTS session. Only the source file is
/// replaced between chunks. Rebuilding an `AVAudioEngine` for every paragraph creates an
/// audio-session boundary precisely when an app is locked or backgrounded; iOS can suspend
/// that boundary before the next graph has started. Keeping one graph also makes route and
/// media-service recovery deterministic.
///
/// `AVAudioPlayer.rate` is documented to span only 0.5–2.0, so every speech rate above 200%
/// saturated silently. `AVAudioUnitTimePitch` covers the requested 5× range while preserving
/// pitch.
final class TTSChunkAudioPlayer: @unchecked Sendable {
    weak var delegate: TTSChunkAudioPlayerDelegate?

    /// Source duration in seconds — unaffected by `rate`, matching `AVAudioPlayer.duration`.
    private(set) var duration: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var sampleRate: Double = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var connectedSampleRate: Double = 0
    private var connectedChannelCount: AVAudioChannelCount = 0

    /// Source frame the current schedule started at. `currentTime` is this plus whatever
    /// the node has rendered since; a seek restarts the schedule and resets it.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    /// Invalidates the completion handler of a schedule that a seek/load/stop superseded.
    private var scheduleToken = UUID()
    private var hasStarted = false
    /// Position captured at `pause`. `engine.pause()` can make `lastRenderTime` nil, so
    /// retaining this position prevents a resume from replaying the whole paragraph.
    private var pausedTime: TimeInterval?

    private(set) var isPlaying = false
    var hasLoadedAudio: Bool { file != nil && totalFrames > 0 }

    /// Wall-clock length at the current rate — what the Now Playing elapsed clock needs.
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
            // `playerTime.sampleTime` counts source frames, so it stays in the source domain
            // no matter what the time-pitch unit is doing downstream.
            return min(max(frameToSeconds(scheduleStartFrame + playerTime.sampleTime), 0), duration)
        }
        set { seek(to: newValue) }
    }

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        clear()
    }

    /// Replaces the source while retaining the audio graph. The data is staged in a temporary
    /// file because `AVAudioFile` decodes compressed containers from a URL.
    func load(data: Data) throws {
        stop()
        clearCurrentFile()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yd-tts-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: data))
        try data.write(to: url, options: .atomic)

        do {
            let newFile = try AVAudioFile(forReading: url)
            fileURL = url
            file = newFile
            sampleRate = newFile.processingFormat.sampleRate
            totalFrames = newFile.length
            duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
            connectGraph(for: newFile.processingFormat, force: true)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        scheduleStartFrame = 0
        pausedTime = nil
        hasStarted = false
    }

    /// Releases the current source but keeps the reusable graph attached to the engine.
    func clear() {
        stop()
        clearCurrentFile()
    }

    @discardableResult
    func play() -> Bool {
        guard let file, totalFrames > 0, scheduleStartFrame < totalFrames else { return false }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            ttsLog("[TTS][ChunkPlayer] engine start failed error=\(error.localizedDescription)")
            return false
        }
        if !hasStarted {
            scheduleFromCurrentStartFrame(file: file)
        }
        playerNode.play()
        pausedTime = nil
        hasStarted = true
        isPlaying = true
        return true
    }

    func pause() {
        guard isPlaying else { return }
        pausedTime = currentTime
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
        scheduleStartFrame = 0
    }

    // MARK: - Private

    private func clearCurrentFile() {
        file = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        sampleRate = 0
        totalFrames = 0
        duration = 0
        scheduleStartFrame = 0
        pausedTime = nil
        hasStarted = false
    }

    private func seek(to time: TimeInterval) {
        guard hasLoadedAudio else { return }
        let wasPlaying = isPlaying
        scheduleToken = UUID()
        playerNode.stop()
        engine.stop()
        pausedTime = nil
        hasStarted = false
        isPlaying = false
        scheduleStartFrame = secondsToFrame(min(max(time, 0), duration))
        if wasPlaying {
            _ = play()
        }
    }

    private func scheduleFromCurrentStartFrame(file: AVAudioFile) {
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
                // A seek, load, or stop replaced this schedule; it is not the chunk finishing.
                guard token == self.scheduleToken, self.isPlaying else { return }
                self.isPlaying = false
                self.delegate?.chunkAudioPlayerDidFinishPlaying(self, successfully: true)
            }
        }
    }

    private func connectGraph(for format: AVAudioFormat, force: Bool = false) {
        let channelCount = format.channelCount
        guard force || connectedSampleRate != format.sampleRate || connectedChannelCount != channelCount else {
            return
        }

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        connectedSampleRate = format.sampleRate
        connectedChannelCount = channelCount
    }

    /// A route change can invalidate the running graph. Reconnect it before restarting from
    /// the captured source position; the source file and current queue item remain intact.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying, let file = self.file else { return }
            let resumeAt = self.currentTime
            ttsLog("[TTS][ChunkPlayer] audio graph changed; resuming at \(resumeAt)")
            self.connectGraph(for: file.processingFormat, force: true)
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
            return "wav"
        }
        if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 {
            return "m4a"
        }
        if header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 {
            return "flac"
        }
        if header[0] == 0x4F, header[1] == 0x67, header[2] == 0x67, header[3] == 0x53 {
            return "ogg"
        }
        return "mp3"
    }
}
