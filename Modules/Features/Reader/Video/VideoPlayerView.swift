import AVFoundation
import AVKit
import SwiftUI

/// The video player, laid out as Swiftfin and plezy lay theirs out (maintainer, 2026-11-01:
/// 「照開源的emby player」, 「plezy 這個也算吧」): the picture full screen, and over it a top
/// bar (close, title, actions), previous / play-pause / next in the centre (plezy), and the
/// timeline at the bottom. A tap shows and hides them; the episodes open in a sheet.
///
/// On an iPhone it opens in landscape and turns to portrait for a portrait picture, as the
/// picture reports its size (maintainer, 2026-11-01: 「依影片比例」).
struct VideoPlayerView: View {
    enum Content {
        /// A shelf book: its position is saved to the shelf.
        case shelf(UUID)
        /// A book played from its detail page without being shelved: position in memory only.
        case transient(ReadingBook)
        /// A source script's one link (`java.openVideoPlayer`).
        case link(VideoStream, title: String)
    }

    let content: Content
    let onClose: () -> Void

    @EnvironmentObject private var store: BookStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var controller: VideoPlaybackController?
    @State private var showsControls = true
    /// Bumped by every interaction; the controls hide a while after the last one.
    @State private var interaction = 0
    @State private var showsEpisodes = false
    /// The time under the finger while the timeline is dragged.
    @State private var scrubTime: Double?
    /// A drag on the picture in progress.
    @State private var pan: VideoPan?
    @State private var fillsScreen = false
    @State private var window = ReaderWindowReference()

    var body: some View {
        ZStack {
            DSColor.videoPlayerBackground.ignoresSafeArea()
            if let controller {
                VideoPlayerLayerView(player: controller.player, fillsScreen: fillsScreen,
                                     onLayer: controller.attachPictureInPicture(to:))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                gestureSurface(controller)
                if showsControls {
                    controls(controller)
                        .transition(.opacity)
                }
                if controller.isLongPressing {
                    longPressBadge
                }
                if let pan, pan.kind == .seek, let range = controller.seekableRange {
                    VideoSeekBadge(time: pan.value, end: range.upperBound, delta: pan.value - pan.origin)
                }
            } else {
                ProgressView()
                    .tint(DSColor.textOnFixedFill)
            }
        }
        .readerWindowProbe(window)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .animation(DSAnimation.fast, value: showsControls)
        .task {
            guard controller == nil, let controller = makeController() else { return }
            self.controller = controller
            turn(to: .landscape)
            controller.start()
        }
        .onChange(of: controller?.pictureSize) { _, size in
            guard let size else { return }
            turn(to: size.height > size.width ? .portrait : .landscape)
        }
        // An inactivity timeout, not a wait for state: the controls get out of the picture's
        // way, as every video player's do. VoiceOver keeps them, as it cannot find a hidden one.
        .task(id: interaction) {
            guard showsControls, !voiceOverEnabled, controller?.phase == .playing else { return }
            try? await Task.sleep(for: DSAnimation.videoControlsAutoHide)
            guard !Task.isCancelled, scrubTime == nil, !showsEpisodes else { return }
            showsControls = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller?.saveProgress(force: true) }
        }
        // The picture's gesture surface is hidden from VoiceOver; the controls are all it can
        // reach, so they come back when it turns on over hidden ones.
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { showsControls = true }
        }
        .onDisappear {
            controller?.close()
            if turnsWindow { ReaderOrientationController.shared.restoreDefault(in: window.windowScene) }
        }
        .sheet(isPresented: $showsEpisodes) {
            if let controller {
                VideoEpisodeSheet(
                    guide: controller.guide,
                    current: controller.chapterIndex,
                    title: controller.title(of:),
                    onSelect: { chapterIndex in
                        showsEpisodes = false
                        controller.play(chapterIndex: chapterIndex)
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func makeController() -> VideoPlaybackController? {
        switch content {
        case .shelf(let id):
            store.readingBook(id: id).map { VideoPlaybackController(book: $0, store: store, persists: true) }
        case .transient(let book):
            VideoPlaybackController(book: book, store: store, persists: false)
        case .link(let stream, let title):
            VideoPlaybackController(link: stream, title: title)
        }
    }

    /// Whether the player turns its window: an iPhone's only. An iPad's window is the size the
    /// person made it, and turning the device is theirs.
    private var turnsWindow: Bool {
        window.windowScene?.traitCollection.userInterfaceIdiom == .phone
    }

    private func turn(to orientation: FixedLayoutOrientation) {
        window.withWindow { uiWindow in
            guard let scene = uiWindow.windowScene, scene.traitCollection.userInterfaceIdiom == .phone else { return }
            ReaderOrientationController.shared.request(orientation, in: scene)
        }
    }

    private func touched() {
        interaction += 1
    }

    // MARK: Gestures

    /// Under the controls: a tap shows or hides them, a long press plays faster while held
    /// (legado-E), a swipe across seeks (FB-144), and a swipe up opens the episodes (plezy). Each
    /// has a control too: VoiceOver, which cannot reach the surface, keeps the labeled timeline.
    private func gestureSurface(_ controller: VideoPlaybackController) -> some View {
        VideoGestureSurface(
            isLocked: false,
            onTap: {
                showsControls.toggle()
                touched()
            },
            onLongPress: { controller.setLongPressing($0) },
            onPan: { panned($0, controller) },
            // Pinching is not wired in yet (0ac5df7a's pieces); a pinch does nothing.
            onPinch: { _ in }
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func panned(_ event: VideoGestureSurface.PanEvent, _ controller: VideoPlaybackController) {
        switch event {
        case .began(let start, let translation, let size):
            let kind = VideoPanKind(start: start, translation: translation, in: size)
            // A stream with nothing to seek in (live, or still loading) ignores a swipe across.
            guard kind != .seek || controller.seekableRange != nil else { return }
            pan = VideoPan(kind: kind, origin: controller.currentTime, value: controller.currentTime)
            touched()
        case .changed(let translation, let size):
            guard var current = pan, current.kind == .seek, let range = controller.seekableRange else { return }
            current.value = VideoPan.seekTime(origin: current.origin, translation: translation.width,
                                              width: size.width, in: range)
            pan = current
            scrubTime = current.value
        case .ended(let translation, _):
            guard let finished = pan else { return }
            pan = nil
            switch finished.kind {
            case .seek:
                controller.seek(to: finished.value)
                scrubTime = nil
            // The edges' brightness and volume are not wired in yet: an up-down drag anywhere
            // keeps opening the episodes, as it did before the seek.
            case .episodes, .brightness, .volume:
                if hasEpisodes(controller), translation.height < -DSLayout.videoSwipeThreshold {
                    showsEpisodes = true
                }
            }
            touched()
        case .cancelled:
            pan = nil
            scrubTime = nil
        }
    }

    private var longPressBadge: some View {
        VStack {
            Label(VideoPlayerFormat.rate(VideoPlaybackController.longPressRate), systemImage: "forward.fill")
                .font(DSFont.subheadline.weight(.semibold))
                .foregroundStyle(DSColor.textOnFixedFill)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.xs)
                .background(DSColor.videoControlScrim, in: Capsule())
                .padding(.top, DSSpacing.xl)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: Controls

    private func controls(_ controller: VideoPlaybackController) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: DSColor.videoControlScrim, location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.7),
                    .init(color: DSColor.videoControlScrim, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar(controller)
                Spacer()
                bottomBar(controller)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            centerControls(controller)
        }
        .foregroundStyle(DSColor.textOnFixedFill)
    }

    private func topBar(_ controller: VideoPlaybackController) -> some View {
        HStack(spacing: DSSpacing.md) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DSFont.toolbarIconLarge)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("關閉"))
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(controller.book.title)
                    .font(DSFont.headline)
                    .lineLimit(1)
                Text(subtitle(controller))
                    .font(DSFont.caption)
                    .opacity(DSLayout.cardSecondaryTextOpacity)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            speedMenu(controller)
            // The system's button names itself to VoiceOver.
            AirPlayButton()
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            Button {
                fillsScreen.toggle()
                touched()
            } label: {
                Image(systemName: fillsScreen
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(fillsScreen ? localized("完整畫面") : localized("填滿螢幕"))
            if hasEpisodes(controller) {
                Button {
                    showsEpisodes = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(DSFont.toolbarIcon)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("選集"))
            }
        }
    }

    /// A script's single link has no episodes to choose from.
    private func hasEpisodes(_ controller: VideoPlaybackController) -> Bool {
        controller.hasNext || controller.hasPrevious
    }

    private func subtitle(_ controller: VideoPlaybackController) -> String {
        let episode = controller.episodeTitle
        guard let route = controller.route?.title, controller.guide.routes.count > 1 else { return episode }
        return "\(route) · \(episode)"
    }

    private func speedMenu(_ controller: VideoPlaybackController) -> some View {
        Menu {
            Picker(localized("倍速"), selection: Binding(
                get: { controller.rate },
                set: { controller.setRate($0); touched() }
            )) {
                ForEach(VideoPlaybackController.rates, id: \.self) { rate in
                    Text(VideoPlayerFormat.rate(rate)).tag(rate)
                }
            }
        } label: {
            Text(VideoPlayerFormat.rate(controller.rate))
                .font(DSFont.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
        }
        .accessibilityLabel(localized("倍速"))
        .accessibilityValue(VideoPlayerFormat.rate(controller.rate))
    }

    private func centerControls(_ controller: VideoPlaybackController) -> some View {
        HStack(spacing: DSSpacing.xxl) {
            Button(action: { controller.playPrevious(); touched() }) {
                Image(systemName: "backward.end.fill")
                    .font(DSFont.title2)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .disabled(!controller.hasPrevious)
            .accessibilityLabel(localized("上一集"))
            playPauseButton(controller)
            Button(action: { controller.playNext(); touched() }) {
                Image(systemName: "forward.end.fill")
                    .font(DSFont.title2)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .disabled(!controller.hasNext)
            .accessibilityLabel(localized("下一集"))
        }
    }

    @ViewBuilder
    private func playPauseButton(_ controller: VideoPlaybackController) -> some View {
        switch controller.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(DSColor.textOnFixedFill)
                .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
        case .failed(let message):
            VStack(spacing: DSSpacing.sm) {
                Text(message)
                    .font(DSFont.subheadline)
                    .multilineTextAlignment(.center)
                Button(localized("重試")) { controller.retry() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: DSLayout.readableListWidth)
        default:
            Button(action: { controller.togglePlayPause(); touched() }) {
                Image(systemName: playSymbol(controller.phase))
                    .font(DSFont.largeTitle)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .accessibilityLabel(controller.phase == .playing ? localized("暫停") : localized("播放"))
        }
    }

    private func playSymbol(_ phase: VideoPlaybackController.Phase) -> String {
        switch phase {
        case .playing: "pause.fill"
        case .ended: "arrow.counterclockwise"
        default: "play.fill"
        }
    }

    private func bottomBar(_ controller: VideoPlaybackController) -> some View {
        let shown = scrubTime ?? controller.currentTime
        let range = controller.seekableRange
        let end = range?.upperBound ?? controller.duration
        return VStack(spacing: DSSpacing.xxs) {
            Slider(
                value: Binding(get: { shown }, set: { scrubTime = $0 }),
                in: range ?? 0...max(shown, 1),
                onEditingChanged: { editing in
                    if !editing, let scrubTime {
                        controller.seek(to: scrubTime)
                        self.scrubTime = nil
                    }
                    touched()
                }
            )
            // Disabled only while nothing is seekable — a live stream with no window, or one
            // still loading. A playlist with no duration still seeks in its seekable ranges.
            .disabled(range == nil)
            .accessibilityLabel(localized("播放進度"))
            .accessibilityValue(VideoPlayerFormat.position(shown, of: end))
            HStack {
                Text(VideoPlayerFormat.time(shown))
                Spacer()
                Text(VideoPlayerFormat.time(end))
            }
            .font(DSFont.caption.monospacedDigit())
            .opacity(DSLayout.cardSecondaryTextOpacity)
            .accessibilityHidden(true)
        }
    }
}

#Preview {
    var book = ReadingBook(title: "示範短劇", author: "", contentFilename: "")
    book.isOnline = true
    book.contentPipelineKind = .video
    book.onlineChapters = [
        OnlineChapterRef(index: 0, title: "第1集", url: "https://example.com/1.m3u8"),
        OnlineChapterRef(index: 1, title: "第2集", url: "https://example.com/2.m3u8"),
    ]
    return VideoPlayerView(content: .transient(book), onClose: {})
        .environmentObject(BookStore())
}

#Preview("Seek badge") {
    ZStack {
        DSColor.videoPlayerBackground.ignoresSafeArea()
        VideoSeekBadge(time: 754, end: 2700, delta: 65)
    }
}

// MARK: - Seek badge

/// Where a swipe across the picture will land: 「12:34 / 45:00」 over how far it moves.
struct VideoSeekBadge: View {
    let time: Double
    let end: Double
    let delta: Double

    var body: some View {
        VStack(spacing: DSSpacing.xxs) {
            Text("\(VideoPlayerFormat.time(time)) / \(VideoPlayerFormat.time(end))")
                .font(DSFont.title3.weight(.semibold))
            Text(VideoPlayerFormat.delta(delta))
                .font(DSFont.subheadline)
                .opacity(DSLayout.cardSecondaryTextOpacity)
        }
        .monospacedDigit()
        .foregroundStyle(DSColor.textOnFixedFill)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .background(DSColor.videoControlScrim, in: RoundedRectangle(cornerRadius: DSRadius.md))
        .allowsHitTesting(false)
        // The surface that drives it is hidden from VoiceOver, whose timeline announces itself.
        .accessibilityHidden(true)
    }
}

// MARK: - Formatting

@MainActor
enum VideoPlayerFormat {
    static func time(_ seconds: Double) -> String {
        AudiobookReaderView.formatTime(seconds)
    }

    /// How far a swipe moves: 「+1:05」, 「−0:30」.
    static func delta(_ seconds: Double) -> String {
        (seconds < 0 ? "−" : "+") + time(abs(seconds))
    }

    static func rate(_ rate: Float) -> String {
        AudiobookReaderView.rateLabel(rate)
    }

    /// The timeline's VoiceOver value: where it is, of how long.
    static func position(_ seconds: Double, of duration: Double) -> String {
        guard duration > 0 else { return time(seconds) }
        return String(format: localized("%1$@，共 %2$@"), time(seconds), time(duration))
    }
}

// MARK: - Picture

/// The picture: an `AVPlayerLayer`, so the controls over it are ours (彈幕 and the episode
/// list have no place in `AVPlayerViewController`).
struct VideoPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fillsScreen: Bool
    /// Hands over the layer once, for Picture in Picture.
    var onLayer: @MainActor (AVPlayerLayer) -> Void = { _ in }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = UIColor(DSColor.videoPlayerBackground)
        view.playerLayer.player = player
        onLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
    }
}

/// The system's AirPlay route button.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(DSColor.textOnFixedFill)
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
