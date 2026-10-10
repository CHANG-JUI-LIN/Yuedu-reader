import SwiftUI
import UIKit

enum ReaderQuickPageTurnOption: String, CaseIterable, Identifiable, Hashable {
    case slide
    case cover
    case curl
    case fastFade
    case scroll

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .slide: return "Slide"
        case .cover: return "覆蓋翻頁"
        case .curl: return "Curl"
        case .fastFade: return "Fast Fade"
        case .scroll: return "Scroll"
        }
    }

    var iconName: String {
        switch self {
        case .slide: return "arrow.left.square"
        case .cover: return "square.on.square"
        case .curl: return "doc"
        case .fastFade: return "bolt.square"
        case .scroll: return "doc.plaintext"
        }
    }
}

/// Which saved-background page the quick panel has pushed.
enum ReaderBackgroundEditorRoute: Hashable {
    case new
    case edit(UUID)

    var backgroundID: UUID? {
        if case .edit(let id) = self { return id }
        return nil
    }
}

struct ReaderQuickThemePanelView: View {
    @Binding var fontSize: CGFloat
    @Binding var readerTheme: ReaderTheme
    let pageTurnOption: ReaderQuickPageTurnOption
    let isVerticalWritingMode: Bool
    let onSelectPageTurnOption: (ReaderQuickPageTurnOption) -> Void
    /// Enters auto-read mode and puts every surface away. It is only an entry:
    /// once running, the footer pill is the single route to the speed and the exit.
    let onStartAutoRead: () -> Void
    let onCustomize: () -> Void
    /// A locked control asked for the paywall. The reader closes this sheet and presents
    /// it from its own `onDismiss`, as it does for 自訂 — never a sheet on top of this one.
    var onOpenPaywall: ((PremiumFeature) -> Void)? = nil

    @Bindable private var settings = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    /// The saved-background page pushed in this panel's own navigation.
    @State private var backgroundEditor: ReaderBackgroundEditorRoute?
    /// Measured height of the panel's own content, so the sheet is exactly as tall
    /// as what it holds. A fixed detent left a band of dead space under the last
    /// row whenever the content came out shorter than the constant.
    @State private var contentHeight = DSLayout.readerQuickPanelSheetHeight
    @State private var bottomSafeAreaInset: CGFloat = 0

    private let minFontSize = GlobalSettings.readerFontSizeRange.lowerBound
    private let maxFontSize = GlobalSettings.readerFontSizeRange.upperBound

    var body: some View {
        NavigationStack {
            // Scrolls rather than clips. The panel is no longer a fixed 508pt of
            // which 214 went to a background pager that only ever had one page, so
            // its height follows its content — and at the largest Dynamic Type
            // sizes that content is taller than any detent.
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    typeAndPageTurnRow
                    brightnessSlider
                    readingBackgroundRow
                        .padding(.bottom, DSSpacing.lg)
                    // Only under 綁定閱讀主題: without it the reader follows the device by
                    // itself and there is nothing to switch (the user's call, 2026-09-30).
                    if settings.appearanceBindReaderTheme {
                        followSystemAppearanceToggle
                    }
                    quickActionRow
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.top, DSSpacing.xl)
                .padding(.bottom, DSSpacing.xl)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ReaderQuickPanelContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .softScrollEdges()
            .onPreferenceChange(ReaderQuickPanelContentHeightKey.self) { height in
                guard height > 0 else { return }
                contentHeight = height
            }
            .scrollBounceBehavior(.basedOnSize)
            // This panel supplies its own bottom padding. Let the scroll viewport
            // use the whole sheet instead of reserving another home-indicator band.
            .ignoresSafeArea(.container, edges: .bottom)
            .frame(maxWidth: DSLayout.readableCompactWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .pageBackgroundToolbar(for: .settings)
            // No title bar and no close button: the panel is a short sheet the
            // reader flicks away, and a navigation chrome on top of it ate height
            // the controls could use.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $backgroundEditor) { route in
                ReaderCustomBackgroundEditorView(
                    original: route.backgroundID.flatMap(settings.readerCustomBackground(id:)),
                    onSave: { saved in
                        // A new one is made to be worn; an edit leaves what is worn alone,
                        // and the reader repaints if it was this one.
                        if route == .new {
                            wear(saved)
                        }
                        backgroundEditor = nil
                    },
                    onDelete: { backgroundEditor = nil },
                    onRequestPaywall: { onOpenPaywall?($0) }
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReaderQuickPanelSafeAreaBottomKey.self,
                    value: proxy.safeAreaInsets.bottom
                )
            }
        }
        .onPreferenceChange(ReaderQuickPanelSafeAreaBottomKey.self) {
            bottomSafeAreaInset = $0
        }
        // The grabber is the only way out now that the title bar is gone, so the
        // sheet must stay draggable and the indicator visible.
        // A height detent excludes the bottom safe area, which UIKit adds back.
        // Our measurement already includes the panel's complete bottom padding.
        // The saved-background page is a whole form, not a row of controls: the panel
        // opens to full height while it is up, and goes back to fitting its content.
        .presentationDetents(backgroundEditor == nil
            ? [.height(max(DSLayout.minimumTapTarget, contentHeight - bottomSafeAreaInset))]
            : [.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 字級 + 翻頁

    /// One row for the two things a reader reaches for mid-page. They used to sit
    /// apart with the page-turn style behind an icon-only `Menu` — a glyph that
    /// never said which style was active.
    private var typeAndPageTurnRow: some View {
        HStack(spacing: DSSpacing.md) {
            fontSizeStepper
            pageTurnMenu
                .frame(width: DSLayout.readerQuickPanelTopMenuWidth)
        }
    }

    /// 小 A ── 現在的字級 ── 大 A, in one capsule.
    ///
    /// The size used to be reported by a row of dots under this control that
    /// faded out after 1.8 seconds — it was gone by the time anyone looked for it,
    /// and its appearing and disappearing made the panel change height. The number
    /// now sits between the two buttons that change it and never moves.
    ///
    /// Both ends keep `.buttonRepeatBehavior(.enabled)`, so press-and-hold keeps
    /// stepping.
    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            fontSizeStepButton(
                -1,
                textFont: DSFont.body.weight(.semibold),
                accessibilityKey: "縮小字體"
            )

            Text("\(Int(fontSize))")
                .font(DSFont.title3.weight(.medium).monospacedDigit())
                .foregroundStyle(DSColor.textPrimary)
                .frame(minWidth: DSSpacing.xxl)
                // The stepper is one control with one value; the buttons carry
                // their own labels, so the number would only repeat what VoiceOver
                // already announces when the value changes.
                .accessibilityHidden(true)

            fontSizeStepButton(
                1,
                textFont: DSFont.title2.weight(.semibold),
                accessibilityKey: "放大字體"
            )
        }
        .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
        .background(DSColor.neutralControlFill, in: Capsule())
        .shadow(color: DSColor.shadow, radius: 6, y: 1)
    }

    /// A `Menu` behind a capsule button.
    ///
    /// The menu is the stock control for picking one of several styles; what
    /// changed from the icon-only version is the label — it now says which style
    /// is active, so the reader does not have to open it to find out.
    private var pageTurnMenu: some View {
        Menu {
            Picker(
                localized("翻頁"),
                selection: Binding(
                    get: { pageTurnOption },
                    set: { onSelectPageTurnOption($0) }
                )
            ) {
                ForEach(ReaderQuickPageTurnOption.allCases) { option in
                    Label(
                        localized(pageTurnTitleKey(for: option)),
                        systemImage: option.iconName
                    )
                    .font(DSFont.body)
                    .tag(option)
                }
            }
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(localized(pageTurnTitleKey(for: pageTurnOption)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(DSFont.footnote)
                    .accessibilityHidden(true)
            }
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textPrimary)
            .padding(.horizontal, DSSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
            .background(DSColor.neutralControlFill, in: Capsule())
            .shadow(color: DSColor.shadow, radius: 6, y: 1)
            .contentShape(Capsule())
        }
        .accessibilityLabel(localized("翻頁"))
        .accessibilityValue(localized(pageTurnTitleKey(for: pageTurnOption)))
    }

    /// One half of the A / A stepper. `.buttonRepeatBehavior(.enabled)` makes
    /// press-and-hold keep stepping, matching Apple Books.
    private func fontSizeStepButton(_ delta: CGFloat, textFont: Font, accessibilityKey: String) -> some View {
        Button {
            adjustFontSize(delta)
        } label: {
            Text("A")
                .font(textFont)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickPanelSegmentButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(localized(accessibilityKey))
    }

    // MARK: - Brightness

    private var brightnessSlider: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: "sun.min.fill")
                .font(DSFont.body)
            Slider(
                value: Binding(
                    get: { CGFloat(settings.readerBrightness) },
                    set: { value in
                        settings.followSystemBrightness = false
                        settings.readerBrightness = Double(value)
                        UIScreen.main.brightness = value
                    }
                ),
                in: 0.05...1.0
            )
            .tint(DSColor.textPrimary)
            Image(systemName: "sun.max.fill")
                .font(DSFont.body)
        }
        .frame(minHeight: DSLayout.minimumTapTarget)
        .foregroundStyle(DSColor.textPrimary)
    }

    // MARK: - Reading backgrounds

    /// One scrolling row, not the 3×2 paged grid this replaced: the four built-in
    /// backgrounds, then every saved one, each by name, then 自定義 to make another.
    private var readingBackgroundRow: some View {
        let resolution = settings.readerBackgroundResolution(mode: settings.readerMode, wornTheme: readerTheme)
        return VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("閱讀背景"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DSSpacing.md) {
                    ForEach(ReaderTheme.allCases, id: \.self) { background in
                        readingBackgroundButton(background, resolution: resolution)
                            .frame(width: DSLayout.readerQuickPanelBackgroundTileWidth)
                    }
                    ForEach(settings.readerCustomBackgrounds) { background in
                        savedBackgroundButton(background, resolution: resolution)
                            .frame(width: DSLayout.readerQuickPanelBackgroundTileWidth)
                    }
                    newBackgroundButton
                        .frame(width: DSLayout.readerQuickPanelBackgroundTileWidth)
                }
                .padding(.vertical, DSSpacing.xs)
                .padding(.horizontal, 2)
            }
        }
    }

    /// Whether the reader's dark mode keeps to the device's appearance, where the two
    /// picks of 綁定閱讀主題 are worn. Off to start with; switching the reader against
    /// the device by hand turns it back off, since the two cannot both hold.
    private var followSystemAppearanceToggle: some View {
        Toggle(
            localized("跟隨裝置深淺色"),
            isOn: Binding(
                get: { settings.readerFollowSystemTheme },
                set: { applyFollowSystemAppearance($0) }
            )
        )
        .font(DSFont.body)
        .foregroundStyle(DSColor.textPrimary)
    }

    private func readingBackgroundButton(
        _ background: ReaderTheme,
        resolution: ReaderBackgroundResolution
    ) -> some View {
        // While the page is painted by 跟隨外觀主題 or by a saved background — a dark one
        // sits on 黑色 — no built-in one is the one in effect.
        let selected = !resolution.paintsWithAppearanceTheme
            && resolution.customBackground == nil
            && resolution.theme == background
        return Button {
            settings.appearanceBindReaderTheme = false
            settings.setReaderDarkMode(background == .night, deviceIsDark: colorScheme == .dark)
            // 黑色 is the reader's dark mode; the saved background stays the light mode's
            // and comes back with it. A light built-in one takes its place there.
            if background != .night {
                settings.readerCustomBackgroundID = nil
            }
            readerTheme = background
        } label: {
            backgroundTile(
                fill: background.previewBackgroundColor,
                image: nil,
                title: background.localizedTitle,
                titleColor: background.previewTextColor,
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(background.localizedTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func savedBackgroundButton(
        _ background: ReaderCustomBackground,
        resolution: ReaderBackgroundResolution
    ) -> some View {
        let selected = resolution.customBackground?.id == background.id
        return Button {
            wear(background)
        } label: {
            backgroundTile(
                fill: Color(uiColor: AppearanceThemePreset.hex(background.colorHex)),
                image: background.imageFileName.flatMap(ReaderCustomBackgroundStorageManager.shared.thumbnail(fileName:)),
                title: background.name,
                titleColor: Color(uiColor: AppearanceThemePreset.hex(background.resolvedTextColorHex)),
                selected: selected
            )
        }
        .buttonStyle(.plain)
        // Plain buttons only, as on the theme grid: the delete confirmation is a submenu
        // because a modal raised from a context-menu action can be dropped on iOS 17
        // (Technotes/iOS17MenuModalPresentation.md).
        .contextMenu {
            Button {
                backgroundEditor = .edit(background.id)
            } label: {
                Label(localized("編輯"), systemImage: "slider.horizontal.3")
            }
            Menu {
                Button(role: .destructive) {
                    settings.deleteReaderCustomBackground(id: background.id)
                } label: {
                    Label(String(format: localized("刪除「%@」"), background.name), systemImage: "trash")
                }
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
        }
        .accessibilityLabel(background.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: localized("編輯")) {
            backgroundEditor = .edit(background.id)
        }
    }

    private var newBackgroundButton: some View {
        Button {
            backgroundEditor = .new
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .fill(DSColor.neutralControlFill)
                VStack(spacing: DSSpacing.xs) {
                    Image(systemName: "plus")
                        .font(DSFont.title2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(localized("自定義"))
                        .font(DSFont.subheadline)
                }
                .foregroundStyle(DSColor.textPrimary)
            }
            .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .stroke(DSColor.separator, lineWidth: 1)
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("自定義"))
    }

    /// One background's tile: its colour or picture, its name, and the selection ring.
    /// Built-in and saved ones alike carry the name — only the saved ones did at first,
    /// which left the built-in half of the row unnamed (2026-09-29).
    private func backgroundTile(
        fill: Color,
        image: UIImage?,
        title: String,
        titleColor: Color,
        selected: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                .fill(fill)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight)
                    .clipped()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            Text(title)
                .font(DSFont.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(titleColor)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.bottom, DSSpacing.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityHidden(true)

            if selected {
                Image(systemName: "asterisk")
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor.opacity(0.6))
                    .padding(.top, DSSpacing.sm)
                    .padding(.trailing, DSSpacing.md)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                .stroke(
                    selected ? DSColor.textPrimary : DSColor.separator,
                    lineWidth: selected ? 3 : 1
                )
        )
        .shadow(color: DSColor.shadow, radius: 6, y: 1)
    }

    // MARK: - 快捷動作

    /// The space the background pager gave back.
    ///
    /// 自動閱讀 comes first — that is where every reader that ships this feature
    /// puts it, and until now this app had no entry for it at all: the controller
    /// and its panel were both complete, but nothing ever set `showAutoReadPanel`.
    private var quickActionRow: some View {
        HStack(spacing: DSSpacing.md) {
            Button {
                onStartAutoRead()
            } label: {
                Label(localized("自動閱讀"), systemImage: "play.fill")
            }
            .buttonStyle(QuickPanelActionButtonStyle())

            Button(action: onCustomize) {
                Label(localized("Customize"), systemImage: "gear")
            }
            .buttonStyle(QuickPanelActionButtonStyle())
        }
    }

    // MARK: - Actions

    private func adjustFontSize(_ delta: CGFloat) {
        fontSize = GlobalSettings.clampedReaderFontSize((fontSize + delta).rounded())
    }

    /// Turning it on hands the reader's mode to the device; turning it off keeps whatever
    /// is on screen. The reader puts the background of the mode in place.
    private func applyFollowSystemAppearance(_ isOn: Bool) {
        settings.setReaderFollowsDevice(isOn, deviceIsDark: colorScheme == .dark)
    }

    /// A saved background, worn as the reader's own pick: the light mode's background.
    private func wear(_ background: ReaderCustomBackground) {
        readerTheme = settings.wearReaderCustomBackground(
            background,
            over: readerTheme,
            deviceIsDark: colorScheme == .dark
        )
    }

    private func pageTurnTitleKey(for option: ReaderQuickPageTurnOption) -> String {
        option == .scroll && isVerticalWritingMode ? "右往左" : option.titleKey
    }


}

/// Full-width quick-panel action button: darkens and gently compresses while
/// pressed, then springs back on release.
private struct QuickPanelActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Filled with the accent while auto-read is running, so the panel says what
    /// state the reader is in without a second row of text.
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.headline)
            .foregroundStyle(isProminent ? DSColor.textOnAccent : DSColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelControlHeight)
            .background(
                isProminent
                    ? DSColor.accent.opacity(configuration.isPressed ? 0.8 : 1)
                    : (configuration.isPressed ? DSColor.neutralControlPressedFill : DSColor.neutralControlFill),
                in: Capsule()
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DSAnimation.fast, value: configuration.isPressed)
    }
}

/// Segment sharing one capsule with its neighbor in the A / A control. While
/// pressed, an inset darker capsule appears behind the content; on release it
/// shrinks and fades back out, echoing the Apple Books quick panel.
private struct QuickPanelSegmentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(DSColor.neutralControlPressedFill)
                    .padding(DSSpacing.xs)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(configuration.isPressed || reduceMotion ? 1 : 0.85)
            )
            .animation(
                configuration.isPressed ? DSAnimation.fast : DSAnimation.standard,
                value: configuration.isPressed
            )
    }
}

#Preview() {
    ReaderQuickThemePanelView(
        fontSize: .constant(18),
        readerTheme: .constant(.white),
        pageTurnOption: .curl,
        isVerticalWritingMode: false,
        onSelectPageTurnOption: { _ in },
        onStartAutoRead: {},
        onCustomize: {}
    )
}
