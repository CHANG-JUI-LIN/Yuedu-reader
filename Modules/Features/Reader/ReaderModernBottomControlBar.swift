import SwiftUI

/// The 現代 interface's bottom chrome: one floating rounded panel, inset from every
/// edge, holding the chapter line, the chapter progress slider, and the same four
/// tools 經典 offers — 目錄 / 書籤 / 深色 / 設置.
///
/// It wears the shared 界面效果 surface (`floatingSurface`), which on iOS 26 is the
/// system's own glass — so it matches the toolbar controls above it without either
/// being hand-painted, and follows 外觀主題 › 界面效果 like every other floating element.
///
/// The book-scoped actions (刷新 / 換源 / 下載 / 聽書) are deliberately *not* here;
/// 現代 puts them in `ReaderModernBookCard` behind the cover thumbnail.
struct ReaderModernBottomControlBar: View {
    @Binding var readerTheme: ReaderTheme
    let overlayContentMaxWidth: CGFloat
    let canGoPrevChapter: Bool
    let canGoNextChapter: Bool
    let chapterTitle: String
    let chapterPageInfo: String
    let chapterSliderProgressValue: () -> Double
    let applyChapterSliderProgress: (Double) -> Void
    let chapterTitleForProgress: (Double) -> String
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onOpenTOC: () -> Void
    let onOpenBookmarks: () -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var settings = GlobalSettings.shared

    @State private var chapterSliderDraft: Double? = nil

    private let feedbackDuration: Double = 0.25

    private var palette: ReaderChromePalette {
        ReaderChromePalette(interface: .modern, theme: readerTheme, settings: settings)
    }

    private var isNightTheme: Bool { readerTheme == .night }

    private var sliderProgress: Double {
        chapterSliderDraft ?? chapterSliderProgressValue()
    }

    private var progressPercentText: String {
        String(format: "%.0f%%", sliderProgress * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: DSSpacing.sm) {
                chapterLine
                progressRow
                toolRow
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.md)
            .floatingSurface(
                in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous),
                fill: palette.bottomFill
            )
            .overlay(alignment: .top) {
                if chapterSliderDraft != nil {
                    scrubPreview
                }
            }
            .frame(maxWidth: overlayContentMaxWidth)
            .padding(.horizontal, DSSpacing.md)
            .padding(.bottom, DSSpacing.md)
            .tint(palette.bottomAccent)
            .animation(.easeOut(duration: 0.15), value: chapterSliderDraft == nil)
        }
    }

    private var chapterLine: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(chapterTitle)
                .font(DSFont.footnote)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(chapterPageInfo)
                .font(DSFont.footnote.monospacedDigit())
        }
        .foregroundStyle(palette.bottomIcon.opacity(0.62))
        .accessibilityElement(children: .combine)
    }

    private var progressRow: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onPrevChapter) {
                Image(systemName: "chevron.left")
                    .font(DSFont.fixed(size: 15, weight: .medium))
                    .foregroundStyle(palette.bottomIcon)
                    // Explicit, not left to the button style: `.plain` does not reliably
                    // dim a disabled label, and at a chapter boundary the arrow has to
                    // read as unavailable.
                    .opacity(canGoPrevChapter ? 1 : 0.3)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevChapter)
            .accessibilityLabel(localized("上一章"))

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
            .accessibilityLabel(localized("閱讀進度"))
            .accessibilityValue(progressPercentText)

            Button(action: onNextChapter) {
                Image(systemName: "chevron.right")
                    .font(DSFont.fixed(size: 15, weight: .medium))
                    .foregroundStyle(palette.bottomIcon)
                    .opacity(canGoNextChapter ? 1 : 0.3)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNextChapter)
            .accessibilityLabel(localized(canGoNextChapter ? "下一章" : "書末頁"))
        }
    }

    /// Same shared list 經典 draws, so hiding 深色 or importing an icon in
    /// 自定義 applies to whichever interface is on. Order always follows
    /// `allCases`; persistence only records what is hidden.
    private var toolRow: some View {
        HStack(spacing: 0) {
            ForEach(settings.visibleReaderChromeToolItems) { item in
                toolButton(for: item)
            }
        }
    }

    @ViewBuilder
    private func toolButton(for item: ReaderChromeToolItem) -> some View {
        switch item {
        case .tableOfContents:
            toolBtn(item: item, label: localized("目錄"), action: onOpenTOC)
        case .bookmarks:
            toolBtn(item: item, label: localized("書籤"), action: onOpenBookmarks)
        case .nightMode:
            toolBtn(
                item: item,
                label: localized(isNightTheme ? "白天" : "深色"),
                active: isNightTheme,
                action: toggleNightTheme
            )
        case .settings:
            toolBtn(item: item, label: localized("設置"), action: onOpenSettings)
        }
    }

    private func toggleNightTheme() {
        withAnimation(.easeInOut(duration: feedbackDuration)) {
            if isNightTheme {
                let saved = UserDefaults.standard.string(forKey: "lastLightTheme")
                    ?? ReaderTheme.white.rawValue
                readerTheme = ReaderTheme(rawValue: saved) ?? .white
            } else {
                UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                readerTheme = .night
            }
        }
    }

    @ViewBuilder
    private func toolBtn(
        item: ReaderChromeToolItem,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                toolGlyph(for: item, active: active)
                Text(label)
                    .font(DSFont.caption2)
                    .foregroundStyle(active ? palette.bottomAccent : palette.bottomIcon)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint. Only the fallback SF Symbol takes the palette.
    @ViewBuilder
    private func toolGlyph(for item: ReaderChromeToolItem, active: Bool) -> some View {
        if let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.systemImage(isNight: isNightTheme))
                .imageScale(.large)
                .foregroundStyle(active ? palette.bottomAccent : palette.bottomIcon)
        }
    }

    /// The bubble that follows the slider while scrubbing, showing where a release
    /// would land. Same behaviour as the 經典 bar.
    private var scrubPreview: some View {
        VStack(spacing: 4) {
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
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
        .offset(y: -72)
    }
}

#Preview("Modern Bottom Control Bar") {
    @Previewable @State var theme: ReaderTheme = .sepia

    ZStack {
        theme.backgroundColor.ignoresSafeArea()

        Text(String(repeating: "正文墊在浮動底欄後面，檢查是否穿透。", count: 24))
            .font(DSFont.fixed(size: 17))
            .foregroundColor(theme.textColor)
            .padding(20)

        ReaderModernBottomControlBar(
            readerTheme: $theme,
            overlayContentMaxWidth: 640,
            canGoPrevChapter: true,
            canGoNextChapter: true,
            chapterTitle: "第四回 薄命女偏逢薄命郎 葫蘆僧亂判葫蘆案",
            chapterPageInfo: "7 / 18",
            chapterSliderProgressValue: { 0.32 },
            applyChapterSliderProgress: { _ in },
            chapterTitleForProgress: { _ in "第五回" },
            onPrevChapter: {},
            onNextChapter: {},
            onOpenTOC: {},
            onOpenBookmarks: {},
            onOpenSettings: {}
        )
    }
}
