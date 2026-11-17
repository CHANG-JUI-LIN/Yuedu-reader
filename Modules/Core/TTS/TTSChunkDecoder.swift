import AudioToolbox
import AVFoundation
import Foundation

/// Decodes a TTS chunk straight from the bytes the provider returned, a buffer at a time.
///
/// `AVAudioFile` only opens URLs, so `TTSChunkAudioPlayer` used to write every chunk to tmp
/// first. Over a day of listening that was 310 MB of the 1.07 GB MetricKit disk-write
/// exception build 143 reported on an iPhone17,1 (Crashlytics 9a66b633, Organizer
/// 9e5b6ef3), every byte of it a copy of data already in memory. `AudioFileOpenWithCallbacks`
/// reads the same containers from memory, and `ExtAudioFile` gives the same Float32
/// deinterleaved output `AVAudioFile.processingFormat` did.
///
/// Decoding a buffer at a time, not the whole chunk up front, matters for direct chapter
/// audio: one chunk there is a whole chapter, and an hour at 44.1 kHz stereo is over a
/// gigabyte of PCM.
final class TTSChunkDecoder {
    /// Float32, deinterleaved, at the source's sample rate and channel count.
    let processingFormat: AVAudioFormat
    /// Length in frames: as `ExtAudioFile` reports it (`AVAudioFile.length` reads the same
    /// property), or the trimmed window's when `trimsSilence` cut the clip. The end of
    /// playback is found by reading, not by this number.
    private(set) var length: AVAudioFramePosition

    private let source: Source
    private let audioFile: AudioFileID
    private let extAudioFile: ExtAudioFileRef
    /// The window of the source this decoder plays, in source frames. Frame 0 of `seek` and
    /// `read` is `windowStart`; reading stops at `windowEnd` (nil: the source's own end).
    private var windowStart: AVAudioFramePosition = 0
    private var windowEnd: AVAudioFramePosition?
    /// Source frame the next `read` starts at.
    private var position: AVAudioFramePosition = 0

    /// Silence a synthesized clip may keep at each end. Speech services pad every clip — 微軟
    /// 線上語音 measured 170 ms before and 600 ms after each paragraph (FB-23, 2026-11-17),
    /// ~770 ms of dead air at every paragraph boundary once clips play back to back. The
    /// maintainer chose a ~300 ms boundary: about what the system voice leaves (5 + 200 ms).
    static let keptLeadingSilence: TimeInterval = 0.1
    static let keptTrailingSilence: TimeInterval = 0.2
    /// -40 dBFS. Edge's padding reads at the MP3 noise floor, far below this; speech onsets
    /// rise through it within a few milliseconds.
    static let silenceThreshold: Float = 0.01
    /// How far back from the end the trailing scan looks; longer trailing silence than this
    /// is left as it is rather than decoding the whole clip twice.
    private static let trailingScanWindow: TimeInterval = 2

    /// `trimsSilence` cuts the clip's leading and trailing silence down to
    /// `keptLeadingSilence` / `keptTrailingSilence`. Synthesized speech only: direct chapter
    /// audio is a recording, possibly an hour long, and is played exactly as served.
    convenience init(data: Data, trimsSilence: Bool) throws {
        try self.init(data: data)
        if trimsSilence {
            try SourcePerfTrace.span("tts.trimSilence", thresholdMs: 5) { try trimSilence() }
        }
    }

    init(data: Data) throws {
        let source = Source(data: data)
        var fileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(source).toOpaque(),
            { clientData, position, requestCount, buffer, actualCount in
                Unmanaged<Source>.fromOpaque(clientData).takeUnretainedValue()
                    .read(at: position, count: requestCount, into: buffer, actualCount: actualCount)
            },
            nil,
            { clientData in
                Int64(Unmanaged<Source>.fromOpaque(clientData).takeUnretainedValue().data.count)
            },
            nil,
            Self.fileTypeHint(for: data),
            &fileID
        )
        guard status == noErr, let fileID else { throw Self.error(status, "AudioFileOpenWithCallbacks") }

        var extFile: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &extFile)
        guard status == noErr, let extFile else {
            AudioFileClose(fileID)
            throw Self.error(status, "ExtAudioFileWrapAudioFileID")
        }

        do {
            var fileFormat = AudioStreamBasicDescription()
            try Self.check(Self.getProperty(extFile, kExtAudioFileProperty_FileDataFormat, &fileFormat), "FileDataFormat")
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: fileFormat.mSampleRate,
                channels: fileFormat.mChannelsPerFrame
            ) else {
                throw Self.error(kAudioFileUnsupportedDataFormatError, "channels=\(fileFormat.mChannelsPerFrame)")
            }
            var clientFormat = format.streamDescription.pointee
            try Self.check(ExtAudioFileSetProperty(
                extFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            ), "ClientDataFormat")
            var frames: Int64 = 0
            try Self.check(Self.getProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &frames), "FileLengthFrames")

            processingFormat = format
            length = frames
        } catch {
            ExtAudioFileDispose(extFile)
            AudioFileClose(fileID)
            throw error
        }
        self.source = source
        self.audioFile = fileID
        self.extAudioFile = extFile
    }

    deinit {
        ExtAudioFileDispose(extAudioFile)
        AudioFileClose(audioFile)
    }

    func seek(toFrame frame: AVAudioFramePosition) throws {
        let target = windowStart + max(0, frame)
        try Self.check(ExtAudioFileSeek(extAudioFile, target), "ExtAudioFileSeek")
        position = target
    }

    /// The next buffer of up to `frameCapacity` frames, or nil at the end of the window.
    func read(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        var capacity = frameCapacity
        if let windowEnd {
            let remaining = windowEnd - position
            guard remaining > 0 else { return nil }
            capacity = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
            throw Self.error(kAudio_MemFullError, "AVAudioPCMBuffer")
        }
        // Sizes every channel's `mDataByteSize` to the capacity for `ExtAudioFileRead`.
        buffer.frameLength = capacity
        var frames = UInt32(capacity)
        try Self.check(ExtAudioFileRead(extAudioFile, &frames, buffer.mutableAudioBufferList), "ExtAudioFileRead")
        guard frames > 0 else { return nil }
        buffer.frameLength = frames
        position += AVAudioFramePosition(frames)
        return buffer
    }

    // MARK: - Silence trimming

    /// Finds the first and last audible frame and narrows the window to them plus the kept
    /// silence. Reads from the start only until speech begins, and the end only within
    /// `trailingScanWindow`, so a clip is never decoded twice in full. A clip with no audible
    /// frame in either scan is left whole: there is nothing to tell speech from padding by.
    private func trimSilence() throws {
        let rate = processingFormat.sampleRate
        guard rate > 0 else { return }
        let chunk: AVAudioFrameCount = 4_096

        // Leading: the first frame above the threshold.
        try seek(toFrame: 0)
        var firstAudible: AVAudioFramePosition?
        var scanned: AVAudioFramePosition = 0
        while firstAudible == nil, let buffer = try read(frameCapacity: chunk) {
            if let offset = Self.firstAudibleFrame(in: buffer) {
                firstAudible = scanned + AVAudioFramePosition(offset)
            }
            scanned += AVAudioFramePosition(buffer.frameLength)
        }
        guard let firstAudible else {
            try seek(toFrame: 0)
            return
        }

        // Trailing: the last frame above the threshold within the final window, and the
        // source's real end (an MP3's reported length can be off by its priming frames).
        let tailStart = max(firstAudible, length - AVAudioFramePosition(Self.trailingScanWindow * rate))
        try seek(toFrame: tailStart)
        var lastAudible: AVAudioFramePosition?
        var cursor = tailStart
        while let buffer = try read(frameCapacity: chunk) {
            if let offset = Self.lastAudibleFrame(in: buffer) {
                lastAudible = cursor + AVAudioFramePosition(offset)
            }
            cursor += AVAudioFramePosition(buffer.frameLength)
        }
        let sourceEnd = cursor

        let start = max(0, firstAudible - AVAudioFramePosition(Self.keptLeadingSilence * rate))
        let end = lastAudible.map { min(sourceEnd, $0 + 1 + AVAudioFramePosition(Self.keptTrailingSilence * rate)) }
            ?? sourceEnd
        windowStart = start
        windowEnd = end
        length = end - start
        try seek(toFrame: 0)
    }

    private static func firstAudibleFrame(in buffer: AVAudioPCMBuffer) -> Int? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        for frame in 0..<frames {
            for channel in 0..<Int(buffer.format.channelCount) where abs(channels[channel][frame]) > silenceThreshold {
                return frame
            }
        }
        return nil
    }

    private static func lastAudibleFrame(in buffer: AVAudioPCMBuffer) -> Int? {
        guard let channels = buffer.floatChannelData else { return nil }
        for frame in stride(from: Int(buffer.frameLength) - 1, through: 0, by: -1) {
            for channel in 0..<Int(buffer.format.channelCount) where abs(channels[channel][frame]) > silenceThreshold {
                return frame
            }
        }
        return nil
    }

    // MARK: - Private

    /// Owns the bytes for as long as `AudioFile` may call back into them.
    private final class Source {
        let data: Data

        init(data: Data) {
            self.data = data
        }

        func read(
            at position: Int64,
            count: UInt32,
            into buffer: UnsafeMutableRawPointer,
            actualCount: UnsafeMutablePointer<UInt32>
        ) -> OSStatus {
            guard position >= 0, position <= Int64(data.count) else {
                actualCount.pointee = 0
                return kAudioFilePositionError
            }
            let start = Int(position)
            let available = min(Int(count), data.count - start)
            data.withUnsafeBytes { bytes in
                buffer.copyMemory(from: bytes.baseAddress!.advanced(by: start), byteCount: available)
            }
            actualCount.pointee = UInt32(available)
            return noErr
        }
    }

    /// The same magic numbers `TTSAudioPayload.looksLikeAudioContainer` accepts. A hint, not
    /// a verdict: `AudioFile` still parses the bytes, and 0 lets it identify Ogg itself.
    private static func fileTypeHint(for data: Data) -> AudioFileTypeID {
        let header = [UInt8](data.prefix(12))
        guard header.count >= 12 else { return kAudioFileMP3Type }
        if header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46 {
            return kAudioFileWAVEType
        }
        if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 {
            return kAudioFileM4AType
        }
        if header[0] == 0x66, header[1] == 0x4C, header[2] == 0x61, header[3] == 0x43 {
            return kAudioFileFLACType
        }
        if header[0] == 0x4F, header[1] == 0x67, header[2] == 0x67, header[3] == 0x53 {
            return 0
        }
        return kAudioFileMP3Type
    }

    private static func getProperty<T>(_ file: ExtAudioFileRef, _ id: ExtAudioFilePropertyID, _ value: inout T) -> OSStatus {
        var size = UInt32(MemoryLayout<T>.size)
        return ExtAudioFileGetProperty(file, id, &size, &value)
    }

    private static func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw error(status, stage) }
    }

    /// An `NSOSStatusErrorDomain` error, as `AVAudioFile` threw, so the engine's failure log
    /// keeps reading the same codes ('dta?' 1685348671 for a non-audio body).
    private static func error(_ status: OSStatus, _ stage: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "TTS chunk decode failed at \(stage) (OSStatus \(status))"
        ])
    }
}
