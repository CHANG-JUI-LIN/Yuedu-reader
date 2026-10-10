import SwiftUI

struct ReaderTopBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let theme: ReaderTheme
    let chapterTitle: String
    let titleVisible: Bool
    let titleSize: CGFloat
    let titleTopSpacing: CGFloat
    let titleBottomSpacing: CGFloat
    let isBookmarked: Bool
    let overlayMaxWidth: CGFloat
    let onBack: () -> Void
    /// 全書搜尋 — the same sheet Apple Books opens from its 選單.
    let onOpenSearch: () -> Void
    let onToggleBookmark: () -> Void
    /// AI 助手 and AI 翻譯, the 三橫線 menu's first rows. A locked one (no Pro) is marked
    /// and its action opens the paywall.
    let menuActions: [ReaderSecondaryAction]
    /// 書籍詳情, the menu's last row — online books only.
    let onOpenBookDetail: (() -> Void)?

    @Bindable private var settings = GlobalSettings.shared
    /// iOS 17 only: the menu is a chooser sheet, and its choice runs from the sheet's real
    /// `onDismiss` (Technotes/iOS17MenuModalPresentation.md) — every row opens a sheet.
    @State private var showsLegacyMenu = false
    @State private var legacyMenuSequence = DismissalSequencedPresentation<MenuRoute>()

    private enum MenuRoute: Hashable {
        case action(ReaderSecondaryAction.ID)
        case bookDetail
    }

    private var palette: ReaderChromePalette {
        ReaderChromePalette(interface: .classic, theme: theme, settings: settings)
    }

    private var showsMenu: Bool {
        !menuActions.isEmpty || onOpenBookDetail != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Button {
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(DSFont.fixed(size: 17, weight: .medium))
                            .foregroundColor(palette.topIcon)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)   // 名稱在按鈕上（見 §7.1）
                    }
                    // Identifier moved off the Image with its accessibility: the UI test
                    // queries `app.buttons["reader_back_button"]`, so it has to live on the
                    // element that stays visible to accessibility.
                    .accessibilityIdentifier("reader_back_button")
                    .accessibilityLabel(localized("退出閱讀"))

                    // Balances the trailing side, so a visible title stays centred: one
                    // placeholder per trailing control past the first (搜尋 always, 選單 when shown).
                    Color.clear
                        .frame(width: 36, height: 36)

                    if showsMenu {
                        Color.clear
                            .frame(width: 36, height: 36)
                    }

                    if titleVisible {
                        Text(chapterTitle)
                            .font(DSFont.fixed(size: titleSize, weight: .medium))
                            .foregroundColor(palette.topIcon)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }

                    Button {
                        onOpenSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(DSFont.fixed(size: 17, weight: .medium))
                            .foregroundColor(palette.topIcon)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)   // 名稱在按鈕上（見 §7.1）
                    }
                    .accessibilityLabel(localized("Search Book"))

                    Button {
                        onToggleBookmark()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(DSFont.fixed(size: 17, weight: .medium))
                            .foregroundColor(isBookmarked ? .orange : palette.topIcon)
                            .scaleEffect(isBookmarked && !reduceMotion ? 1.15 : 1.0)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                    }
                    .animation(DSAnimation.fast, value: isBookmarked)
                    .accessibilityLabel(localized("書籤"))
                    .accessibilityValue(localized(isBookmarked ? "已加入" : "未加入"))

                    if showsMenu {
                        menu
                    }
                }
                .frame(maxWidth: overlayMaxWidth)
            }
            .padding(.horizontal, 12)
            .padding(.top, titleTopSpacing)
            .padding(.bottom, titleBottomSpacing)
            .background(palette.topFill)

            Divider().opacity(0.18)
            Spacer()
        }
    }

    // MARK: - 三橫線 menu

    @ViewBuilder
    private var menu: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyMenuSequence.cancel()
                showsLegacyMenu = true
            } label: {
                menuGlyph
            }
            .accessibilityLabel(localized("選單"))
            .sheet(isPresented: $showsLegacyMenu, onDismiss: runLegacyMenuChoice) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("選單"),
                        actions: legacyMenuActions,
                        onSelect: { legacyMenuSequence.select($0) }
                    )
                }
            }
        } else {
            Menu {
                ForEach(menuActions) { item in
                    Button(action: item.action) {
                        // A locked row keeps its name, trades its symbol for the lock the
                        // selection menu's 筆記 uses, and says why underneath. A menu reads
                        // a second `Text` in the label as the row's subtitle; inside a
                        // `Label`'s title it is dropped.
                        Text(item.label)
                        if item.isLocked {
                            Text(localized("需要 Pro"))
                        }
                        Image(systemName: item.isLocked ? "lock.fill" : item.icon)
                    }
                }
                if let onOpenBookDetail {
                    Button(action: onOpenBookDetail) {
                        Label(localized("書籍詳情"), systemImage: "info.circle")
                    }
                }
            } label: {
                menuGlyph
            }
            .accessibilityLabel(localized("選單"))
        }
    }

    private var menuGlyph: some View {
        Image(systemName: "line.3.horizontal")
            .font(DSFont.fixed(size: 17, weight: .medium))
            .foregroundColor(palette.topIcon)
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
    }

    private var legacyMenuActions: [DismissalSequencedAction<MenuRoute>] {
        var actions = menuActions.map { item in
            DismissalSequencedAction(
                route: MenuRoute.action(item.id),
                title: item.label,
                systemImage: item.isLocked ? "lock.fill" : item.icon,
                subtitle: item.isLocked ? localized("需要 Pro") : nil
            )
        }
        if onOpenBookDetail != nil {
            actions.append(DismissalSequencedAction(
                route: .bookDetail,
                title: localized("書籍詳情"),
                systemImage: "info.circle"
            ))
        }
        return actions
    }

    private func runLegacyMenuChoice() {
        switch legacyMenuSequence.consumeAfterDismissal() {
        case .action(let id):
            menuActions.first { $0.id == id }?.action()
        case .bookDetail:
            onOpenBookDetail?()
        case nil:
            break
        }
    }
}

#Preview("經典頂欄") {
    ZStack(alignment: .top) {
        ReaderTheme.white.backgroundColor
            .ignoresSafeArea()
        ReaderTopBar(
            theme: .white,
            chapterTitle: "第一章",
            titleVisible: false,
            titleSize: 16,
            titleTopSpacing: 10,
            titleBottomSpacing: 10,
            isBookmarked: false,
            overlayMaxWidth: 700,
            onBack: {},
            onOpenSearch: {},
            onToggleBookmark: {},
            menuActions: [
                ReaderSecondaryAction(id: .aiAssistant, icon: "sparkles", label: "AI 助手", isLocked: true, action: {}),
                ReaderSecondaryAction(id: .translation, icon: "translate", label: "AI 翻譯", isLocked: true, action: {}),
            ],
            onOpenBookDetail: {}
        )
    }
}
