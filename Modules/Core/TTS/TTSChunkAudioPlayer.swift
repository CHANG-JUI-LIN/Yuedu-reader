import AVFoundation
import Foundation

/// Called on main: the player hops there before validating the finished schedule.
@MainActor
protocol TTSChunkAudioPlayerDelegate: AnyObject {
    func chunkAudioPlayerDidFinishPlaying(_ player: TTSChunkAudioPlayer, successfully flag: Bool)
}

/// A reusable audio graph for HTTP TTS chunks.
///
/// The player node and engine live for the whole TTS session. Only the decoded source is
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

    /// Internal so tests can render the graph offline (`init(manualRenderingFormat:)`).
    let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var decoder: TTSChunkDecoder?
    private var sampleRate: Double = 0
    private var totalFrames: AVAudioFramePosition = 0
    private var connectedSampleRate: Double = 0
    private var connectedChannelCount: AVAudioChannelCount = 0

    /// Source frame the current schedule started at. `currentTime` is this plus whatever
    /// the node has rendered since; a seek restarts the schedule and resets it.
    private var scheduleStartFrame: AVAudioFramePosition = 0
    /// Invalidates the completion handler of a schedule that a seek/load/stop superseded.
    private var scheduleToken = UUID()
    /// Decoded buffers handed to the node and not yet played back.
    private var queuedBuffers = 0
    /// The last buffer of the current schedule is queued.
    private var reachedEndOfSource = false
    /// The decoder failed partway; the chunk ends once what was queued has played.
    private var decodeFailed = false
    /// The next decoded buffer, read before it is scheduled (see `fillBufferQueue`).
    private var lookahead: AVAudioPCMBuffer?
    private var hasStarted = false
    /// Position captured at `pause`. `engine.pause()` can make `lastRenderTime` nil, so
    /// retaining this position prevents a resume from replaying the whole paragraph.
    private var pausedTime: TimeInterval?

    private(set) var isPlaying = false
    var hasLoadedAudio: Bool { decoder != nil && totalFrames > 0 }

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

    /// `manualRenderingFormat` puts the engine in offline manual rendering before the graph
    /// is built, so tests can pull exactly what a listener would hear. Production passes nil.
    init(manualRenderingFormat: AVAudioFormat? = nil) {
        if let manualRenderingFormat {
            do {
                try engine.enableManualRenderingMode(.offline, format: manualRenderingFormat, maximumFrameCount: 4096)
            } catch {
                ttsLog("[TTS][ChunkPlayer] manual rendering unavailable error=\(error.localizedDescription)")
            }
        }
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

    /// Replaces the source while retaining the audio graph. The chunk is decoded from memory;
    /// nothing is written to disk (see `TTSChunkDecoder`).
    func load(data: Data) throws {
        stop()
        clearCurrentSource()

        let newDecoder = try TTSChunkDecoder(data: data)
        decoder = newDecoder
        sampleRate = newDecoder.processingFormat.sampleRate
        totalFrames = newDecoder.length
        duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
        connectGraph(for: newDecoder.processingFormat, force: true)

        scheduleStartFrame = 0
        pausedTime = nil
        hasStarted = false
    }

    /// Releases the current source but keeps the reusable graph attached to the engine.
    func clear() {
        stop()
        clearCurrentSource()
    }

    @discardableResult
    func play() -> Bool {
        guard let decoder, totalFrames > 0, scheduleStartFrame < totalFrames else { return false }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            ttsLog("[TTS][ChunkPlayer] engine start failed error=\(error.localizedDescription)")
            return false
        }
        if !hasStarted {
            do {
                try scheduleFromCurrentStartFrame(decoder: decoder)
            } catch {
                ttsLog("[TTS][ChunkPlayer] decode failed at frame=\(scheduleStartFrame) error=\(error.localizedDescription)")
                return false
            }
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

    private func clearCurrentSource() {
        decoder = nil
        lookahead = nil
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

    /// Seconds of decoded audio per scheduled buffer, and how many buffers stay queued. The
    /// queue is refilled from the main queue, so it is what a busy main thread can fall behind
    /// by before the listener hears a gap.
    private static let bufferDuration: Double = 1
    private static let bufferQueueDepth = 3

    private func scheduleFromCurrentStartFrame(decoder: TTSChunkDecoder) throws {
        guard totalFrames - scheduleStartFrame > 0 else { return }
        try decoder.seek(toFrame: scheduleStartFrame)
        queuedBuffers = 0
        reachedEndOfSource = false
        decodeFailed = false
        lookahead = try decoder.read(frameCapacity: bufferFrameCapacity)
        try fillBufferQueue(decoder: decoder, token: scheduleToken)
    }

    private var bufferFrameCapacity: AVAudioFrameCount {
        AVAudioFrameCount(max(1, sampleRate * Self.bufferDuration))
    }

    /// Reads one buffer ahead, so the last buffer is known when it is scheduled: only it waits
    /// for `.dataPlayedBack` (the chunk is over when the listener has heard it); every other
    /// buffer refills the queue at `.dataConsumed`, as soon as the node has taken it.
    private func fillBufferQueue(decoder: TTSChunkDecoder, token: UUID) throws {
        while !reachedEndOfSource, queuedBuffers < Self.bufferQueueDepth, let buffer = lookahead {
            lookahead = try decoder.read(frameCapacity: bufferFrameCapacity)
            let isLast = lookahead == nil
            reachedEndOfSource = isLast
            queuedBuffers += 1
            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    // A seek, load, or stop replaced this schedule; it is not the chunk finishing.
                    guard token == self.scheduleToken else { return }
                    self.bufferCompleted(isLast: isLast, token: token)
                }
            }
        }
    }

    /// On main, where the delegate is called, as every completion is hopped there.
    @MainActor
    private func bufferCompleted(isLast: Bool, token: UUID) {
        // The token still matching means `decoder` is the one this schedule read from.
        guard let decoder else { return }
        queuedBuffers -= 1
        if !isLast, !decodeFailed {
            do {
                try fillBufferQueue(decoder: decoder, token: token)
            } catch {
                // The bytes decoded at load and up to here, so this is a corrupt stretch
                // mid-chunk. End the chunk where the audio ends rather than stall silent.
                ttsLog("[TTS][ChunkPlayer] decode failed mid-chunk error=\(error.localizedDescription)")
                decodeFailed = true
            }
        }
        let finished = isLast || (decodeFailed && queuedBuffers == 0)
        guard finished, isPlaying else { return }
        isPlaying = false
        delegate?.chunkAudioPlayerDidFinishPlaying(self, successfully: !decodeFailed)
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
    /// the captured source position; the decoder and current queue item remain intact.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying, let decoder = self.decoder else { return }
            let resumeAt = self.currentTime
            ttsLog("[TTS][ChunkPlayer] audio graph changed; resuming at \(resumeAt)")
            self.connectGraph(for: decoder.processingFormat, force: true)
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
}
