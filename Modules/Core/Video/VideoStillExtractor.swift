import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One frame of an episode, encoded, and how long the episode runs: what 選集 shows on an
/// episode's card in place of its number.
struct VideoStillFrame: Sendable, Equatable {
    /// JPEG bytes, the running time written into them (`VideoStillCoding`).
    let jpeg: Data
    let duration: TimeInterval?
}

enum VideoStillError: LocalizedError, Equatable {
    /// The player readied the stream but handed over no frame where it was asked for one: an
    /// audio-only episode, or a stream it cannot decode.
    case noFrame
    /// The stream never became ready within `VideoStillExtractor.timeout`.
    case timedOut
    case notEncodable

    var errorDescription: String? {
        switch self {
        case .noFrame: "no frame at the requested time"
        case .timedOut: "the stream did not become ready in time"
        case .notEncodable: "the frame could not be encoded"
        }
    }
}

/// Takes an episode's still as its player would show it: a muted player that never plays,
/// seeked a fifth of the way in, its video output read the moment the seek completes.
///
/// One path for every stream. `AVAssetImageGenerator` reads files but never returns for an HLS
/// playlist (measured 2026-11-01: no error, no image, the request outstanding after 90 s), and
/// sources' episodes are mostly HLS; the player reads both. The stream's headers ride on the
/// asset (`HeaderedMediaAsset`), so a Referer-guarded CDN serves the playlist and its segments.
enum VideoStillExtractor {
    /// How far into an episode its still is taken: past a cold open's black frames and the
    /// title card, as a media centre's episode stills are.
    static let position = 0.2
    /// Seeks land on any frame this close to `position`, so a stream gives the keyframe it
    /// already has instead of decoding forward to an exact time.
    static let seekTolerance = CMTime(seconds: 3, preferredTimescale: 600)
    /// Bounds a stream that never becomes ready — a CDN that accepts the connection and sends
    /// nothing — or a seek that never returns (seen 2026-11-01 on an HLS item without a video
    /// output), which would otherwise hold one of the stills' few slots for as long as its
    /// card stays on screen. A stream that answers at all is ready in well under a second.
    static let timeout: Duration = .seconds(20)

    static func still(of stream: VideoStream, fitting pixelSize: CGSize) async throws -> VideoStillFrame {
        try await withThrowingTaskGroup(of: VideoStillFrame.self) { group in
            group.addTask { try await take(stream, fitting: pixelSize) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw VideoStillError.timedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw CancellationError() }
            return frame
        }
    }

    private static func take(_ stream: VideoStream, fitting pixelSize: CGSize) async throws -> VideoStillFrame {
        let asset = HeaderedMediaAsset.make(url: stream.url, headers: stream.headers)
        let item = AVPlayerItem(asset: asset)
        // Only the frame's own segment, not the episode's first minutes as well.
        item.preferredForwardBufferDuration = 1
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        defer {
            player.replaceCurrentItem(with: nil)
            asset.cancelLoading()
        }

        try await ItemReadiness().wait(for: item)
        let duration = item.duration.isNumeric && item.duration.seconds > 0 ? item.duration.seconds : nil
        // A file's video track says how it is turned. An HLS asset lists no tracks (the player
        // item's are its), and its segments are encoded upright.
        var transform = CGAffineTransform.identity
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            do {
                transform = try await track.load(.preferredTransform)
            } catch {
                // The frame is still the episode's; it is only possibly on its side.
                AppLogger.network("[Video] still's track rotation unreadable; taking the frame as stored", error: error)
            }
        }

        let target = CMTime(seconds: (duration ?? 0) * position, preferredTimescale: 600)
        _ = await item.seek(to: target, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
        try Task.checkCancellation()
        let shown = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: shown),
              let buffer = output.copyPixelBuffer(forItemTime: shown, itemTimeForDisplay: nil) else {
            throw VideoStillError.noFrame
        }
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation(of: transform))
        guard let jpeg = VideoStillCoding.jpeg(of: image, fitting: pixelSize, duration: duration) else {
            throw VideoStillError.notEncodable
        }
        return VideoStillFrame(jpeg: jpeg, duration: duration)
    }

    /// A track's rotation as the orientation that stands its frames upright: a phone's
    /// portrait recording is stored on its side with a quarter-turn transform.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// Waits for a player item's status to turn ready, or its failure, through KVO itself.
/// `publisher(for: \.status).values` never delivered the ready status on iOS (measured
/// 2026-11-01: still `.unknown` after 20 s, a local file included, where reading the status
/// directly saw it ready). The async sequence asks the KVO publisher for one value at a
/// time, and a KVO publisher does not keep a change that arrives while nothing is asked.
private final class ItemReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var observation: NSKeyValueObservation?
    private var result: Result<Void, Error>?

    func wait(for item: AVPlayerItem) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                let observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    switch item.status {
                    case .readyToPlay: self?.finish(.success(()))
                    case .failed: self?.finish(.failure(item.error ?? VideoStillError.noFrame))
                    case .unknown: break
                    @unknown default: break
                    }
                }
                let settled = lock.withLock {
                    self.observation = observation
                    return result != nil
                }
                // Already ready (the initial value) or cancelled before the observation began.
                if settled { finish(nil) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Settles the wait once: the first result resumes it, later ones are ignored. Nil only
    /// releases what a settled wait still holds.
    private func finish(_ outcome: Result<Void, Error>?) {
        let (continuation, observation, settled) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, NSKeyValueObservation?, Result<Void, Error>?) in
            if result == nil, let outcome { result = outcome }
            guard let result else { return (nil, nil, nil) }
            defer {
                self.continuation = nil
                self.observation = nil
            }
            return (self.continuation, self.observation, result)
        }
        observation?.invalidate()
        if let settled { continuation?.resume(with: settled) }
    }
}

/// A still's bytes: a JPEG with the episode's running time in its IPTC caption, so the one
/// file the cover cache keeps for it brings back both (`VideoEpisodeStills`). IPTC, not the
/// TIFF image description: iOS's JPEG writer moves the description into the IPTC caption
/// (measured 2026-11-01), so it is never there to be read back.
enum VideoStillCoding {
    private static let durationPrefix = "yuedu.duration="
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The image scaled down until it just covers `pixelSize` (it is shown filling the card),
    /// never up.
    static func jpeg(of image: CIImage, fitting pixelSize: CGSize, duration: TimeInterval?) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, max(pixelSize.width / extent.width, pixelSize.height / extent.height))
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .samplingLinear()
        let bounds = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        guard let cgImage = context.createCGImage(scaled, from: bounds) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let duration {
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCCaptionAbstract: durationPrefix + String(duration),
            ]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The running time a still's bytes carry, if they carry one.
    static func duration(in jpeg: Data) -> TimeInterval? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
              let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String,
              caption.hasPrefix(durationPrefix) else { return nil }
        return TimeInterval(caption.dropFirst(durationPrefix.count))
    }
}
