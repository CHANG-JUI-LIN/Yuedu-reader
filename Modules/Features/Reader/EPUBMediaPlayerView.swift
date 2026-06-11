import AVKit
import SwiftUI
import UIKit

struct EPUBMediaPlayerView: View {
    let media: EPUBMediaAttachment

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if media.kind == .video {
                videoBody
            } else {
                audioBody
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private var videoBody: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                mediaStatus
            }
            closeButton
                .padding(16)
        }
    }

    private var audioBody: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)
                Text(displayTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(media.sourceHref)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? localized("暫停") : localized("播放"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(player == nil)
            }
            .padding(24)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
    }

    private var mediaStatus: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .tint(.white)
                Text(localized("載入中..."))
                    .foregroundStyle(.white)
            }
        }
        .padding()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
    }

    private var displayTitle: String {
        let title = media.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return media.kind == .video ? "EPUB Video" : "EPUB Audio"
    }

    private func load() async {
        guard player == nil else { return }

        let playableURL: URL
        do {
            playableURL = try await EPUBMediaURLResolver.playableURL(for: media)
        } catch EPUBMediaURLError.invalidURL {
            errorMessage = localized("無效的媒體網址")
            return
        } catch {
            errorMessage = localized("無法載入媒體")
            return
        }

        let item = AVPlayerItem(url: playableURL)
        observeFailure(of: item)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        if media.kind == .video {
            nextPlayer.play()
            isPlaying = true
        }
    }

    /// Surfaces an AVPlayerItem that fails to load/play (codec unsupported, corrupt extraction, …)
    /// instead of leaving a silent black screen. Polls status briefly because AVPlayerItem has no
    /// async status stream, and asset-load failures surface a short while after play() is called.
    @MainActor
    private func observeFailure(of item: AVPlayerItem) {
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                switch item.status {
                case .failed:
                    errorMessage = localized("無法播放此影片")
                    return
                case .readyToPlay:
                    return
                default:
                    continue
                }
            }
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}

enum EPUBMediaURLError: Error {
    case invalidURL
}

/// Owns the live `AVPlayer` instances for inline EPUB videos. Playback lives here — not on the recycled
/// reader page views — so it survives page turns: when the page scrolls away its embedded player view is
/// torn down, but the `AVPlayer` keeps running here and audio continues in the background (the same model
/// as TTS). When the reader returns to the video's page, the freshly-created page view re-binds this same
/// live player, so the picture resumes already in sync with the audio. Players are keyed by source href, so
/// a given video has exactly one player regardless of how many times its page is rebuilt.
@MainActor
final class EPUBVideoPlaybackManager {
    static let shared = EPUBVideoPlaybackManager()

    private var players: [String: AVPlayer] = [:]
    private var audioSessionActivated = false

    private init() {}

    /// True once a player exists for this media (i.e. the user has started it). The page view uses this to
    /// decide whether to re-embed a live player on (re)appearance vs. just show the poster placeholder.
    func isActive(_ media: EPUBMediaAttachment) -> Bool {
        players[media.sourceHref] != nil
    }

    func existingPlayer(for media: EPUBMediaAttachment) -> AVPlayer? {
        players[media.sourceHref]
    }

    /// Returns the persistent player for this media, creating it (and resolving/extracting the playable URL)
    /// on first use. Activates a `.playback` audio session so sound keeps going across page turns.
    func player(for media: EPUBMediaAttachment) async -> AVPlayer? {
        if let existing = players[media.sourceHref] { return existing }
        guard let url = try? await EPUBMediaURLResolver.playableURL(for: media) else { return nil }
        activateAudioSessionIfNeeded()
        let player = AVPlayer(url: url)
        players[media.sourceHref] = player
        return player
    }

    func stop(_ media: EPUBMediaAttachment) {
        players[media.sourceHref]?.pause()
        players[media.sourceHref] = nil
    }

    /// Stops and releases every inline video. Call when the reader closes so nothing keeps playing after
    /// the user leaves the book.
    func stopAll() {
        for player in players.values { player.pause() }
        players.removeAll()
    }

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActivated else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        audioSessionActivated = true
    }
}

/// Resolves an EPUB media attachment's href to a URL `AVPlayer` can open. `http(s)` and `file` URLs are
/// used directly; resources served over the reader's custom `reader-book://<bookId>/<path>` scheme are
/// extracted out of the EPUB archive into a cached temp file (AVPlayer can't read the custom scheme).
enum EPUBMediaURLResolver {
    static func playableURL(for media: EPUBMediaAttachment) async throws -> URL {
        guard let url = URL(string: media.sourceHref) else {
            throw EPUBMediaURLError.invalidURL
        }
        if url.isFileURL || url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return try await localPlaybackURL(for: url)
    }

    private static func localPlaybackURL(for url: URL) async throws -> URL {
        guard let bookId = url.host,
              let session = PublicationSessionRegistry.shared.session(for: bookId) else {
            throw PublicationSessionError.resourceNotFound(url.absoluteString)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("epub_media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the original extension so AVPlayer can infer the container type.
        let ext = url.pathExtension
        let safeStem = (bookId + url.path)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let dest = dir.appendingPathComponent(ext.isEmpty ? safeStem : "\(safeStem).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        let response = try await session.response(for: url)
        try response.data.write(to: dest, options: .atomic)
        return dest
    }
}
