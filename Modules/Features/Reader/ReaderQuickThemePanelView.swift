import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ReaderQuickPageTurnOption: String, CaseIterable, Identifiable, Hashable {
    case slide
    case curl
    case fastFade
    case scroll

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .slide: return "Slide"
        case .curl: return "Curl"
        case .fastFade: return "Fast Fade"
        case .scroll: return "Scroll"
        }
    }

    var iconName: String {
        switch self {
        case .slide: return "arrow.left.square"
        case .curl: return "doc"
        case .fastFade: return "bolt.square"
        case .scroll: return "doc.plaintext"
        }
    }
}

private enum ReaderQuickThemeMode: String, CaseIterable, Identifiable, Hashable {
    case light
    case dark
    case device
    case surroundings

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .device: return "Match Device"
        case .surroundings: return "Match Surroundings"
        }
    }

    var iconName: String {
        switch self {
        case .light: return "sunrise"
        case .dark: return "moon.stars"
        case .device: return "circle.lefthalf.filled"
        case .surroundings: return "sun.max"
        }
    }
}

private enum ReadingBackgroundGridItem: Identifiable {
    case background(ReaderTheme)
    case custom

    var id: String {
        switch self {
        case .background(let background): return "background-\(background.rawValue)"
        case .custom: return "custom"
        }
    }
}

struct ReaderQuickThemePanelNavigationState: Equatable {
    private(set) var isShowingCustomBackgroundOptions = false

    mutating func showCustomBackgroundOptions() {
        isShowingCustomBackgroundOptions = true
    }

    mutating func setCustomBackgroundOptionsPresented(_ isPresented: Bool) {
        isShowingCustomBackgroundOptions = isPresented
    }

    mutating func completeBackgroundImageImport() {
        isShowingCustomBackgroundOptions = false
    }
}

struct ReaderQuickThemePanelView: View {
    @Binding var fontSize: CGFloat
    @Binding var readerTheme: ReaderTheme
    let pageTurnOption: ReaderQuickPageTurnOption
    let isVerticalWritingMode: Bool
    let onSelectPageTurnOption: (ReaderQuickPageTurnOption) -> Void
    let onCustomize: () -> Void
    let onClose: () -> Void

    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsFontSizeScale = false
    @State private var fontScaleToken = 0
    @State private var navigationState = ReaderQuickThemePanelNavigationState()
    @State private var customBackgroundColor = Color(uiColor: ReaderTheme.white.uiBackgroundColor)

    private let minFontSize: CGFloat = 12
    private let maxFontSize: CGFloat = 32
    /// Diameter of each dot in the font-size scale indicator.
    private let fontScaleDotSize: CGFloat = 5

    private var readingBackgroundPages: [[ReadingBackgroundGridItem]] {
        let items = ReaderTheme.allCases.map(ReadingBackgroundGridItem.background) + [.custom]
        return stride(from: 0, to: items.count, by: 6).map { startIndex in
            Array(items[startIndex..<min(startIndex + 6, items.count)])
        }
    }

    private var currentThemeMode: ReaderQuickThemeMode {
        if settings.readerFollowSystemTheme { return .device }
        return readerTheme == .night ? .dark : .light
    }

    private var customColorEditorInitialUIColor: UIColor {
        settings.readerCustomBackgroundMode == .color
            ? settings.readerCustomBackgroundPreviewUIColor
            : readerTheme.uiBackgroundColor
    }

    private var fontStepCount: Int { Int(maxFontSize - minFontSize) + 1 }

    private var currentFontStepIndex: Int {
        let raw = Int((fontSize - minFontSize).rounded())
        return min(max(raw, 0), fontStepCount - 1)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                topControls
                if showsFontSizeScale {
                    fontSizeScale
                        .transition(.opacity)
                }
                brightnessSlider
                readingBackgroundGrid
                customizeButton
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.top, DSSpacing.xs)
            .padding(.bottom, DSSpacing.lg)
            .frame(maxWidth: DSLayout.readableCompactWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .navigationTitle(localized("Themes & Settings"))
            .toolbarTitleDisplayMode(.inline)
            .navigationDestination(
                isPresented: Binding(
                    get: { navigationState.isShowingCustomBackgroundOptions },
                    set: { navigationState.setCustomBackgroundOptionsPresented($0) }
                )
            ) {
                ReaderCustomBackgroundOptionsView(
                    color: $customBackgroundColor,
                    onImageImported: {
                        navigationState.completeBackgroundImageImport()
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .tint(DSColor.textSecondary)
                    .accessibilityLabel(localized("關閉"))
                }
            }
        }
        .task(id: fontScaleToken) {
            guard showsFontSizeScale else { return }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(DSAnimation.standard) { showsFontSizeScale = false }
        }
    }

    // MARK: - Top controls (font size + icon menus)

    private var topControls: some View {
        HStack(spacing: DSSpacing.md) {
            fontSizeControl
            iconMenuControl
        }
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

    private var fontSizeControl: some View {
        HStack(spacing: 0) {
            fontSizeStepButton(-1, textFont: DSFont.title3.weight(.semibold), accessibilityKey: "縮小字體")

            Divider().frame(height: DSSpacing.xxl)

            fontSizeStepButton(1, textFont: DSFont.title.weight(.semibold), accessibilityKey: "放大字體")
        }
        .background(DSColor.neutralControlFill, in: Capsule())
        .shadow(color: DSColor.shadow, radius: 6, y: 1)
    }

    private var iconMenuControl: some View {
        HStack(spacing: 0) {
            pageTurnMenu
            themeModeMenu
        }
        .menuStyle(.button)
        .buttonStyle(QuickPanelSegmentButtonStyle())
        .frame(width: DSLayout.readerQuickPanelTopMenuWidth)
        .background(DSColor.neutralControlFill, in: Capsule())
        .shadow(color: DSColor.shadow, radius: 6, y: 1)
    }

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
            Image(systemName: pageTurnOption.iconName)
                .font(DSFont.title3)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("翻頁"))
    }

    private var themeModeMenu: some View {
        Menu {
            Picker(
                localized("主題模式"),
                selection: Binding(
                    get: { currentThemeMode },
                    set: { applyThemeMode($0) }
                )
            ) {
                ForEach(ReaderQuickThemeMode.allCases) { mode in
                    Label(localized(mode.titleKey), systemImage: mode.iconName)
                        .font(DSFont.body)
                        .tag(mode)
                        .disabled(mode == .surroundings)
                }
            }
        } label: {
            Image(systemName: currentThemeMode.iconName)
                .font(DSFont.title3)
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(localized("主題模式"))
    }

    /// Discrete dot scale that surfaces the current font-size step. Revealed
    /// transiently while the reader taps the A / A control, then auto-hides.
    private var fontSizeScale: some View {
        HStack(spacing: DSSpacing.xs) {
            ForEach(0..<fontStepCount, id: \.self) { index in
                Circle()
                    .fill(index <= currentFontStepIndex
                        ? DSColor.textPrimary
                        : DSColor.textPrimary.opacity(0.16))
                    .frame(width: fontScaleDotSize, height: fontScaleDotSize)
            }
            Spacer(minLength: 0)
        }
        .frame(height: DSSpacing.sm)
        .accessibilityElement()
        .accessibilityLabel(localized("字體大小"))
        .accessibilityValue("\(Int(fontSize))")
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
        .foregroundStyle(DSColor.textPrimary)
    }

    // MARK: - Reading backgrounds

    private var readingBackgroundGrid: some View {
        TabView {
            ForEach(Array(readingBackgroundPages.enumerated()), id: \.offset) { _, page in
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: 3),
                    spacing: DSSpacing.md
                ) {
                    ForEach(page) { item in
                        switch item {
                        case .background(let background):
                            readingBackgroundButton(background)
                        case .custom:
                            customReadingBackgroundButton
                        }
                    }
                }
                .padding(DSSpacing.md)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: readingBackgroundPages.count > 1 ? .automatic : .never))
        .frame(height: DSLayout.readerQuickPanelReadingBackgroundPagerHeight)
    }

    private func readingBackgroundButton(_ background: ReaderTheme) -> some View {
        let selected = settings.readerCustomBackgroundMode == .none
            && !settings.appearanceBindReaderTheme
            && readerTheme == background
        return Button {
            settings.readerFollowSystemTheme = false
            settings.appearanceBindReaderTheme = false
            settings.clearReaderCustomBackground()
            AppearanceThemePreset.activeReaderTheme = nil
            readerTheme = background
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                    .fill(background.previewBackgroundColor)

                VStack(spacing: DSSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(localized("閱讀背景預覽大字"))
                            .font(DSFont.title2.weight(settings.readerFontBold ? .bold : .regular))
                        Text(localized("閱讀背景預覽小字"))
                            .font(DSFont.subheadline.weight(settings.readerFontBold ? .bold : .regular))
                    }
                    .accessibilityHidden(true)

                    Text(background.localizedTitle)
                        .font(DSFont.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(background.previewTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if selected {
                    Image(systemName: "asterisk")
                        .font(DSFont.subheadline.weight(.semibold))
                        .foregroundStyle(background.previewTextColor.opacity(0.6))
                        .padding(.top, DSSpacing.sm)
                        .padding(.trailing, DSSpacing.md)
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
        let selected = settings.readerCustomBackgroundMode != .none
        return Button {
            customBackgroundColor = Color(uiColor: customColorEditorInitialUIColor)
            navigationState.showCustomBackgroundOptions()
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
        }
    }

    // MARK: - Customize

    private var customizeButton: some View {
        Button(action: onCustomize) {
            Label(localized("Customize"), systemImage: "gear")
        }
        .buttonStyle(QuickPanelActionButtonStyle())
    }

    // MARK: - Actions

    private func adjustFontSize(_ delta: CGFloat) {
        fontSize = min(maxFontSize, max(minFontSize, (fontSize + delta).rounded()))
        withAnimation(DSAnimation.standard) { showsFontSizeScale = true }
        fontScaleToken &+= 1
    }

    private func applyThemeMode(_ mode: ReaderQuickThemeMode) {
        settings.appearanceBindReaderTheme = false
        settings.clearReaderCustomBackground()
        AppearanceThemePreset.activeReaderTheme = nil
        switch mode {
        case .light:
            settings.readerFollowSystemTheme = false
            if readerTheme == .night {
                readerTheme = ReaderTheme.lastLightTheme
            }
        case .dark:
            settings.readerFollowSystemTheme = false
            readerTheme = .night
        case .device:
            settings.readerFollowSystemTheme = true
            readerTheme = ReaderTheme.forSystem(dark: colorScheme == .dark)
        case .surroundings:
            break
        }
    }

    private func pageTurnTitleKey(for option: ReaderQuickPageTurnOption) -> String {
        option == .scroll && isVerticalWritingMode ? "右往左" : option.titleKey
    }

}

private struct ReaderCustomBackgroundImportAlert: Identifiable {
    let id = UUID()
    let message: String
}

/// A pushed choice page avoids presenting a `confirmationDialog` above the
/// quick-settings sheet, which otherwise produces an overlapping popover on
/// the immersive reader surface.
private struct ReaderCustomBackgroundOptionsView: View {
    @Binding var color: Color
    let onImageImported: () -> Void

    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @State private var showingImageImporter = false
    @State private var importAlert: ReaderCustomBackgroundImportAlert?

    private static let imageContentTypes: [UTType] = [
        UTType(filenameExtension: "webp") ?? .data,
        UTType(filenameExtension: "jpg") ?? .jpeg,
        UTType(filenameExtension: "jpeg") ?? .jpeg,
    ]

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
                    Button {
                        showingImageImporter = true
                    } label: {
                        Label(localized("導入圖片背景"), systemImage: "photo")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                    }
                }
            } footer: {
                Text(localized("圖片會直接顯示在閱讀背景與主題預覽中。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .listRowBackground(DSColor.surface)
        }
        .font(DSFont.body)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .navigationTitle(localized("自定義閱讀背景"))
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingImageImporter,
            allowedContentTypes: Self.imageContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importBackgroundImage
        )
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized("閱讀背景匯入失敗")),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    private func importBackgroundImage(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try settings.importReaderCustomBackgroundImage(from: url)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.headline)
            .foregroundStyle(DSColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelControlHeight)
            .background(
                configuration.isPressed ? DSColor.neutralControlPressedFill : DSColor.neutralControlFill,
                in: Capsule()
            )
            .shadow(color: DSColor.shadow, radius: 6, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DSAnimation.fast, value: configuration.isPressed)
    }
}

/// Segment sharing one capsule with its neighbors (the A / A halves and the
/// two icon menus): while pressed, an inset darker capsule appears behind the
/// content; on release it shrinks and fades back out, echoing the Apple Books
/// quick panel. Highlight snaps in fast and recedes on the slower curve.
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
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .listRowBackground(DSColor.surface)
        }
        .font(DSFont.body)
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
        onCustomize: {},
        onClose: {}
    )
}
