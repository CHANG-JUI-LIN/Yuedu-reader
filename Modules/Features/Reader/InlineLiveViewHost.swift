import AVKit
import UIKit
import WebKit
import YueduCoreText

/// Something in the text that plays in place once tapped: a video, or an `<iframe>` page.
enum InlineLiveContent {
    case video(EPUBMediaAttachment)
    case web(ReaderWebEmbed)

    /// One live view per piece of content.
    var key: String {
        switch self {
        case .video(let media): return "video:" + media.sourceHref
        case .web(let embed): return "web:" + embed.key
        }
    }

    /// Started by the reader and still held by its manager, so its view comes back on screen.
    @MainActor var isActive: Bool {
        switch self {
        case .video(let media): return EPUBVideoPlaybackManager.shared.isActive(media)
        case .web(let embed): return ReaderWebEmbedManager.shared.isActive(embed)
        }
    }

    /// The live content a rendered attachment stands for, if any.
    init?(_ attachment: CoreTextPaginator.RenderedAttachment) {
        if let media = attachment.mediaAttachment, media.kind == .video {
            self = .video(media)
        } else if let embed = attachment.webEmbed {
            self = .web(embed)
        } else {
            return nil
        }
    }

    /// The VoiceOver action that starts it — the page itself is one drawn element.
    var accessibilityActionName: String {
        switch self {
        case .video(let media):
            let title = media.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? localized("播放影片") : String(format: localized("播放影片：%@"), title)
        case .web(let embed):
            let title = embed.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = title.isEmpty ? embed.host : title
            return name.isEmpty ? localized("內嵌網頁") : String(format: localized("載入內嵌網頁：%@"), name)
        }
    }
}

/// Puts live views — a video player, an `<iframe>` page — over their drawn placeholders, for
/// both reading modes. Paged and scroll mode each used to keep their own copy of this for video
/// alone; there is one now, and it knows both kinds.
///
/// The view is only ever a window: playback (`EPUBVideoPlaybackManager`) and the loaded page
/// (`ReaderWebEmbedManager`) live in their managers, so a view can be torn down when its content
/// scrolls or turns away and rebuilt when it comes back without restarting anything.
@MainActor
final class InlineLiveViewHost {
    private weak var owner: UIViewController?
    private var controllers: [String: UIViewController] = [:]

    private var stopObserver: NSObjectProtocol?

    init(owner: UIViewController) {
        self.owner = owner
        stopObserver = NotificationCenter.default.addObserver(
            forName: .readerWebEmbedDidStop, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneInactive() }
        }
    }

    deinit {
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
    }

    var count: Int { controllers.count }

    /// Keeps live views in step with what is on screen: views whose content left are removed,
    /// content already started gets its view back at its current frame.
    func reconcile(_ visible: [(content: InlineLiveContent, frame: CGRect)]) {
        let visibleKeys = Set(visible.map(\.content.key))
        for key in Array(controllers.keys) where !visibleKeys.contains(key) {
            detach(key: key)
        }
        pruneInactive()
        for item in visible where item.content.isActive {
            embed(item.content, frame: item.frame)
        }
    }

    /// The reader tapped `content`: show it live at `frame` and start it.
    func start(_ content: InlineLiveContent, frame: CGRect) {
        embed(content, frame: frame)
        // Starting a page closes any other live page; its window must not stay behind.
        pruneInactive()
    }

    /// Drops windows whose content is no longer live — a page the manager closed because
    /// another started or the app went to the background. Left in place, an empty frame would
    /// cover the card and swallow the tap that would start it again.
    private func pruneInactive() {
        for (key, controller) in Array(controllers) {
            guard let web = controller as? WebEmbedViewController, !web.isShowingLivePage else { continue }
            detach(key: key)
        }
    }

    func detachAll() {
        for key in Array(controllers.keys) { detach(key: key) }
    }

    private func embed(_ content: InlineLiveContent, frame: CGRect) {
        guard let owner else { return }
        if let existing = controllers[content.key] {
            if existing.view.superview !== owner.view { owner.view.addSubview(existing.view) }
            existing.view.frame = frame
            return
        }
        let controller: UIViewController
        switch content {
        case .video(let media):
            let player = AVPlayerViewController()
            player.view.backgroundColor = .black
            player.videoGravity = .resizeAspect
            player.allowsPictureInPicturePlayback = true
            controller = player
            // Bind the persistent player (resolving the URL on first use) and start it. On a
            // revisit the manager already holds a playing player and the picture resumes in sync.
            let startedFresh = !EPUBVideoPlaybackManager.shared.isActive(media)
            let key = content.key
            Task { @MainActor [weak self, weak player] in
                guard let avPlayer = await EPUBVideoPlaybackManager.shared.player(for: media) else {
                    self?.detach(key: key)
                    return
                }
                player?.player = avPlayer
                if startedFresh { avPlayer.play() }
            }
        case .web(let embed):
            let host = WebEmbedViewController(
                embed: embed, webView: ReaderWebEmbedManager.shared.webView(for: embed)
            )
            controller = host
        }
        controller.view.frame = frame
        owner.addChild(controller)
        owner.view.addSubview(controller.view)
        controller.didMove(toParent: owner)
        controllers[content.key] = controller
    }

    private func detach(key: String) {
        guard let controller = controllers.removeValue(forKey: key) else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        // Only the window goes: the player keeps playing in its manager, the page stays loaded.
        (controller as? AVPlayerViewController)?.player = nil
        (controller as? WebEmbedViewController)?.releaseWebView()
    }
}

/// Shows the manager's live web view; giving it up leaves the page loaded in the manager.
private final class WebEmbedViewController: UIViewController {
    private let embed: ReaderWebEmbed
    private var webView: WKWebView?

    init(embed: ReaderWebEmbed, webView: WKWebView) {
        self.embed = embed
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    /// Still showing the manager's live page (false once the manager closed it).
    var isShowingLivePage: Bool {
        webView != nil && ReaderWebEmbedManager.shared.isActive(embed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        guard let webView else { return }
        webView.removeFromSuperview()
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
    }

    func releaseWebView() {
        webView?.removeFromSuperview()
        webView = nil
    }
}
