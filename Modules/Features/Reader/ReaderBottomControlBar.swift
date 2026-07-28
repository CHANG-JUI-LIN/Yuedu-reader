import SwiftUI

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
    let onOpenTOC: () -> Void
    let onOpenBookmarks: () -> Void
    let onOpenSettings: () -> Void

    @State private var chapterSliderDraft: Double? = nil

    private let feedbackDuration: Double = 0.25

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 12) {
                Spacer()
                if showRefreshButton {
                    circleBtn(icon: "arrow.clockwise", label: localized("刷新")) { onRefresh() }
                }
                if showChangeSourceButton {
                    circleBtn(icon: "arrow.left.and.right", label: localized("換源")) {
                        onOpenChangeSource()
                    }
                }
                if showDownloadButton {
                    circleBtn(icon: downloadButtonIcon, label: localized("下載")) { onDownloadAction() }
                }
                circleBtn(icon: "headphones", label: localized("聽書")) { onOpenTTS() }
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
            .background(readerTheme.barColor)
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

    /// A floating secondary action, sitting directly on top of the CoreText page —
    /// unlike the tool row below, it has no bar behind it. The fill must therefore stay
    /// opaque: with `Color.clear` the body text (and 段評 bubbles) showed straight
    /// through the circles and the icons were unreadable against any paragraph behind
    /// them. `barColor` matches the control bar underneath, so the row reads as one
    /// piece of chrome.
    ///
    /// That is also why this takes 光暈 alone rather than the full `floatingSurface`:
    /// letting 毛玻璃 reach these circles would put the body text back behind the icons.
    @ViewBuilder
    private func circleBtn(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DSFont.fixed(size: 18))
                .foregroundColor(readerTheme.textColor.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(readerTheme.barColor, in: Circle())
                .interfaceGlow(in: Circle())
                .overlay(Circle().stroke(readerTheme.textColor.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                // The symbol stayed a focusable element of its own next to the button, so
                // VoiceOver read 「換源」 out as "arrow.left.and.right" — the button's label
                // never won. The icon is decorative here: the name lives on the Button.
                // docs/design.md §7.1, second trap.
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)
    }

    /// The one source for both the printed progress line and the slider's VoiceOver value.
    private var progressStatusText: String {
        "\(chapterPageInfo)  ·  \(totalProgressPercent)"
    }

    private var progressSliderRow: some View {
        HStack(spacing: 4) {
            Button {
                onPrevChapter()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(DSFont.fixed(size: 12))
                        .accessibilityHidden(true)
                    Text(localized("上一章")).font(DSFont.fixed(size: 14))
                }
                .foregroundColor(
                    canGoPrevChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
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
                ).accentColor(readerTheme.accentColor)
                // A bare Slider announces a percentage of its 0…1 range and no name at all
                // (docs/design.md §7.1, third trap). Value shares `progressStatusText` with
                // the line printed underneath so the two can't drift apart.
                .accessibilityLabel(localized("閱讀進度"))
                .accessibilityValue(progressStatusText)

                Text(progressStatusText)
                    .font(DSFont.fixed(size: 10).monospacedDigit())
                    .foregroundColor(readerTheme.textColor.opacity(0.4))
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
                    canGoNextChapter ? readerTheme.textColor : readerTheme.textColor.opacity(0.22)
                )
                .padding(.trailing, 14).padding(.vertical, 18)
            }
            .disabled(!canGoNextChapter)
            .accessibilityLabel(localized(canGoNextChapter ? "下一章" : "書末頁"))
        }
        .background(readerTheme.barColor)
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolBtn(icon: "list.bullet", label: localized("目錄")) { onOpenTOC() }
            toolBtn(icon: "bookmark", label: localized("書籤")) { onOpenBookmarks() }
            toolBtn(
                icon: readerTheme == .night ? "sun.min" : "moon",
                label: localized(readerTheme == .night ? "白天" : "深色"),
                active: readerTheme == .night
            ) {
                withAnimation(.easeInOut(duration: feedbackDuration)) {
                    if readerTheme == .night {
                        let saved = UserDefaults.standard.string(forKey: "lastLightTheme") ?? ReaderTheme.white.rawValue
                        readerTheme = ReaderTheme(rawValue: saved) ?? .white
                    } else {
                        UserDefaults.standard.set(readerTheme.rawValue, forKey: "lastLightTheme")
                        readerTheme = .night
                    }
                }
            }
            toolBtn(icon: "gearshape", label: localized("設置")) { onOpenSettings() }
        }
        .padding(.top, 2).padding(.bottom, 14)
        .background(readerTheme.barColor)
    }

    @ViewBuilder
    private func toolBtn(
        icon: String, label: String, active: Bool = false, badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(DSFont.fixed(size: 20))
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
            .foregroundColor(active ? readerTheme.accentColor : readerTheme.textColor.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label)
        .accessibilityValue(badge.map { "\($0)" } ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
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
            onOpenTOC: {},
            onOpenBookmarks: {},
            onOpenSettings: {}
        )
    }
}
