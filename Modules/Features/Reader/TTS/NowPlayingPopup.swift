import Combine
import LNPopupUI
import SwiftUI
import UIKit

// MARK: - The app root's now-playing bar
//
// What plays on with no reader on screen — an audiobook, or narration whose book was closed —
// shows as one bar over the tabs (maintainer, 2026-11-05: 「統一改成 MiniPlayer」), and an
// audiobook's player grows out of it and folds back into it, under the finger, as Apple Books'
// and Apple Music's do. The bar and those transitions are LNPopupUI's (Léo Natan, MIT), the
// community's long-standing recreation of Apple Music's popup — the maintainer's choice
// (2026-11-05) over Apple's tab-bar accessory, whose zoom transition SwiftUI drops when an
// observable object drives the presentation (Apple Developer Forums 809806, still on 26.4).
// LNPopupUI draws iOS 26's floating glass bar there and iOS 17's Apple Music card before it.
//
// The bar carries Apple Books' layout from iOS 26 — cover, book over chapter, the price pill
// (here 加入書架, for an audiobook played without being shelved) and ⏸ — and Apple Music's
// before: cover, book over chapter, ▶︎ and ⏭. A long press opens Apple Books' menu for it
// (`NowPlayingBarRoute`). A reader on screen keeps its own capsule (`NowPlayingMiniPlayer`),
// and the bar steps aside for it.
//
// Narration has no player page: its bar reopens the book, whose reader takes the narration over.

/// What the bar's long press offers: Apple Books' menu for its audiobook bar (maintainer,
/// 2026-11-05, from a screenshot), in its order, on what Yuedu has — 分享 and 加入分組
/// (欲讀清單) side by side, 停止播放 (關閉音訊播放程式), 加入書架 (加入藏書), 標記為已讀完,
/// 作品詳情 (在商店中檢視), then 移除書架… (移除…). 增加建議 and 減少建議 have no counterpart.
/// The audiobook player's ••• maps the same rows (`AudiobookMoreRoute`), and shares their names.
enum NowPlayingBarRoute: Hashable {
    case share
    case addToGroup
    case stop
    case addToShelf
    case markFinished
    case workDetail
    case removeFromShelf

    var title: String {
        switch self {
        case .share: AudiobookMoreRoute.share.title
        case .addToGroup: AudiobookMoreRoute.addToGroup.title
        case .stop: localized("停止播放")
        case .addToShelf: AudiobookMoreRoute.addToShelf.title
        case .markFinished: AudiobookMoreRoute.markFinished.title
        case .workDetail: AudiobookMoreRoute.workDetail.title
        case .removeFromShelf: AudiobookMoreRoute.removeFromShelf.title
        }
    }

    var systemImage: String {
        switch self {
        case .share: AudiobookMoreRoute.share.systemImage
        case .addToGroup: AudiobookMoreRoute.addToGroup.systemImage
        case .stop: "xmark.circle"
        case .addToShelf: AudiobookMoreRoute.addToShelf.systemImage
        case .markFinished: AudiobookMoreRoute.markFinished.systemImage
        case .workDetail: AudiobookMoreRoute.workDetail.systemImage
        case .removeFromShelf: AudiobookMoreRoute.removeFromShelf.systemImage
        }
    }
}

/// The book the bar stands for, as its menu sees it.
struct NowPlayingBarBook: Equatable {
    let id: UUID
    let title: String
    /// An audiobook, not a book being read aloud: only an audiobook can be shelved from here.
    let isAudiobook: Bool
    let isShelved: Bool
    let isFinished: Bool
    let shareURL: URL?

    /// The menu's rows, in its order — also the rows of iOS 17's chooser. A book not on the
    /// shelf has no group, no progress and no shelf copy to remove; narration of one cannot be
    /// shelved from here either, since only its reader has the book to add.
    var routes: [NowPlayingBarRoute] {
        var routes: [NowPlayingBarRoute] = []
        if shareURL != nil { routes.append(.share) }
        if isShelved { routes.append(.addToGroup) }
        routes.append(.stop)
        if !isShelved, isAudiobook { routes.append(.addToShelf) }
        if isShelved, !isFinished { routes.append(.markFinished) }
        if isShelved { routes += [.workDetail, .removeFromShelf] }
        return routes
    }

    /// The book playing now, read off the hub and the shelf at the moment it is asked for.
    @MainActor
    static func playing(store: BookStore) -> NowPlayingBarBook? {
        let hub = NowPlayingHub.shared
        guard let id = hub.nowPlayingBookID else { return nil }
        let record = store.shelfRecord(id: id)
        let book = store.readingBook(id: id)
            ?? (hub.source == .audiobook ? AudiobookPlayer.shared.playingBook : nil)
        return NowPlayingBarBook(
            id: id,
            title: NowPlayingBarState(hub: hub).title,
            isAudiobook: hub.source == .audiobook,
            isShelved: record != nil,
            isFinished: (record?.currentPosition ?? 0) >= 0.99,
            shareURL: book.flatMap { NowPlayingBookActions.shareURL(for: $0, store: store) }
        )
    }
}

// MARK: - Book actions shared with the audiobook player

/// What the bar's menu and the audiobook player's ••• do to the book playing — one path for
/// both. Presenting what they open is each host's own.
@MainActor
enum NowPlayingBookActions {
    /// A shelf book's link, or its file for a local one: what 分享 hands on.
    static func shareURL(for book: ReadingBook, store: BookStore) -> URL? {
        if let file = store.shareableFileURL(for: book) { return file }
        guard let url = URL(string: book.bookInfoURL ?? book.source),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// 作品詳情 of a shelf book, frozen at the navigation boundary: the page never re-resolves
    /// it from what is playing.
    static func workDetailRoute(for record: ReadingBook, store: BookStore) -> WorkDetailRoute? {
        guard let route = ShelfProvider(store: store).items([record]).first.flatMap(WorkDetailRoute.init) else {
            AppLogger.info("⟐ now playing workDetail no route bookID=\(record.id)")
            return nil
        }
        return route
    }

    /// 標記為已讀完. Paused first: a place saved while it plays would write the progress back.
    static func markFinished(bookId: UUID, store: BookStore) {
        NowPlayingHub.shared.pause()
        store.markFinished(bookId: bookId)
    }

    /// 移除書架: what plays stops with the book. `close` takes the page acting on it away
    /// before the book goes.
    static func removeFromShelf(bookId: UUID, store: BookStore, closing close: () -> Void = {}) {
        let record = store.readingBook(id: bookId)
        NowPlayingHub.shared.stop()
        close()
        if let record {
            SourceCallBackService.notify(.delBookShelf, book: record)
        }
        store.delete(bookId: bookId)
    }

    /// 加入書架 for the audiobook playing without being shelved. The shelf book it became, or
    /// nil when it did not — said in a toast either way.
    static func addPlayingAudiobookToShelf(store: BookStore, dependencies: AppDependencies) async -> UUID? {
        let player = AudiobookPlayer.shared
        do {
            try await player.addPlayingBookToShelf(dependencies: dependencies)
            guard let id = player.bookId, store.shelfRecord(id: id) != nil else { return nil }
            BookSourceFormLoginView.presentToastAlert(message: localized("已加入書架"))
            return id
        } catch {
            AppLogger.error("now playing add to shelf failed", error: error)
            BookSourceFormLoginView.presentToastAlert(message: error.localizedDescription)
            return nil
        }
    }

    /// legado's startRead and endRead for the audiobook playing, as its `AudioPlayActivity`
    /// sends them when the player screen comes and goes: here as the player opens out of the
    /// root's bar and folds back into it.
    static func notifyPlayerScreen(_ event: SourceCallBackEvent, store: BookStore) {
        let player = AudiobookPlayer.shared
        guard let id = player.bookId, let book = store.readingBook(id: id) else { return }
        let chapter = player.chapters.indices.contains(player.chapterIndex)
            ? SourceCallBackService.chapterSnapshot(player.chapters[player.chapterIndex]) : nil
        SourceCallBackService.notify(event, book: book, chapter: chapter)
    }
}

// MARK: - What the menu presents

/// The bar's menu rows that open something — a sheet, a share sheet, a confirmation — and what
/// they open. The bar has no presenter of its own, so the host at the root of the tabs presents
/// them (`NowPlayingPopupHost`).
@MainActor
@Observable
final class NowPlayingBarActions {
    struct GroupSheet: Identifiable { let id: UUID }

    struct WorkDetail: Identifiable {
        let id = UUID()
        let bookID: UUID
        let route: WorkDetailRoute
    }

    var groupSheet: GroupSheet?
    var workDetail: WorkDetail?
    var pendingShare: PendingShareExport<URL>?
    var confirmsRemoval = false
    /// iOS 17's chooser in place of the menu: a menu there cannot launch a sheet
    /// (`MenuModalPresentationPolicy`).
    var showsChooser = false
    private(set) var chooserBook: NowPlayingBarBook?
    private(set) var isAddingToShelf = false
    private var removalBookID: UUID?
    private var chooserSequence = DismissalSequencedPresentation<NowPlayingBarRoute>()
    /// 作品詳情's 繼續閱讀: what plays opens once the page is gone (`continueAfterWorkDetail`).
    private var continuesAfterWorkDetail = false

    func perform(
        _ route: NowPlayingBarRoute,
        on book: NowPlayingBarBook,
        store: BookStore,
        dependencies: AppDependencies
    ) {
        switch route {
        case .share:
            guard let url = book.shareURL else { return }
            pendingShare = PendingShareExport(title: route.title, name: book.title, item: url)
        case .addToGroup:
            groupSheet = GroupSheet(id: book.id)
        case .stop:
            NowPlayingHub.shared.stop()
        case .addToShelf:
            addToShelf(store: store, dependencies: dependencies)
        case .markFinished:
            NowPlayingBookActions.markFinished(bookId: book.id, store: store)
        case .workDetail:
            guard let record = store.shelfRecord(id: book.id),
                  let route = NowPlayingBookActions.workDetailRoute(for: record, store: store)
            else { return }
            workDetail = WorkDetail(bookID: book.id, route: route)
        case .removeFromShelf:
            removalBookID = book.id
            confirmsRemoval = true
        }
    }

    func addToShelf(store: BookStore, dependencies: AppDependencies) {
        guard !isAddingToShelf else { return }
        isAddingToShelf = true
        Task { @MainActor in
            defer { isAddingToShelf = false }
            _ = await NowPlayingBookActions.addPlayingAudiobookToShelf(store: store, dependencies: dependencies)
        }
    }

    func confirmRemoval(store: BookStore) {
        guard let id = removalBookID else { return }
        removalBookID = nil
        NowPlayingBookActions.removeFromShelf(bookId: id, store: store)
    }

    // iOS 17's chooser

    func openChooser(for book: NowPlayingBarBook) {
        chooserBook = book
        showsChooser = true
    }

    func choose(_ route: NowPlayingBarRoute) {
        chooserSequence.select(route)
    }

    /// From the chooser's real `onDismiss`: the row chosen runs once the chooser has gone.
    func runChosenRoute(store: BookStore, dependencies: AppDependencies) {
        guard let route = chooserSequence.consumeAfterDismissal(), let book = chooserBook else { return }
        perform(route, on: book, store: store, dependencies: dependencies)
    }

    // 作品詳情

    /// 繼續閱讀 on 作品詳情: back to what plays — the audiobook's player at the chapter picked,
    /// or the narrated book's reader, which takes the narration over.
    func continueFromWorkDetail(at target: ReaderTOCTarget?) {
        let hub = NowPlayingHub.shared
        if let target, hub.source == .audiobook {
            AudiobookPlayer.shared.selectChapter(target.spineIndex)
        }
        continuesAfterWorkDetail = true
        workDetail = nil
    }

    /// From the page's real `onDismiss`: what plays is asked to open only once the page has
    /// gone, since a presentation asked for while it was still going would be dropped.
    func continueAfterWorkDetail() {
        guard continuesAfterWorkDetail else { return }
        continuesAfterWorkDetail = false
        NowPlayingHub.shared.openFromRootBar()
    }
}

// MARK: - What the bar shows

/// What the root's bar shows and whether it is up, read off the hub. The host keeps a copy and
/// takes a new one only when one of these changed: the hub publishes once per spoken sentence,
/// and each update of the popup re-applies the bar's whole appearance.
struct NowPlayingBarState: Equatable {
    var source: NowPlayingSource = .none
    var bookID: UUID?
    /// The book.
    var title = ""
    /// The chapter.
    var subtitle: String?
    var cover: UIImage?
    var coverTitle = ""
    var isPlaying = false
    var hasNextChapter = false
    var audiobookLoaded = false
    var narrationOutlivesReader = false
    var readerHostsPlayer = false
    var isPlayerOpen = false
    var returnsToDetailPage = false

    @MainActor
    init(hub: NowPlayingHub) {
        source = hub.source
        bookID = hub.nowPlayingBookID
        title = hub.coverTitle.isEmpty ? hub.title : hub.coverTitle
        subtitle = hub.title.isEmpty || hub.title == title ? nil : hub.title
        cover = hub.coverImage
        coverTitle = hub.coverTitle
        isPlaying = hub.playbackState == .playing
        hasNextChapter = hub.source == .tts || AudiobookPlayer.shared.hasNextChapter
        audiobookLoaded = hub.showsGlobalBar
        narrationOutlivesReader = hub.holdsNarrationPastReader
        readerHostsPlayer = hub.readerHostsPlayer
        isPlayerOpen = hub.isPlayerOpen
        returnsToDetailPage = hub.playerReturnsToDetailPage
    }

    init() {}

    /// Narration has no player page: tapping its bar reopens the book.
    var reopensNarratedBook: Bool { source == .tts && narrationOutlivesReader }

    /// What VoiceOver says tapping the bar does — as the reader capsule's cover says it.
    var openHint: String {
        localized(reopensNarratedBook ? "打開這本書到正在朗讀的地方" : "打開播放控制面板")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.bookID == rhs.bookID && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.cover === rhs.cover && lhs.coverTitle == rhs.coverTitle
            && lhs.isPlaying == rhs.isPlaying && lhs.hasNextChapter == rhs.hasNextChapter
            && lhs.audiobookLoaded == rhs.audiobookLoaded
            && lhs.narrationOutlivesReader == rhs.narrationOutlivesReader
            && lhs.readerHostsPlayer == rhs.readerHostsPlayer && lhs.isPlayerOpen == rhs.isPlayerOpen
            && lhs.returnsToDetailPage == rhs.returnsToDetailPage
    }
}

@MainActor
enum NowPlayingPopup {
    /// The root's bar shows what a reader on screen is not showing — an audiobook, or narration
    /// whose book was closed — and goes with the tab bar when a page hides it. While the player is
    /// open the bar stays: the player folds back into it.
    static func isBarPresented(
        audiobookLoaded: Bool,
        narrationOutlivesReader: Bool,
        readerHostsPlayer: Bool,
        tabBarHidden: Bool,
        isPlayerOpen: Bool
    ) -> Bool {
        if isPlayerOpen, audiobookLoaded { return true }
        return !tabBarHidden && NowPlayingHub.showsMiniPlayer(
            inReader: false,
            readerTTSVisible: false,
            audiobookLoaded: audiobookLoaded,
            narrationOutlivesReader: narrationOutlivesReader,
            readerHostsPlayer: readerHostsPlayer
        )
    }

    /// The bar's buttons: Apple Books' from iOS 26 — 加入書架 for a book played without being
    /// shelved, and ⏸ — and Apple Music's before, ▶︎ and ⏭.
    static func barButtons(usesAppleBooksLayout: Bool, showsAddToShelf: Bool) -> [NowPlayingBarButton] {
        if usesAppleBooksLayout {
            return showsAddToShelf ? [.addToShelf, .playPause] : [.playPause]
        }
        return [.playPause, .nextChapter]
    }
}

enum NowPlayingBarButton: Hashable {
    case addToShelf
    case playPause
    case nextChapter
}

// MARK: - Host

/// Wraps the root `TabView`: presents the bar over it, opens the audiobook's player out of it,
/// and presents what the bar's menu opens.
///
/// It observes `NowPlayingHub` through a copy of what the bar shows (`NowPlayingBarState`), so
/// neither the root nor the popup re-renders once per spoken sentence. Every presentation is
/// applied in every state, varying only inside: one that came and went with the bar would give
/// the tabs a new identity and reset their navigation (`ThemedSurfaceBackground`).
///
/// LNPopupUI hosts what it wraps, the player and the menu in hosting controllers of its own,
/// which do not inherit this environment: each is handed what the app root gives the tabs.
struct NowPlayingPopupHost: ViewModifier {
    let store: BookStore
    let subscriptionStore: SubscriptionStore
    @ObservedObject var tabBar: RootTabBarVisibility
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.appThemes) private var appThemes
    @Environment(\.scenePhase) private var scenePhase
    @State private var actions = NowPlayingBarActions()
    @State private var bar = NowPlayingBarState()
    @State private var gestures = NowPlayingBarGestures()
    @State private var shelfCover: ShelfCover?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private struct ShelfCoverKey: Equatable {
        var bookID: UUID?
        var colorScheme: ColorScheme
    }

    private struct ShelfCover {
        let bookID: UUID
        let image: UIImage
    }

    func body(content: Content) -> some View {
        @Bindable var bindable = actions
        let hub = NowPlayingHub.shared
        let store = store
        let dependencies = dependencies
        let actions = actions
        let bar = bar
        return content
            .modifier(AppRootEnvironment(
                store: store, subscriptionStore: subscriptionStore, dependencies: dependencies,
                appThemes: appThemes, scenePhase: scenePhase
            ))
            .popup(
                isBarPresented: Binding(get: { isBarPresented }, set: { _ in }),
                isPopupOpen: Binding(
                    get: { bar.isPlayerOpen },
                    set: { open in if hub.isPlayerOpen != open { hub.isPlayerOpen = open } }
                ),
                onOpen: { NowPlayingBookActions.notifyPlayerScreen(.startRead, store: store) },
                onClose: { NowPlayingBookActions.notifyPlayerScreen(.endRead, store: store) }
            ) {
                NowPlayingPopupContent(
                    bar: bar, store: store, dependencies: dependencies, actions: actions,
                    shelfCover: shelfCover.flatMap { $0.bookID == bar.bookID ? $0.image : nil }
                )
                    .modifier(AppRootEnvironment(
                        store: store, subscriptionStore: subscriptionStore, dependencies: dependencies,
                        appThemes: appThemes, scenePhase: scenePhase
                    ))
            }
            // The player draws its own grabber (Apple Books'), which folds it back into the bar.
            .popupCloseButtonStyle(.none)
            // Narration's bar reopens its book instead of opening a player (`gestures`).
            .popupInteractionStyle(bar.reopensNarratedBook ? UIViewController.PopupInteractionStyle.none : .automatic)
            .popupBarMarqueeScrollEnabled(false)
            .modifier(NowPlayingBarMenuHost(store: store, dependencies: dependencies, actions: actions))
            .popupBarCustomizer { popupBar in
                popupBar.tintColor = DSUIColor.nowPlayingBarControl
                gestures.attach(
                    to: popupBar,
                    reopensNarratedBook: bar.reopensNarratedBook,
                    accessibilityHint: bar.openHint,
                    longPressOpensChooser: MenuModalPresentationPolicy.requiresDismissalSequencedChooser,
                    openChooser: {
                        guard let book = NowPlayingBarBook.playing(store: store) else { return }
                        actions.openChooser(for: book)
                    }
                )
            }
            .onReceive(hub.objectWillChange.receive(on: DispatchQueue.main)) { _ in
                let next = NowPlayingBarState(hub: hub)
                if next != self.bar { self.bar = next }
            }
            .onAppear { self.bar = NowPlayingBarState(hub: hub) }
            // The bar shows a shelf book's cover as the shelf draws it. Loaded here, on the root
            // that is always on screen, rather than in the popup's content, which is not until
            // the player opens.
            .task(id: ShelfCoverKey(bookID: bar.bookID, colorScheme: colorScheme)) {
                guard let id = bar.bookID, let book = store.shelfRecord(id: id) else {
                    shelfCover = nil
                    return
                }
                let image = await BookshelfCoverStyle.bitmap(
                    for: book, colorScheme: colorScheme, filledCover: store.filledCovers.path(for: book),
                    size: BookRow.coverSize, scale: displayScale
                )
                guard !Task.isCancelled else { return }
                shelfCover = image.map { ShelfCover(bookID: id, image: $0) }
            }
            .sheet(item: $bindable.groupSheet) { sheet in
                AdaptiveSheetContainer(maxWidth: DSLayout.readableNarrowWidth) {
                    BookshelfAddToGroupSheet(groups: store.groupBookCounts) { group in
                        store.setGroup(group, for: sheet.id)
                    }
                }
            }
            .sheet(item: $bindable.workDetail, onDismiss: { actions.continueAfterWorkDetail() }) { detail in
                workDetailPage(detail)
            }
            .sheet(item: $bindable.pendingShare) { export in
                ShareExportSheet(export: export)
            }
            .sheet(isPresented: $bindable.showsChooser, onDismiss: {
                actions.runChosenRoute(store: store, dependencies: dependencies)
            }) {
                DismissalSequencedActionChooser(
                    title: actions.chooserBook?.title ?? "",
                    actions: (actions.chooserBook?.routes ?? []).map { route in
                        DismissalSequencedAction(
                            route: route, title: route.title, systemImage: route.systemImage,
                            isDestructive: route == .removeFromShelf
                        )
                    },
                    onSelect: { actions.choose($0) }
                )
            }
            .removeFromShelfConfirmation(isPresented: $bindable.confirmsRemoval) {
                actions.confirmRemoval(store: store)
            }
    }

    private var isBarPresented: Bool {
        NowPlayingPopup.isBarPresented(
            audiobookLoaded: bar.audiobookLoaded,
            narrationOutlivesReader: bar.narrationOutlivesReader,
            readerHostsPlayer: bar.readerHostsPlayer,
            tabBarHidden: tabBar.isTabBarHidden,
            isPlayerOpen: bar.isPlayerOpen
        )
    }

    private func workDetailPage(_ detail: NowPlayingBarActions.WorkDetail) -> some View {
        NavigationStack {
            WorkDetailView(route: detail.route, readerContext: WorkDetailReaderContext(
                bookId: detail.bookID,
                continueReading: { actions.continueFromWorkDetail(at: $0) },
                removedFromShelf: {
                    actions.workDetail = nil
                    NowPlayingHub.shared.stop()
                }
            ))
            .environmentObject(store)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { actions.workDetail = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
    }
}

/// What the app root hands the tabs (`yuedu_appApp`, `ContentView`), handed again to what
/// LNPopupUI re-hosts.
private struct AppRootEnvironment: ViewModifier {
    let store: BookStore
    let subscriptionStore: SubscriptionStore
    let dependencies: AppDependencies
    let appThemes: ActiveAppThemes
    let scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content
            .environmentObject(store)
            .environment(store.filledCovers)
            .environmentObject(subscriptionStore)
            .environment(\.appDependencies, dependencies)
            .environment(\.appThemes, appThemes)
            .environment(\.scenePhase, scenePhase)
    }
}

/// The bar's long press from iOS 18: the system's context menu, in Apple Books' order. Before,
/// iOS 17's chooser opens from the bar's own long press (`NowPlayingBarGestures`), since a menu
/// there cannot launch the sheets its rows open (`MenuModalPresentationPolicy`).
private struct NowPlayingBarMenuHost: ViewModifier {
    let store: BookStore
    let dependencies: AppDependencies
    let actions: NowPlayingBarActions

    func body(content: Content) -> some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            content
        } else {
            content.popupBarContextMenu {
                // Hosted apart from the tabs: handed what it reads.
                NowPlayingBarMenu(actions: actions, store: store, dependencies: dependencies)
            }
        }
    }
}

/// The menu's rows. Plain buttons, the share row included: the menu is hosted in a view off the
/// bar's edge, and a `ShareLink` would present its sheet from there.
private struct NowPlayingBarMenu: View {
    let actions: NowPlayingBarActions
    @ObservedObject var store: BookStore
    let dependencies: AppDependencies

    var body: some View {
        if let book = NowPlayingBarBook.playing(store: store) {
            let routes = book.routes
            ControlGroup {
                row(.share, of: book)
                    .disabled(!routes.contains(.share))
                row(.addToGroup, of: book)
                    .disabled(!routes.contains(.addToGroup))
            }
            Section {
                row(.stop, of: book)
            }
            Section {
                ForEach([NowPlayingBarRoute.addToShelf, .markFinished, .workDetail].filter(routes.contains), id: \.self) {
                    row($0, of: book)
                }
            }
            if routes.contains(.removeFromShelf) {
                Section {
                    row(.removeFromShelf, of: book)
                }
            }
        }
    }

    private func row(_ route: NowPlayingBarRoute, of book: NowPlayingBarBook) -> some View {
        Button(role: route == .removeFromShelf ? .destructive : nil) {
            actions.perform(route, on: book, store: store, dependencies: dependencies)
        } label: {
            Label(route.title, systemImage: route.systemImage)
        }
    }
}

/// What the bar's tap does besides opening the player, and the bar's names for VoiceOver.
///
/// Narration has no player to open: its tap reopens the book (`NowPlayingHub.openFromRootBar`),
/// so the bar's own open tap is switched off for it and this one takes its place. Before iOS 18
/// a long press opens the chooser in place of the context menu. Attached once per bar; the
/// customizer runs on every update of the popup.
@MainActor
final class NowPlayingBarGestures: NSObject, UIGestureRecognizerDelegate {
    private weak var bar: LNPopupBar?
    private var tap: UITapGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var openChooser: (() -> Void)?

    func attach(
        to bar: LNPopupBar,
        reopensNarratedBook: Bool,
        accessibilityHint: String,
        longPressOpensChooser: Bool,
        openChooser: @escaping () -> Void
    ) {
        if self.bar !== bar {
            self.bar = bar
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            bar.addGestureRecognizer(tap)
            self.tap = tap
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.delegate = self
            bar.addGestureRecognizer(press)
            bar.popupOpenGestureRecognizer.require(toFail: press)
            tap.require(toFail: press)
            self.press = press
        }
        self.openChooser = openChooser
        press?.isEnabled = longPressOpensChooser
        bar.popupOpenGestureRecognizer.isEnabled = !reopensNarratedBook
        tap?.isEnabled = reopensNarratedBook
        bar.popupItem?.accessibilityHint = accessibilityHint
        // VoiceOver reaches the bar's menu through 更多 on its titles, the one element LNPopupBar
        // gives VoiceOver for them (the bar itself is not one): the chooser, on every version.
        Self.titlesElement(in: bar)?.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: localized("更多"), target: self, selector: #selector(openMenuForVoiceOver)),
        ]
    }

    /// LNPopupBar's titles: the button-trait element among its views (`_LNPopupBarTitlesView`,
    /// vendored at LNPopupController 4.6.2).
    private static func titlesElement(in view: UIView) -> UIView? {
        for subview in view.subviews {
            if subview.isAccessibilityElement, subview.accessibilityTraits.contains(.button), subview is UIStackView {
                return subview
            }
            if let found = titlesElement(in: subview) { return found }
        }
        return nil
    }

    @objc private func openMenuForVoiceOver() -> Bool {
        openChooser?()
        return openChooser != nil
    }

    @objc private func tapped() {
        NowPlayingHub.shared.openFromRootBar()
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        openChooser?()
    }

    /// The bar's highlight is a long press of its own, which this one runs beside.
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - What opens out of the bar

/// The audiobook's player, which opens out of the bar, and the bar's item, which LNPopupUI reads
/// off it. Narration's bar has no player behind it.
struct NowPlayingPopupContent: View {
    let bar: NowPlayingBarState
    let store: BookStore
    let dependencies: AppDependencies
    let actions: NowPlayingBarActions
    /// The shelf's cover for a shelf book (`BookshelfCoverStyle.bitmap`); nil off the shelf, and
    /// until it has loaded.
    var shelfCover: UIImage?

    var body: some View {
        Group {
            if bar.source == .audiobook, let id = bar.bookID {
                AudiobookReaderView(
                    bookId: id,
                    detailIsPresenter: bar.returnsToDetailPage,
                    opensOutOfRootBar: true
                )
                // A new book is a new page; so is the shelf book a transient one became.
                .id(id)
            } else {
                Color.clear
            }
        }
        .popupItem(popupItem)
    }

    private var popupItem: PopupItem<String> {
        PopupItem(
            id: bar.bookID?.uuidString ?? "",
            verbatimTitle: bar.title,
            verbatimSubtitle: bar.subtitle,
            image: artwork,
            // Labelled, never a trailing closure: an unlabelled closure is matched forward to the
            // `leadingButtons:` initializer, which put ⏸ before the cover instead of after the
            // title, where Apple Books and Apple Music both have it.
            trailingButtons: {
                let buttons = buttons
                ToolbarItemGroup(placement: .popupBar) {
                    // Ink, not the accent. The bar's own tint (`popupBarCustomizer`) reaches
                    // these SwiftUI buttons only from iOS 26; before it they kept the accent.
                    if buttons.contains(.addToShelf) { addToShelfPill }
                    if buttons.contains(.playPause) { playPauseButton.tint(DSColor.nowPlayingBarControl) }
                    if buttons.contains(.nextChapter) { nextChapterButton.tint(DSColor.nowPlayingBarControl) }
                }
            }
        )
    }

    private var buttons: [NowPlayingBarButton] {
        let showsAddToShelf = bar.source == .audiobook && bar.bookID.map { store.shelfRecord(id: $0) == nil } == true
        if #available(iOS 26.0, *) {
            return NowPlayingPopup.barButtons(usesAppleBooksLayout: true, showsAddToShelf: showsAddToShelf)
        }
        return NowPlayingPopup.barButtons(usesAppleBooksLayout: false, showsAddToShelf: showsAddToShelf)
    }

    /// A shelf book's cover as the shelf draws it — not narration's own artwork, a title card on
    /// a pale page, which at the bar's size read as a blank card. Off the shelf, the cover the
    /// player or the reader has, or the title card a book without one is shown with.
    private var artwork: PopupItemImage {
        if let shelfCover {
            return PopupItemImage(Image(uiImage: shelfCover))
        }
        if let cover = bar.cover {
            return PopupItemImage(Image(uiImage: cover))
        }
        let renderer = ImageRenderer(content: GeneratedBookCover(title: bar.coverTitle.isEmpty ? bar.title : bar.coverTitle)
            .frame(width: DSLayout.nowPlayingArtworkRenderWidth,
                   height: DSLayout.nowPlayingArtworkRenderWidth / DSLayout.discoverCoverAspectRatio))
        renderer.scale = UITraitCollection.current.displayScale
        return PopupItemImage(Image(uiImage: renderer.uiImage ?? UIImage()))
    }

    private var playPauseButton: some View {
        Button {
            NowPlayingHub.shared.togglePlayback()
        } label: {
            Image(systemName: bar.isPlaying ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(localized(bar.isPlaying ? "暫停" : "播放"))
        .accessibilityIdentifier("now_playing_global_play_pause")
    }

    /// Apple Music's ⏭: the next chapter, which is an audiobook's or a narrated book's track.
    private var nextChapterButton: some View {
        Button {
            NowPlayingHub.shared.nextChapter()
        } label: {
            Image(systemName: "forward.fill")
        }
        .disabled(!bar.hasNextChapter)
        .accessibilityLabel(localized("下一章"))
        .accessibilityIdentifier("now_playing_global_next_chapter")
    }

    /// Apple Books' price pill, ink on paper: here the one thing an audiobook played without
    /// being shelved lacks.
    private var addToShelfPill: some View {
        Button {
            actions.addToShelf(store: store, dependencies: dependencies)
        } label: {
            Text(localized(actions.isAddingToShelf ? "加入中…" : "加入書架"))
                .font(DSFont.footnote.weight(.semibold))
                .foregroundStyle(DSColor.nowPlayingPillText)
                .lineLimit(1)
                .padding(.horizontal, DSSpacing.md)
                .frame(height: DSLayout.nowPlayingPillHeight)
                .background(Capsule().fill(DSColor.nowPlayingPillFill))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(actions.isAddingToShelf)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Bar, an audiobook") {
    @Previewable @State var isBarPresented = true
    @Previewable @State var isOpen = false
    TabView {
        List(1..<40) { Text("Row \($0)") }
            .tabItem { Label("書架", systemImage: "books.vertical") }
        Text("Settings")
            .tabItem { Label("設定", systemImage: "gearshape") }
    }
    .popup(isBarPresented: $isBarPresented, isPopupOpen: $isOpen) {
        Color.black
            .popupItem(PopupItem(id: "book", verbatimTitle: "傲慢與偏見", verbatimSubtitle: "第十章", trailingButtons: {
                ToolbarItemGroup(placement: .popupBar) {
                    Button {} label: { Image(systemName: "pause.fill") }
                        .accessibilityLabel(localized("暫停"))
                }
            }))
    }
    .popupCloseButtonStyle(.none)
}
#endif
