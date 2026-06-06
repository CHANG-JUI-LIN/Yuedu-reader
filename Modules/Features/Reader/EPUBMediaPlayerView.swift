import AVKit
import SwiftUI

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
                    Button(localized("完成")) { dismiss() }
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
        guard let url = URL(string: media.sourceHref) else {
            errorMessage = localized("無效的媒體網址")
            return
        }

        let playableURL: URL
        if url.isFileURL || url.scheme == "http" || url.scheme == "https" {
            playableURL = url
        } else {
            // EPUB resources are served over a custom scheme (`reader-book://…`) that AVPlayer
            // cannot read. Extract the resource out of the archive to a temp file and play that.
            do {
                playableURL = try await Self.localPlaybackURL(for: url)
            } catch {
                errorMessage = localized("無法載入媒體")
                return
            }
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

    /// Resolves a `reader-book://<bookId>/<path>` resource URL to a local file AVPlayer can open,
    /// extracting the bytes from the EPUB archive once and caching them in the temp directory.
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
