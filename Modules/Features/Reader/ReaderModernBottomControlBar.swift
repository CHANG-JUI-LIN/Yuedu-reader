import SwiftUI

/// The reader's bottom chrome: two floating capsules of one width and one height,
/// inset from the screen edges.
///
/// - The scrubber: ⏮ 上一章 / the book's progress slider / 下一章 ⏭, with the
///   chapter's page and the whole book's progress under the slider.
/// - The tools: 目錄 / 深色 / 聽書 / 主題 from `ReaderChromeToolItem` (自定義 can
///   hide or re-icon them), then 更多, which holds 書籤 and AI 助手 / AI 翻譯.
///
/// Both wear the shared 界面效果 surface (`floatingSurface`), which on iOS 26 is the
/// system's own glass, so 毛玻璃 / 透明度 / 光暈 reach them like every other floating
/// element. They are deliberately not the system bottom toolbar: the system sizes that
/// capsule from the display's corner radius, and the scrubber above it could not be
/// made to match.
///
/// The other book-scoped actions (刷新 / 換源 / 下載 / 來源配置登入 …) are not here; they
/// live in `ReaderModernBookCard` behind the cover.
struct ReaderModernBottomControlBar: View {
    /// The built-in background the reader sits on: what the bar's colours are read from.
    let readerTheme: ReaderTheme
    let overlayContentMaxWidth: CGFloat
    let canGoPrevChapter: Bool
    let canGoNextChapter: Bool
    /// The line under the slider — this chapter's page and the whole book's progress.
    /// Empty while an online chapter is still loading.
    let progressText: String
    let chapterSliderProgressValue: () -> Double
    let applyChapterSliderProgress: (Double) -> Void
    let chapterTitleForProgress: (Double) -> String
    let isCurrentPageBookmarked: Bool
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onOpenTOC: () -> Void
    /// 主題: the quick panel — font size, 翻頁, brightness, backgrounds, 自動閱讀, and
    /// the way into the full reader settings.
    let onOpenSettings: () -> Void
    let onListen: () -> Void
    /// 深色／白天: the reader switches its own dark mode, and the background with it.
    let onToggleDarkMode: () -> Void
    let onOpenBookmarks: () -> Void
    let onToggleBookmark: () -> Void
    /// AI 助手 and AI 翻譯 — those that apply to this book and that 自定義 left on — listed
    /// under 書籤 in 更多.
    let moreActions: [ReaderSecondaryAction]

    @Bindable private var settings = GlobalSettings.shared

    @State private var chapterSliderDraft: Double? = nil
    /// One height for both capsules, growing with the captions they carry.
    @ScaledMetric(relativeTo: .caption2) private var rowHeight = DSLayout.readerModernBarRowHeight
    /// iOS 17 only: 更多 is a chooser sheet, and its choice runs from the sheet's real
    /// `onDismiss` (Technotes/iOS17MenuModalPresentation.md) — 書籤 and the AI panels open
    /// sheets.
    @State private var showsLegacyMoreMenu = false
    @State private var legacyMoreSequence = DismissalSequencedPresentation<MoreRoute>()

    private enum MoreRoute: Hashable {
        case bookmarks
        case toggleBookmark
        case action(ReaderSecondaryAction.ID)
    }

    private var palette: ReaderChromePalette {
        ReaderChromePalette(theme: readerTheme, settings: settings)
    }

    /// The reader's own dark mode, which 深色／白天 switches — not whether the background
    /// it sits on is 黑色, which a dark saved background does in light mode too.
    private var isDarkMode: Bool { settings.readerDarkMode }

    private var sliderProgress: Double {
        chapterSliderDraft ?? chapterSliderProgressValue()
    }

    private var progressPercentText: String {
        String(format: "%.0f%%", sliderProgress * 100)
    }

    /// Only as tall as the two capsules; whoever shows it pins it to the bottom. The reader
    /// slides it in and out with `.move(edge: .bottom)`, which moves a view by its own
    /// height — a full-screen bar was off screen after the first frame and the menu still
    /// vanished with a cut (feedback #81).
    var body: some View {
        GlassGroup {
            VStack(spacing: DSSpacing.sm) {
                scrubberRow
                    .frame(maxWidth: .infinity, minHeight: rowHeight)
                    .floatingSurface(in: Capsule(), fill: palette.bottomFill)
                toolRow
                    .frame(maxWidth: .infinity, minHeight: rowHeight)
                    .floatingSurface(in: Capsule(), fill: palette.bottomFill)
            }
        }
        .overlay(alignment: .top) {
            if chapterSliderDraft != nil {
                scrubPreview
            }
        }
        .frame(maxWidth: overlayContentMaxWidth)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.bottom, DSSpacing.xs)
        .animation(DSAnimation.fast, value: chapterSliderDraft == nil)
    }

    // MARK: - Scrubber

    /// Laid out like the fixed-page reader's bar (`FixedPageReaderView.bottomBar`): the
    /// slider centred on the capsule's middle line, the caption pinned to the bottom
    /// edge, and the outline ⏮ / ⏭ on the same middle line. Stacking the slider and the
    /// caption in a VStack centred them as a pair, which left the slider above the
    /// arrows' line.
    private var scrubberRow: some View {
        HStack(spacing: DSSpacing.sm) {
            chapterButton(
                systemImage: "backward.end",
                label: localized("上一章"),
                isEnabled: canGoPrevChapter,
                action: onPrevChapter
            )

            ZStack {
                Slider(
                    value: Binding<Double>(
                        get: { sliderProgress },
                        set: { chapterSliderDraft = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            chapterSliderDraft = chapterSliderProgressValue()
                        } else if let draft = chapterSliderDraft {
                            applyChapterSliderProgress(draft)
                            chapterSliderDraft = nil
                        }
                    }
                )
                .tint(palette.bottomIcon)
                .accessibilityLabel(localized("閱讀進度"))
                .accessibilityValue(progressPercentText)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(progressText)
                        .font(DSFont.caption2.monospacedDigit())
                        .foregroundStyle(palette.bottomIcon.opacity(0.62))
                        .lineLimit(1)
                        .accessibilityHidden(progressText.isEmpty)
                }
                .padding(.bottom, DSSpacing.xs)
            }
            // A fixed height: the Spacer above the caption is flexible and would
            // otherwise take the space the bar's own top Spacer leaves above it.
            .frame(height: rowHeight)

            chapterButton(
                systemImage: "forward.end",
                label: localized(canGoNextChapter ? "下一章" : "書末頁"),
                isEnabled: canGoNextChapter,
                action: onNextChapter
            )
        }
        .padding(.horizontal, DSSpacing.xs)
    }

    private func chapterButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(palette.bottomIcon)
                // Explicit, not left to the button style: `.plain` does not reliably
                // dim a disabled label, and at a chapter boundary the arrow has to
                // read as unavailable.
                .opacity(isEnabled ? 1 : 0.3)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    // MARK: - Tools

    /// Same shared list 自定義 edits, so hiding a tool or importing an icon applies
    /// here. Order always follows `allCases`; persistence only records what is hidden.
    private var toolRow: some View {
        HStack(spacing: 0) {
            ForEach(settings.visibleReaderChromeToolItems) { item in
                toolButton(for: item)
            }
            moreButton
        }
        .padding(.horizontal, DSSpacing.sm)
    }

    @ViewBuilder
    private func toolButton(for item: ReaderChromeToolItem) -> some View {
        switch item {
        case .tableOfContents:
            toolButton(item: item, label: localized("目錄"), action: onOpenTOC)
        case .settings:
            toolButton(item: item, label: localized("主題"), action: onOpenSettings)
        case .listen:
            toolButton(item: item, label: localized("聽書"), action: onListen)
        case .nightMode:
            toolButton(
                item: item,
                label: localized(isDarkMode ? "白天" : "深色"),
                active: isDarkMode,
                action: onToggleDarkMode
            )
        }
    }

    private func toolButton(
        item: ReaderChromeToolItem,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolLabel(label, active: active) {
                toolGlyph(for: item, active: active)
            }
        }
        .buttonStyle(.plain)
        // Derived from the item, not the label: the label is localized, so a
        // UI test looking for 目錄 would only ever find it in one language.
        .accessibilityIdentifier("reader_tool_\(item.rawValue)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func toolLabel(
        _ label: String,
        active: Bool = false,
        @ViewBuilder glyph: () -> some View
    ) -> some View {
        VStack(spacing: DSSpacing.xxs) {
            glyph()
                .frame(height: DSLayout.readerModernToolGlyphHeight)
                .accessibilityHidden(true)
            Text(label)
                .font(DSFont.caption2)
                .lineLimit(1)
                .foregroundStyle(active ? palette.bottomAccent : palette.bottomIcon)
        }
        .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
        .contentShape(Rectangle())
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint. Only the fallback glyph takes the palette.
    @ViewBuilder
    private func toolGlyph(for item: ReaderChromeToolItem, active: Bool) -> some View {
        if let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: DSLayout.readerModernToolGlyphHeight, height: DSLayout.readerModernToolGlyphHeight)
        } else if item == .settings {
            // 主題 is the serif "Aa" Apple Books uses for its themes button.
            Text(verbatim: "Aa")
                .font(GlobalAppTypography.font(.headline, weight: .bold, systemDesign: .serif))
                .foregroundStyle(palette.bottomIcon)
        } else {
            Image(systemName: item.systemImage(isNight: isDarkMode))
                .imageScale(.large)
                .foregroundStyle(active ? palette.bottomAccent : palette.bottomIcon)
        }
    }

    // MARK: - 更多

    private var bookmarkToggleTitle: String {
        localized(isCurrentPageBookmarked ? "移除書籤" : "加入書籤")
    }

    private var bookmarkToggleSymbol: String {
        isCurrentPageBookmarked ? "bookmark.slash" : "bookmark"
    }

    @ViewBuilder
    private var moreButton: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyMoreSequence.cancel()
                showsLegacyMoreMenu = true
            } label: {
                moreLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader_tool_more")
            .accessibilityLabel(localized("更多"))
            .sheet(isPresented: $showsLegacyMoreMenu, onDismiss: runLegacyMoreChoice) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("更多"),
                        actions: [
                            DismissalSequencedAction(
                                route: MoreRoute.bookmarks,
                                title: localized("書籤"),
                                systemImage: "list.bullet.rectangle"
                            ),
                            DismissalSequencedAction(
                                route: MoreRoute.toggleBookmark,
                                title: bookmarkToggleTitle,
                                systemImage: bookmarkToggleSymbol
                            ),
                        ] + moreActions.map { action in
                            DismissalSequencedAction(
                                route: MoreRoute.action(action.id),
                                title: action.label,
                                systemImage: action.icon,
                                subtitle: action.isLocked ? localized("需要 Pro") : nil
                            )
                        },
                        onSelect: { legacyMoreSequence.select($0) }
                    )
                }
            }
        } else {
            Menu {
                Button(action: onOpenBookmarks) {
                    Label(localized("書籤"), systemImage: "list.bullet.rectangle")
                }
                Button(action: onToggleBookmark) {
                    Label(bookmarkToggleTitle, systemImage: bookmarkToggleSymbol)
                }
                if !moreActions.isEmpty {
                    Section {
                        ForEach(moreActions) { action in
                            Button(action: action.action) {
                                Label {
                                    Text(action.label)
                                    // Without Pro the tap opens the paywall; the menu says so.
                                    if action.isLocked {
                                        Text(localized("需要 Pro"))
                                    }
                                } icon: {
                                    moreActionIcon(action)
                                }
                            }
                            .accessibilityIdentifier("reader_more_\(action.id.rawValue)")
                        }
                    }
                }
            } label: {
                moreLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reader_tool_more")
            .accessibilityLabel(localized("更多"))
        }
    }

    private var moreLabel: some View {
        toolLabel(localized("更多")) {
            Image(systemName: "ellipsis")
                .imageScale(.large)
                .foregroundStyle(palette.bottomIcon)
        }
    }

    /// The icon 自定義 imported for the action, else its symbol.
    @ViewBuilder
    private func moreActionIcon(_ action: ReaderSecondaryAction) -> some View {
        if let item = ReaderChromeActionItem(action.id),
           let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
        } else {
            Image(systemName: action.icon)
        }
    }

    private func runLegacyMoreChoice() {
        switch legacyMoreSequence.consumeAfterDismissal() {
        case .bookmarks: onOpenBookmarks()
        case .toggleBookmark: onToggleBookmark()
        case .action(let id): moreActions.first { $0.id == id }?.action()
        case nil: break
        }
    }

    /// The bubble that follows the slider while scrubbing, showing where a release
    /// would land.
    private var scrubPreview: some View {
        VStack(spacing: DSSpacing.xs) {
            Text(progressPercentText)
                .font(DSFont.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(chapterTitleForProgress(sliderProgress))
                .font(DSFont.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, DSSpacing.md)
        .floatingSurface(in: Capsule(), fill: palette.bottomFill)
        .allowsHitTesting(false)
        .transition(.opacity.animation(DSAnimation.fast))
        .offset(y: -72)
    }
}

/// `GlassEffectContainer` on iOS 26, so the two capsules render as one glass layer.
/// Before iOS 26 there is no glass to group.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#Preview("Modern Bottom Control Bar") {
    @Previewable @State var theme: ReaderTheme = .white

    ZStack {
        theme.backgroundColor.ignoresSafeArea()

        Text(String(repeating: "正文墊在浮動底欄後面，檢查是否穿透。", count: 24))
            .font(DSFont.fixed(size: 17))
            .foregroundColor(theme.textColor)
            .padding(20)

        ReaderModernBottomControlBar(
            readerTheme: theme,
            overlayContentMaxWidth: .infinity,
            canGoPrevChapter: true,
            canGoNextChapter: true,
            progressText: "12 / 28 頁 · 全書 6%",
            chapterSliderProgressValue: { 0.43 },
            applyChapterSliderProgress: { _ in },
            chapterTitleForProgress: { _ in "第五回" },
            isCurrentPageBookmarked: false,
            onPrevChapter: {},
            onNextChapter: {},
            onOpenTOC: {},
            onOpenSettings: {},
            onListen: {},
            onToggleDarkMode: {},
            onOpenBookmarks: {},
            onToggleBookmark: {},
            moreActions: [
                ReaderSecondaryAction(id: .aiAssistant, icon: "sparkles", label: "AI 助手", isLocked: true, action: {}),
                ReaderSecondaryAction(id: .translation, icon: "translate", label: "AI 翻譯", isLocked: true, action: {})
            ]
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
