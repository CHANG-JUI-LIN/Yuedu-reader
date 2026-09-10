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

    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCustomBackgroundOptions = false
    /// Measured height of the panel's own content, so the sheet is exactly as tall
    /// as what it holds. A fixed detent left a band of dead space under the last
    /// row whenever the content came out shorter than the constant.
    @State private var contentHeight = DSLayout.readerQuickPanelSheetHeight
    @State private var bottomSafeAreaInset: CGFloat = 0
    @State private var customBackgroundColor = Color(uiColor: ReaderTheme.white.uiBackgroundColor)

    private let minFontSize = GlobalSettings.readerFontSizeRange.lowerBound
    private let maxFontSize = GlobalSettings.readerFontSizeRange.upperBound

    private var customColorEditorInitialUIColor: UIColor {
        settings.readerCustomBackgroundMode == .color
            ? settings.readerCustomBackgroundPreviewUIColor
            : readerTheme.uiBackgroundColor
    }

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
                    followSystemAppearanceToggle
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
            .navigationDestination(
                isPresented: $showCustomBackgroundOptions
            ) {
                ReaderCustomBackgroundOptionsView(
                    color: $customBackgroundColor,
                    onImageImported: {
                        showCustomBackgroundOptions = false
                    }
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
        .presentationDetents([.height(max(
            DSLayout.minimumTapTarget,
            contentHeight - bottomSafeAreaInset
        ))])
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

    /// One scrolling row, not the 3×2 paged grid this replaced.
    ///
    /// There are five items — four backgrounds and 自定義 — and `stride(by: 6)`
    /// only ever cut one page out of them, so the pager's 214pt (42% of the whole
    /// panel) bought a page indicator that never appeared and an empty sixth cell.
    /// A row costs 82pt and scrolls if more backgrounds are ever added.
    private var readingBackgroundRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(localized("閱讀背景"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DSSpacing.md) {
                    ForEach(ReaderTheme.allCases, id: \.self) { background in
                        readingBackgroundButton(background)
                            .frame(width: DSLayout.readerQuickPanelBackgroundTileWidth)
                    }
                    customReadingBackgroundButton
                        .frame(width: DSLayout.readerQuickPanelBackgroundTileWidth)
                }
                .padding(.vertical, DSSpacing.xs)
                .padding(.horizontal, 2)
            }
        }
    }

    /// The appearance choice that used to hide behind the second icon-only menu.
    /// A `Toggle` says what it does and what state it is in without being opened;
    /// picking a background below turns it back off, which is what tapping a
    /// specific background always meant.
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

    private func readingBackgroundButton(_ background: ReaderTheme) -> some View {
        // While 綁定閱讀主題 maps this appearance to 跟隨外觀主題 the page is painted by
        // the appearance theme, so no reading background is the one in effect.
        // Any other bound pick *is* one of these backgrounds and marks it.
        let paintedByAppearanceTheme = settings.appearanceBindReaderTheme
            && settings.boundReaderTheme(for: colorScheme) == .followAppearanceTheme
        let selected = (background == .night || settings.readerCustomBackgroundMode == .none)
            && !paintedByAppearanceTheme
            && readerTheme == background
        return Button {
            settings.readerFollowSystemTheme = false
            settings.appearanceBindReaderTheme = false
            if background != .night {
                settings.clearReaderCustomBackground()
                AppearanceThemePreset.activeReaderTheme = nil
            }
            readerTheme = background
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .fill(background.previewBackgroundColor)

                if selected {
                    Image(systemName: "asterisk")
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(background.previewTextColor.opacity(0.6))
                        .padding(.top, DSSpacing.sm)
                        .padding(.trailing, DSSpacing.md)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .stroke(
                        selected ? DSColor.textPrimary : DSColor.separator,
                        lineWidth: selected ? 3 : 1
                    )
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(background.localizedTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customReadingBackgroundButton: some View {
        let selected = settings.readerCustomBackgroundMode != .none && readerTheme != .night
        return Button {
            customBackgroundColor = Color(uiColor: customColorEditorInitialUIColor)
            showCustomBackgroundOptions = true
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .fill(customReadingBackgroundBaseColor)

                customReadingBackgroundImagePreview

                VStack(spacing: DSSpacing.xs) {
                    Image(systemName: "plus")
                        .font(DSFont.title2.weight(.semibold))
                    Text(localized("自定義"))
                        .font(DSFont.subheadline)
                }
                .foregroundStyle(customReadingBackgroundTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if selected {
                    Image(systemName: "asterisk")
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(customReadingBackgroundTextColor.opacity(0.6))
                        .padding(.top, DSSpacing.sm)
                        .padding(.trailing, DSSpacing.md)
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
        .buttonStyle(.plain)
        .accessibilityLabel(localized("自定義"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customReadingBackgroundBaseColor: Color {
        settings.readerCustomBackgroundMode == .none
            ? DSColor.neutralControlFill
            : Color(uiColor: settings.readerCustomBackgroundPreviewUIColor)
    }

    private var customReadingBackgroundTextColor: Color {
        settings.readerCustomBackgroundMode == .none
            ? DSColor.textPrimary
            : Color(uiColor: settings.readerCustomBackgroundPreviewTextUIColor)
    }

    @ViewBuilder
    private var customReadingBackgroundImagePreview: some View {
        if settings.readerCustomBackgroundMode == .image,
           let url = settings.readerCustomBackgroundImageURL,
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight)
                .clipped()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
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

    /// Turning it on hands the theme to the system; turning it off keeps whatever
    /// is on screen rather than snapping to some remembered other theme, which is
    /// what the old menu's Light/Dark cases did and why it could change the page
    /// out from under you.
    private func applyFollowSystemAppearance(_ isOn: Bool) {
        settings.appearanceBindReaderTheme = false
        settings.readerFollowSystemTheme = isOn
        guard isOn else { return }
        readerTheme = ReaderTheme.forSystem(dark: colorScheme == .dark)
    }

    private func pageTurnTitleKey(for option: ReaderQuickPageTurnOption) -> String {
        option == .scroll && isVerticalWritingMode ? "右往左" : option.titleKey
    }


}

private struct ReaderCustomBackgroundImportAlert: Identifiable {
    let id = UUID()
    let message: String
}

/// A pushed choice page avoids presenting another modal choice surface above the
/// quick-settings sheet, which otherwise produces an overlapping popover on
/// the immersive reader surface.
private struct ReaderCustomBackgroundOptionsView: View {
    @Binding var color: Color
    let onImageImported: () -> Void

    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @State private var importAlert: ReaderCustomBackgroundImportAlert?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ReaderCustomBackgroundColorEditorView(
                        color: $color,
                        onApply: { color in
                            settings.applyReaderCustomBackgroundColor(UIColor(color))
                        }
                    )
                } label: {
                    Label(localized("RGB 調色"), systemImage: "paintpalette")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                }

                if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsBackgroundImageImport {
                    ImageSourcePickerButton(
                        accessibilityTitle: localized("導入圖片背景"),
                        onPick: importBackgroundImage
                    ) {
                        Label(localized("導入圖片背景"), systemImage: "photo")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                    }
                }
            } footer: {
                Text(localized("圖片會直接顯示在閱讀背景與主題預覽中。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .navigationTitle(localized("自定義閱讀背景"))
        .toolbarTitleDisplayMode(.inline)
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized("閱讀背景匯入失敗")),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    private func importBackgroundImage(_ result: Result<PickedImageSource, PickedImageError>) {
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importReaderCustomBackgroundImage(data: data)
            case .success(.file(let url)):
                try settings.importReaderCustomBackgroundImage(from: url)
            case .failure(let error):
                importAlert = ReaderCustomBackgroundImportAlert(message: localized(error.messageKey))
                return
            }
            onImageImported()
        } catch let error as ReaderCustomBackgroundStorageError {
            importAlert = ReaderCustomBackgroundImportAlert(message: localized(error.messageKey))
        } catch {
            importAlert = ReaderCustomBackgroundImportAlert(message: localized("無法匯入圖片背景。"))
        }
    }
}

/// Full-width quick-panel action button: darkens and gently compresses while
/// pressed, then springs back on release.
private struct QuickPanelActionButtonStyle: ButtonStyle {
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
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DSAnimation.fast, value: configuration.isPressed)
    }
}

/// Segment sharing one capsule with its neighbor in the A / A control. While
/// pressed, an inset darker capsule appears behind the content; on release it
/// shrinks and fades back out, echoing the Apple Books quick panel.
private struct QuickPanelSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(DSColor.neutralControlPressedFill)
                    .padding(DSSpacing.xs)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(configuration.isPressed ? 1 : 0.85)
            )
            .animation(
                configuration.isPressed ? DSAnimation.fast : DSAnimation.standard,
                value: configuration.isPressed
            )
    }
}

private struct ReaderCustomBackgroundColorEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var color: Color
    let onApply: (Color) -> Void

    var body: some View {
        Form {
            Section {
                ColorPicker(selection: $color, supportsOpacity: false) {
                    Text(localized("背景顏色"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                }
            } footer: {
                Text(localized("套用後會作為自定義閱讀背景。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .navigationTitle(localized("RGB 調色"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onApply(color)
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel(localized("完成"))
            }
        }
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
