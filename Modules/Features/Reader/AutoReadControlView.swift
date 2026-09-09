import SwiftUI

/// 「設置自動閱讀 ∧」 — the running state, and the way to its controls.
///
/// Its own layer at the bottom of the screen, deliberately *not* a field in the
/// footer bar. It was one at first, which was wrong twice over: migration fills
/// unknown field kinds with `.hidden`, so it never appeared on any device that
/// already had a stored layout, and being a field meant someone could hide the
/// only way out of the mode. The bottom of the screen is just a position — it
/// shows whether or not the footer is on, and overlaps whatever is under it.
struct AutoReadPill: View {
    let secondsPerPage: Double
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
            .foregroundStyle(DSColor.textOnAccent)
            .padding(.horizontal, DSSpacing.lg)
            .frame(minHeight: DSLayout.minimumTapTarget)
            .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
            .overlay(Capsule().stroke(DSColor.textOnAccent.opacity(0.12), lineWidth: 0.5))
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
/// sits above the footer instead, on its own dark material, which is the contrast
/// that separates "an activity in progress" from the paper-coloured panels that
/// change settings.
///
/// No play/pause: auto-read is a mode. The way out is the one full-width action
/// at the bottom.
struct AutoReadControlPanel: View {
    @ObservedObject var autoReader: AutoReadController
    let onOpenTOC: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            speedRow
            Divider()
                .overlay(DSColor.textOnAccent.opacity(0.18))
            actionRow
        }
        .padding(DSSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
                .stroke(DSColor.textOnAccent.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: DSColor.coverHeroShadow, radius: 18, y: 8)
        .padding(.horizontal, DSSpacing.md)
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
            .foregroundStyle(DSColor.textOnAccent.opacity(0.7))
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
            .tint(DSColor.textOnAccent.opacity(0.85))
            .accessibilityLabel(localized("翻頁速度"))
            .accessibilityValue(autoReader.intervalDescription)
        }
    }

    /// 目錄 / 設置 / 退出 — legado's row, minus its 主選單 button, which here is
    /// just tapping the page.
    private var actionRow: some View {
        HStack(spacing: 0) {
            action(icon: "list.bullet", title: localized("目錄"), action: onOpenTOC)
            action(icon: "textformat.size", title: localized("設置"), action: onOpenSettings)
            action(icon: "stop.circle", title: localized("退出自動閱讀"), action: onClose)
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
            .foregroundStyle(DSColor.textOnAccent)
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
        VStack {
            Spacer()
            AutoReadControlPanel(
                autoReader: AutoReadController(),
                onOpenTOC: {},
                onOpenSettings: {},
                onClose: {}
            )
        }
    }
}
