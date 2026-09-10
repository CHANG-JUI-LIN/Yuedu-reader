import SwiftUI

/// 「設置自動閱讀 ∧」 — the running state, and the way to its controls.
///
/// Its own layer at the bottom of the screen, deliberately *not* a field in the
/// footer bar. It was one at first, which was wrong twice over: migration fills
/// unknown field kinds with `.hidden`, so it never appeared on any device that
/// already had a stored layout, and being a field meant someone could hide the
/// only way out of the mode. The bottom of the screen is just a position — it
/// shows whether or not the footer is on, and overlaps whatever is under it.
///
/// Tapping it opens `AutoReadControlPanel`; a tap on the page collapses that back
/// to this. Neither pauses the mode — see `ReaderView.autoReadIsCoveredBySurface`.
///
/// It wears the shared 界面效果 surface, like every other floating control in the
/// reader: on iOS 26 that is the same Liquid Glass the bottom bar under it is made
/// of, and it follows 毛玻璃／透明度／光暈 rather than a material of its own. It used
/// to hand-paint a dark `.ultraThinMaterial` — a second surface implementation
/// that on iOS 26 rendered as the legacy blur, so the pill read as a dark slab
/// floating over a glass toolbar.
struct AutoReadPill: View {
    let secondsPerPage: Double
    let fill: Color
    let tint: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DSSpacing.xs) {
                Text(localized("設置自動閱讀"))
                Image(systemName: "chevron.up")
                    .font(DSFont.caption)
                    .accessibilityHidden(true)
            }
            .font(DSFont.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, DSSpacing.lg)
            .frame(minHeight: DSLayout.minimumTapTarget)
            // The hairline that used to sit here defined the edge of a flat fill;
            // glass draws its own, and 光暈 comes with the surface.
            .floatingSurface(in: Capsule(), fill: fill)
            // Kept: `floatingSurface` layers on top of the caller's shadow rather
            // than replacing it, so the pill still has depth at 光暈 0.
            .shadow(color: DSColor.coverHeroShadow, radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("設置自動閱讀"))
        .accessibilityValue(AutoReadController.secondsText(secondsPerPage))
    }
}

/// The auto-read controls, drawn over the reading page rather than in a sheet.
///
/// The reader has already collapsed all the chrome to get here — a modal would
/// put a system surface straight back over the page they are watching turn. This
/// sits above the footer instead, on the same 界面效果 surface as the bottom bar it
/// replaces — same shape, same radius, same glass — so entering the mode swaps one
/// bottom surface for another instead of introducing a third material.
///
/// No play/pause: auto-read is a mode. It collapses back to the pill on a tap
/// anywhere on the page — legado's `AutoReadDialog` dismisses on an outside tap
/// the same way — and 退出自動閱讀 is what ends the mode itself.
struct AutoReadControlPanel: View {
    @ObservedObject var autoReader: AutoReadController
    let fill: Color
    let tint: Color
    let accent: Color
    let onOpenTOC: () -> Void
    let onOpenReadingMenu: () -> Void
    let onOpenSettings: () -> Void
    let onCollapse: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            collapseHandle
            speedRow
            Divider()
                .overlay(tint.opacity(0.18))
            actionRow
        }
        .padding(DSSpacing.md)
        // The 現代 bottom bar's own shape and radius (`ReaderModernBottomControlBar`),
        // because this stands in that bar's place while the mode runs.
        .floatingSurface(
            in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous),
            fill: fill
        )
        .shadow(color: DSColor.coverHeroShadow, radius: 18, y: 8)
        .padding(.horizontal, DSSpacing.md)
    }

    /// The counterpart to the pill's 「∧」, and the answer to "how do I put this
    /// away". legado's dialog needs no such handle: it is a real dialog window, so
    /// tapping outside it is the obvious move. This one sits on the page with the
    /// reveal still running behind it, so the way back has to be *visible* rather
    /// than discovered. Tapping the page does the same thing.
    private var collapseHandle: some View {
        Button(action: onCollapse) {
            Image(systemName: "chevron.down")
                .font(DSFont.caption)
                .foregroundStyle(tint.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localized("收起"))
    }

    /// 「翻頁速度  10s」 over a 1–120 slider, the same readout and range legado's
    /// `dialog_auto_read.xml` uses. Bigger is slower: the number is how long one
    /// page takes, so it needs no mental arithmetic to read.
    private var speedRow: some View {
        VStack(spacing: DSSpacing.xs) {
            HStack {
                Text(localized("翻頁速度"))
                Spacer()
                Text(autoReader.secondsText)
                    .monospacedDigit()
            }
            .font(DSFont.footnote)
            .foregroundStyle(tint.opacity(0.7))
            .accessibilityHidden(true)

            // A Slider has no name of its own and announces a fraction of its
            // range, so it carries the label and the value shown above it —
            // docs/design.md §7.1.
            Slider(
                value: Binding(
                    get: { autoReader.secondsPerPage },
                    set: { autoReader.setSecondsPerPage($0) }
                ),
                in: AutoReadController.secondsPerPageRange,
                step: 1
            )
            .tint(accent)
            .accessibilityLabel(localized("翻頁速度"))
            .accessibilityValue(autoReader.intervalDescription)
        }
    }

    /// 目錄 / 主選單 / 退出 / 設置 — legado's row and its order
    /// (`dialog_auto_read.xml`), 主選單 included this time. Leaving it out made the
    /// panel a dead end: with the mode's own chrome the only thing on screen, the
    /// reading menu was reachable only by collapsing this and tapping again.
    private var actionRow: some View {
        HStack(spacing: 0) {
            action(icon: "list.bullet", title: localized("目錄"), action: onOpenTOC)
            action(icon: "ellipsis.circle", title: localized("主選單"), action: onOpenReadingMenu)
            action(icon: "stop.circle", title: localized("退出自動閱讀"), action: onClose)
            action(icon: "textformat.size", title: localized("設置"), action: onOpenSettings)
        }
    }

    private func action(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                Image(systemName: icon)
                    .font(DSFont.fixed(size: 20))
                    .accessibilityHidden(true)
                Text(title)
                    .font(DSFont.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#Preview("自動閱讀控制") {
    ZStack {
        Color(uiColor: ReaderTheme.sepia.uiBackgroundColor).ignoresSafeArea()
        VStack(spacing: DSSpacing.xl) {
            Spacer()
            AutoReadPill(
                secondsPerPage: AutoReadController.defaultSecondsPerPage,
                fill: ReaderTheme.sepia.barColor,
                tint: ReaderTheme.sepia.textColor,
                onTap: {}
            )
            AutoReadControlPanel(
                autoReader: AutoReadController(),
                fill: ReaderTheme.sepia.barColor,
                tint: ReaderTheme.sepia.textColor,
                accent: ReaderTheme.sepia.accentColor,
                onOpenTOC: {},
                onOpenReadingMenu: {},
                onOpenSettings: {},
                onCollapse: {},
                onClose: {}
            )
        }
    }
}
