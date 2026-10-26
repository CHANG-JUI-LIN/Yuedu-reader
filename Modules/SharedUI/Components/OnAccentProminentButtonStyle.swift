import SwiftUI

/// `.borderedProminent` with its label in `DSColor.textOnAccent`.
///
/// The system's prominent styles draw their label white on whatever the accent is, and so white
/// on white under a theme whose accent is near white. Measured 2026-10-26 on iOS 27.0: contrast
/// 1.09 on F5F5F5 and 1.14 on E6F2F4, in both appearances (feedback #77, the same defect as the
/// shelf chip). Every prominent button on the accent uses this or `.onAccentGlassProminent`.
struct OnAccentProminentButtonStyle: PrimitiveButtonStyle {
    /// Set for a button that works in place — a purchase, a submission — showing a spinner as
    /// its label meanwhile. Working, it stays on the accent under that spinner, where a disabled
    /// one would sit on the system's grey (a spinner made for the accent measured 1.12:1 there),
    /// and it ignores taps. VoiceOver hears it by `title` and dimmed, as a disabled button: the
    /// spinner alone left it nameless.
    fileprivate var work: (isWorking: Bool, title: Text)?

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role) {
            guard work?.isWorking != true else { return }
            configuration.trigger()
        } label: {
            OnAccentProminentLabel(content: configuration.label)
        }
        .buttonStyle(.borderedProminent)
        // Fixed per call site, so a button keeps its identity as it starts and stops working.
        if let work {
            button.accessibilityRepresentation {
                Button(role: configuration.role, action: configuration.trigger) { work.title }
                    .disabled(work.isWorking)
            }
        } else {
            button
        }
    }
}

#if compiler(>=6.2)
/// `.glassProminent` with its label in `DSColor.textOnAccent`: white on F5F5F5 measured 1.00 in
/// light appearance and 1.17 in dark, the glass lightening the fill further.
@available(iOS 26.0, *)
struct OnAccentGlassProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            OnAccentProminentLabel(content: configuration.label)
        }
        .buttonStyle(.glassProminent)
    }
}
#endif

extension PrimitiveButtonStyle where Self == OnAccentProminentButtonStyle {
    /// `.borderedProminent`, its label black where the accent is too light for white.
    static var onAccentProminent: OnAccentProminentButtonStyle { OnAccentProminentButtonStyle() }

    /// `.onAccentProminent` for a button that shows a spinner while `isWorking`; `title` is
    /// what its label reads when it is not.
    static func onAccentProminent(working isWorking: Bool, title: Text) -> OnAccentProminentButtonStyle {
        OnAccentProminentButtonStyle(work: (isWorking, title))
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
extension PrimitiveButtonStyle where Self == OnAccentGlassProminentButtonStyle {
    /// `.glassProminent`, its label black where the accent is too light for white.
    static var onAccentGlassProminent: OnAccentGlassProminentButtonStyle { OnAccentGlassProminentButtonStyle() }
}
#endif

/// A prominent button's label: the token while the button draws the accent. A disabled one
/// draws the system's grey instead, which the token was never paired with, so its label is
/// left to the system. The branch is the label's, inside the button, so the button VoiceOver
/// reads keeps its identity when it is enabled or disabled.
private struct OnAccentProminentLabel<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let content: Content

    var body: some View {
        if isEnabled {
            content.foregroundStyle(DSColor.textOnAccent)
        } else {
            content
        }
    }
}

#Preview("強調色上的主要按鈕") {
    VStack(spacing: DSSpacing.lg) {
        ForEach([Color(red: 0.96, green: 0.96, blue: 0.96), Color(red: 0.12, green: 0.16, blue: 0.35)], id: \.self) { accent in
            VStack(spacing: DSSpacing.sm) {
                Button(localized("升級")) {}
                    .buttonStyle(.onAccentProminent)
                Button(localized("升級")) {}
                    .buttonStyle(.onAccentProminent)
                    .disabled(true)
            }
            .tint(accent)
            .accentColor(accent)
        }
    }
    .padding()
    .background(DSColor.groupedBackground)
}
