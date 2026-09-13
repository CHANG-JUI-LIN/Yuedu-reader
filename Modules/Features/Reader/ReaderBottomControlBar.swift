import SwiftUI

// MARK: - Slider centreline alignment

/// Lets 上一章／下一章 line up with the progress slider itself rather than with the
/// column that also carries the 「4/12 · 25.60%」 line beneath it.
///
/// The default resolves to the view's own centre, so only the slider has to declare
/// the guide explicitly; every other child of the row keeps behaving as it did under
/// `.center`.
private enum ReaderSliderCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let readerSliderCenter = VerticalAlignment(ReaderSliderCenterAlignment.self)
}

struct ReaderBottomControlBar: View {
    @Binding var readerTheme: ReaderTheme
    let overlayContentMaxWidth: CGFloat
    let showRefreshButton: Bool
    let showChangeSourceButton: Bool
    let showDownloadButton: Bool
    let downloadButtonIcon: String
    let canGoPrevChapter: Bool
    let canGoNextChapter: Bool
    let chapterPageInfo: String
    let totalProgressPercent: String
    let chapterSliderProgressValue: () -> Double
    let applyChapterSliderProgress: (Double) -> Void
    let chapterTitleForProgress: (Double) -> String
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onRefresh: () -> Void
    let onOpenChangeSource: () -> Void
    let onDownloadAction: () -> Void
    let onOpenTTS: () -> Void
    let onOpenAIAssistant: () -> Void
    let onOpenTOC: () -> Void
    let onOpenBookmarks: () -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var settings = GlobalSettings.shared

    @State private var chapterSliderDraft: Double? = nil

    private let feedbackDuration: Double = 0.25

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 12) {
                Spacer()
                if showRefreshButton, settings.isReaderChromeItemVisible(ReaderChromeActionItem.refresh) {
                    circleBtn(item: .refresh, label: localized("刷新")) { onRefresh() }
                }
                if showChangeSourceButton, settings.isReaderChromeItemVisible(ReaderChromeActionItem.changeSource) {
                    circleBtn(item: .changeSource, label: localized("換源")) {
                        onOpenChangeSource()
                    }
                }
                if showDownloadButton, settings.isReaderChromeItemVisible(ReaderChromeActionItem.download) {
                    circleBtn(item: .download, label: localized("下載")) { onDownloadAction() }
                }
                if settings.isReaderChromeItemVisible(ReaderChromeActionItem.playback) {
                    circleBtn(item: .playback, label: localized("聽書")) { onOpenTTS() }
                }
                // This row is hand-written rather than built from `readerSecondaryActions`,
                // which is why adding the action alone left 經典 with no way in at all — the
                // button only ever appeared on 現代's book card.
                if settings.isReaderChromeItemVisible(ReaderChromeActionItem.aiAssistant) {
                    circleBtn(item: .aiAssistant, label: localized("AI 助手")) { onOpenAIAssistant() }
                }
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)

            VStack {
                VStack(spacing: 0) {
                    Divider().opacity(0.18)
                    progressSliderRow
                    Divider().opacity(0.1)
                    toolRow
                }
                .frame(maxWidth: overlayContentMaxWidth)
            }
            .background(palette.bottomFill)
            .overlay(alignment: .top) {
                if let draft = chapterSliderDraft {
                    VStack(spacing: 4) {
                        Text(String(format: "%.0f%%", draft * 100))
                            .font(DSFont.fixed(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text(chapterTitleForProgress(draft))
                            .font(DSFont.fixed(size: 15, weight: .regular))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.62))
                            .background(Capsule().fill(.ultraThinMaterial))
                    )
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    .offset(y: -72)
                }
            }
            .animation(.easeOut(duration: 0.15), value: chapterSliderDraft == nil)
        }
    }

    private var palette: ReaderChromePalette {
        ReaderChromePalette(interface: .classic, theme: readerTheme, settings: settings)
    }

    private var isNightTheme: Bool { readerTheme == .night }

    /// A floating secondary action, sitting directly on top of the CoreText page —
    /// unlike the tool row below, it has no bar behind it. The fill must therefore stay
    /// opaque: with `Color.clear` the body text (and 段評 bubbles) showed straight
    /// through the circles and the icons were unreadable against any paragraph behind
    /// them. The default fill (`barColor`) matches the control bar underneath, so the
    /// row reads as one piece of chrome; an override from 自定義 replaces it wholesale
    /// — see `ReaderClassicChromePalette`.
    ///
    /// That is also why this takes 光暈 alone rather than the full `floatingSurface`:
    /// letting 毛玻璃 reach these circles would put the body text back behind the icons.
    @ViewBuilder
    private func circleBtn(item: ReaderChromeActionItem, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleGlyph(for: item)
                .frame(width: 40, height: 40)
                .background(palette.circleFill, in: Circle())
                .interfaceGlow(in: Circle())
                .overlay(Circle().stroke(palette.circleBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                // The symbol stayed a focusable element of its own next to the button, so
                // VoiceOver read 「換源」 out as "arrow.left.and.right" — the button's label
                // never won. The icon is decorative here: the name lives on the Button.
                // docs/design.md §7.1, second trap.
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint.
    @ViewBuilder
    private func circleGlyph(for item: ReaderChromeActionItem) -> some View {
        if let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: item == .download ? downloadButtonIcon : item.defaultSystemImage)
                .font(DSFont.fixed(size: 18))
                .foregroundColor(palette.circleIcon)
        }
    }

    /// The one source for both the printed progress line and the slider's VoiceOver value.
    private var progressStatusText: String {
        "\(chapterPageInfo)  ·  \(totalProgressPercent)"
    }

    private var progressSliderRow: some View {
        HStack(alignment: .readerSliderCenter, spacing: 4) {
            Button {
                onPrevChapter()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(DSFont.fixed(size: 12))
                        .accessibilityHidden(true)
                    Text(localized("上一章")).font(DSFont.fixed(size: 14))
                }
                .foregroundColor(
                    canGoPrevChapter ? palette.bottomIcon : palette.bottomIcon.opacity(0.22)
                )
                .padding(.leading, 14).padding(.vertical, 18)
            }
            .disabled(!canGoPrevChapter)
            .accessibilityLabel(localized("上一章"))

            VStack(spacing: 2) {
                Slider(
                    value: Binding<Double>(
                        get: { chapterSliderDraft ?? chapterSliderProgressValue() },
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
                ).accentColor(palette.bottomAccent)
                // 上一章／下一章 line up with the slider's own centreline, not with the
                // centre of the column that also holds the progress line underneath it.
                // Without this the two buttons sit half a line low, because the HStack
                // centres them on the whole VStack. Custom alignment guides propagate up
                // out of nested stacks, so declaring it here is enough — the buttons take
                // the AlignmentID's default, which is their own centre.
                .alignmentGuide(.readerSliderCenter) { $0[VerticalAlignment.center] }
                // A bare Slider announces a percentage of its 0…1 range and no name at all
                // (docs/design.md §7.1, third trap). Value shares `progressStatusText` with
                // the line printed underneath so the two can't drift apart.
                .accessibilityLabel(localized("閱讀進度"))
                .accessibilityValue(progressStatusText)

                Text(progressStatusText)
                    .font(DSFont.fixed(size: 10).monospacedDigit())
                    .foregroundColor(palette.bottomIcon.opacity(0.4))
                    .accessibilityHidden(true)   // 已由滑桿的 value 念出
            }.padding(.horizontal, 6)

            Button {
                onNextChapter()
            } label: {
                HStack(spacing: 3) {
                    Text(localized(canGoNextChapter ? "下一章" : "書末頁")).font(DSFont.fixed(size: 14))
                    Image(systemName: "chevron.right").font(DSFont.fixed(size: 12))
                        .accessibilityHidden(true)
                }
                .foregroundColor(
                    canGoNextChapter ? palette.bottomIcon : palette.bottomIcon.opacity(0.22)
                )
                .padding(.trailing, 14).padding(.vertical, 18)
            }
            .disabled(!canGoNextChapter)
            .accessibilityLabel(localized(canGoNextChapter ? "下一章" : "書末頁"))
        }
        .background(palette.bottomFill)
    }

    /// Driven by 自定義's visibility list rather than four hardcoded calls, so a
    /// hidden button leaves the row entirely instead of sitting there disabled.
    /// The list is sanitized on write and always follows `allCases` order, so this
    /// cannot reshuffle the row.
    private var toolRow: some View {
        HStack(spacing: 0) {
            ForEach(settings.visibleReaderChromeToolItems) { item in
                toolButton(for: item)
            }
        }
        .padding(.top, 2).padding(.bottom, 14)
        .background(palette.bottomFill)
    }

    @ViewBuilder
    private func toolButton(for item: ReaderChromeToolItem) -> some View {
        switch item {
        case .tableOfContents:
            toolBtn(item: item, label: localized("目錄")) { onOpenTOC() }
        case .bookmarks:
            toolBtn(item: item, label: localized("書籤")) { onOpenBookmarks() }
        case .nightMode:
            toolBtn(
                item: item,
                label: localized(isNightTheme ? "白天" : "深色"),
                active: isNightTheme
            ) {
                toggleNightTheme()
            }
        case .settings:
            toolBtn(item: item, label: localized("設置")) { onOpenSettings() }
        }
    }

    private func toggleNightTheme() {
        withAnimation(.easeInOut(duration: feedbackDuration)) {
            if isNightTheme {
                let saved = UserDefaults.standard.string(forKey: "lastLightTheme") ?? ReaderTheme.white.rawValue
                readerTheme = ReaderTheme(rawValue: saved) ?? .white
            } else {
                UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                readerTheme = .night
            }
        }
    }

    @ViewBuilder
    private func toolBtn(
        item: ReaderChromeToolItem, label: String, active: Bool = false, badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    toolGlyph(for: item)
                        .accessibilityHidden(true)   // 名稱在按鈕上，符號名不進旁白
                    if let count = badge, count > 0 {
                        Text("\(count)")
                            .font(DSFont.fixed(size: 9, weight: .semibold))
                            .foregroundColor(.white).padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .offset(x: 10, y: -4)
                    }
                }
                Text(label).font(DSFont.fixed(size: 10))
            }
            .foregroundColor(active ? palette.bottomAccent : palette.bottomIcon.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label)
        .accessibilityValue(badge.map { "\($0)" } ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// An imported icon is drawn in its own colours — it is artwork the reader
    /// chose, not a symbol to tint. Only the fallback SF Symbol inherits the row's
    /// `foregroundColor`, which is why the label under it still recolors either way.
    @ViewBuilder
    private func toolGlyph(for item: ReaderChromeToolItem) -> some View {
        if let custom = settings.readerChromeIconImage(for: item) {
            Image(uiImage: custom)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: item.systemImage(isNight: isNightTheme))
                .font(DSFont.fixed(size: 20))
        }
    }
}

// Page text sits behind the floating circle buttons on purpose: that is the case where
// a transparent fill made them unreadable.
#Preview("Classic Bottom Control Bar") {
    @Previewable @State var theme: ReaderTheme = .sepia

    ZStack {
        theme.backgroundColor.ignoresSafeArea()

        Text(String(repeating: "書頁正文擋在浮動按鈕後面，檢查按鈕是否仍清楚可辨。", count: 12))
            .font(DSFont.fixed(size: 17))
            .foregroundColor(theme.textColor)
            .padding(24)

        ReaderBottomControlBar(
            readerTheme: $theme,
            overlayContentMaxWidth: 520,
            showRefreshButton: true,
            showChangeSourceButton: true,
            showDownloadButton: true,
            downloadButtonIcon: "arrow.down.circle",
            canGoPrevChapter: true,
            canGoNextChapter: true,
            chapterPageInfo: "3 / 12",
            totalProgressPercent: "24%",
            chapterSliderProgressValue: { 0.24 },
            applyChapterSliderProgress: { _ in },
            chapterTitleForProgress: { _ in "第五章" },
            onPrevChapter: {},
            onNextChapter: {},
            onRefresh: {},
            onOpenChangeSource: {},
            onDownloadAction: {},
            onOpenTTS: {},
            onOpenAIAssistant: {},
            onOpenTOC: {},
            onOpenBookmarks: {},
            onOpenSettings: {}
        )
    }
}
