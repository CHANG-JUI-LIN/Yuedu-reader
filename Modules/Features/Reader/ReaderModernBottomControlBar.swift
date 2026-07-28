import SwiftUI

/// The 現代 interface's bottom chrome: one floating rounded panel, inset from every
/// edge, holding the chapter line, the chapter progress slider, and the same four
/// tools 經典 offers — 目錄 / 書籤 / 深色 / 設置.
///
/// It wears the system's own glass (`readerFloatingPanel` below) so it matches the
/// toolbar controls above it without either being hand-painted.
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

    @State private var chapterSliderDraft: Double? = nil

    private let feedbackDuration: Double = 0.25

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
            .readerFloatingPanel(
                in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
            )
            .overlay(alignment: .top) {
                if chapterSliderDraft != nil {
                    scrubPreview
                }
            }
            .frame(maxWidth: overlayContentMaxWidth)
            .padding(.horizontal, DSSpacing.md)
            .padding(.bottom, DSSpacing.md)
            .tint(readerTheme.accentColor)
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
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var progressRow: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: onPrevChapter) {
                Image(systemName: "chevron.left")
                    .font(DSFont.fixed(size: 15, weight: .medium))
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
                    .opacity(canGoNextChapter ? 1 : 0.3)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNextChapter)
            .accessibilityLabel(localized(canGoNextChapter ? "下一章" : "書末頁"))
        }
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolBtn(icon: "list.bullet", label: localized("目錄"), action: onOpenTOC)
            toolBtn(icon: "bookmark", label: localized("書籤"), action: onOpenBookmarks)
            toolBtn(
                icon: readerTheme == .night ? "sun.min" : "moon",
                label: localized(readerTheme == .night ? "白天" : "深色"),
                active: readerTheme == .night
            ) {
                withAnimation(.easeInOut(duration: feedbackDuration)) {
                    if readerTheme == .night {
                        let saved = UserDefaults.standard.string(forKey: "lastLightTheme")
                            ?? ReaderTheme.white.rawValue
                        readerTheme = ReaderTheme(rawValue: saved) ?? .white
                    } else {
                        UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                        readerTheme = .night
                    }
                }
            }
            toolBtn(icon: "gearshape", label: localized("設置"), action: onOpenSettings)
        }
    }

    @ViewBuilder
    private func toolBtn(
        icon: String,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Label(label, systemImage: icon)
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                Text(label)
                    .font(DSFont.caption2)
            }
            .foregroundStyle(active ? readerTheme.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        .readerFloatingPanel(in: Capsule())
        .allowsHitTesting(false)
        .transition(.opacity.animation(.easeOut(duration: 0.15)))
        .offset(y: -72)
    }
}

extension View {
    /// The surface 現代's floating panels sit on. iOS 26 has the real thing —
    /// `glassEffect`, the same material the toolbar controls above are made of — so
    /// the panel and the toolbar match without either being hand-painted. Older
    /// systems have no glass; `.regularMaterial` is the closest they offer.
    ///
    /// The `#if compiler` guard mirrors `RSSFeedSearchBar`: the iOS 26 API only exists
    /// in the Xcode 26 SDK, and the project still has to compile on older toolchains.
    @ViewBuilder
    func readerFloatingPanel<PanelShape: Shape>(in shape: PanelShape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #else
        background(.regularMaterial, in: shape)
        #endif
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
