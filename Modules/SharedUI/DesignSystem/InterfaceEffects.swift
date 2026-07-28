import SwiftUI

// MARK: - Design System: 界面效果 (Interface Effects)

/// The surface every floating element in the app sits on — the mini player, the
/// reader's toolbars, control bars and quick panels. One entry point so the two
/// knobs in 外觀主題 › 界面效果 reach all of them:
///
/// - **毛玻璃** + **透明度** — whether the surface blurs what is behind it, and how
///   much of that blur shows through. Transparency 100% leaves the material
///   untouched (the app's original look); below that an opaque fill fades in over
///   the blur, so the slider is continuous and legibility only improves as it
///   drops. With the toggle off the surface is that fill alone.
/// - **光暈強度** — a tinted glow bleeding out of the surface's edge. It layers on
///   top of whatever drop shadow the caller already has rather than replacing it,
///   so a floating element keeps its depth at 強度 0.
extension View {
    /// Applies the user's 界面效果 to a floating element.
    ///
    /// - Parameters:
    ///   - shape: The element's outline. Both the surface and the glow take it.
    ///   - fill: The solid color behind the blur — what the element looks like with
    ///     毛玻璃 off. Reader chrome passes `readerTheme.barColor`; app chrome
    ///     defaults to `DSColor.surface`.
    ///   - glowTint: Glow color. Defaults to the active app theme's accent, so the
    ///     glow follows 外觀主題 without every caller restating it.
    func floatingSurface<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        fill: Color = DSColor.surface,
        glowTint: Color? = nil
    ) -> some View {
        modifier(FloatingSurfaceModifier(shape: shape, fill: fill, glowTint: glowTint))
    }

    /// The 光暈 alone, for elements that already own their background and only need
    /// the glow (e.g. chrome painted with an opaque theme color).
    func interfaceGlow<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        tint: Color? = nil
    ) -> some View {
        modifier(InterfaceGlowModifier(shape: shape, tint: tint))
    }
}

private struct FloatingSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let fill: Color
    let glowTint: Color?

    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Reduce Transparency is a system-level request for solid surfaces; it outranks
    /// a cosmetic preference, so it forces the opaque fill regardless of the toggle.
    private var usesFrostedGlass: Bool {
        settings.interfaceFrostedGlass && !reduceTransparency
    }

    func body(content: Content) -> some View {
        surfaced(content)
            .interfaceGlow(in: shape, tint: glowTint)
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if usesFrostedGlass {
            content
                // Fades in over the blur as 透明度 drops; invisible at 100%.
                .background(fill.opacity(1 - settings.interfaceGlassTransparency), in: shape)
                .modifier(FrostedGlassBackground(shape: shape))
        } else {
            content.background(fill, in: shape)
        }
    }
}

/// iOS 26 has the real thing — `glassEffect`, the same material the system
/// toolbars are made of, so a panel and the toolbar above it match without either
/// being hand-painted. Older systems have no glass; `.regularMaterial` is the
/// closest they offer.
///
/// The `#if compiler` guard mirrors `RSSFeedSearchBar`: the iOS 26 API only exists
/// in the Xcode 26 SDK, and the project still has to compile on older toolchains.
private struct FrostedGlassBackground<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
        #else
        content.background(.regularMaterial, in: shape)
        #endif
    }
}

private struct InterfaceGlowModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let tint: Color?

    @ObservedObject private var settings = GlobalSettings.shared

    private var intensity: Double {
        settings.interfaceGlowIntensity
    }

    private var resolvedTint: Color {
        tint ?? AppearanceThemePreset.activeAppTheme?.accentColor ?? DSColor.accent
    }

    func body(content: Content) -> some View {
        if intensity <= 0 {
            content
        } else {
            // Two blurred copies of the outline behind the element: a tight dense
            // one for the halo right at the edge, a wide faint one for the bloom.
            // Both sit under the surface, so only what spills past the edge shows.
            content
                .background {
                    glowLayer(
                        radius: DSLayout.interfaceGlowInnerRadius,
                        opacity: DSLayout.interfaceGlowInnerOpacity
                    )
                }
                .background {
                    glowLayer(
                        radius: DSLayout.interfaceGlowOuterRadius,
                        opacity: DSLayout.interfaceGlowOuterOpacity
                    )
                }
        }
    }

    private func glowLayer(radius: CGFloat, opacity: Double) -> some View {
        shape
            .fill(resolvedTint)
            .blur(radius: radius * intensity)
            .opacity(opacity * intensity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("界面效果 — 浮動表面") {
    ZStack {
        LinearGradient(
            colors: [DSColor.accent.opacity(0.35), DSColor.groupedBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack(spacing: DSSpacing.xxl) {
            Text("正文墊在浮動元素後面，檢查毛玻璃是否穿透。")
                .font(DSFont.body)
                .padding(DSSpacing.lg)

            HStack(spacing: DSSpacing.lg) {
                Image(systemName: "play.fill")
                    .font(DSFont.toolbarIconLarge)
                    .frame(width: 48, height: 48)
                    .floatingSurface(in: Circle())

                Text("浮動工具列")
                    .font(DSFont.subheadline)
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.vertical, DSSpacing.md)
                    .floatingSurface(in: Capsule())
            }
        }
    }
}
