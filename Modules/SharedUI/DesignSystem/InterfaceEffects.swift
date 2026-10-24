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
/// - **光暈** — a tinted glow bleeding out of the surface's edge, off by default. It
///   layers on top of whatever drop shadow the caller already has rather than
///   replacing it, so a floating element keeps its depth with the glow off.
extension View {
    /// Applies the user's 界面效果 to a floating element.
    ///
    /// - Parameters:
    ///   - shape: The element's outline. Both the surface and the glow take it.
    ///   - fill: The solid color behind the blur — what the element looks like with
    ///     毛玻璃 off. Reader chrome passes `readerTheme.barColor`; app chrome
    ///     defaults to `DSColor.surface`.
    ///   - glowTint: Glow color. Defaults to the colour picked in 界面效果, else the
    ///     active app theme's accent, so the glow follows 外觀主題 without every
    ///     caller restating it.
    func floatingSurface<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        fill: Color = DSColor.surface,
        glowTint: Color? = nil
    ) -> some View {
        modifier(FloatingSurfaceModifier(shape: shape, fill: fill, glowTint: glowTint))
    }

    /// The floating surface without the 光暈, for a surface something else clips —
    /// a glow drawn behind it could never show past the clip anyway.
    ///
    /// 現代's book card is the caller: its surface is the popover's, handed over
    /// through `presentationBackground`, and the popover clips it to its own
    /// rounded shape and cuts the arrow out of it.
    ///
    /// The reading assistant's composer and the controls floating with it are the other
    /// callers: glass samples the glow drawn behind it, so the whole input surface turns
    /// accent-tinted, reads as a focused field, and its placeholder loses contrast.
    func floatingSurfaceBackground<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        fill: Color = DSColor.surface
    ) -> some View {
        modifier(InterfaceSurfaceModifier(shape: shape, fill: fill, glassAllowed: true))
    }

    /// The 光暈 alone, for elements that already own their background and only need
    /// the glow (e.g. chrome painted with an opaque theme color).
    func interfaceGlow<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        tint: Color? = nil
    ) -> some View {
        modifier(InterfaceGlowModifier(shape: shape, tint: tint))
    }

    /// The surface a `Form`/`List` section card sits on. Apply to a `Section` (or a
    /// single row) in place of a hardcoded `DSColor.surface` row background.
    ///
    /// - Parameter fill: The opaque card color — what the section looks like with
    ///   分組卡片 off, and the fill 透明度 fades in over the glass.
    func interfaceSectionSurface(fill: Color = DSColor.surface) -> some View {
        modifier(InterfaceSectionSurfaceModifier(fill: fill))
    }

    /// The surface a hand-drawn card sits on — settings rows built as buttons or
    /// stacks rather than list rows, stat cards, detail-page cards. Same material
    /// and same 分組卡片 switch as `interfaceSectionSurface()`; this one attaches as
    /// a background because there is no list row to hand it to.
    ///
    /// - Parameters:
    ///   - shape: The card's outline, matching whatever the caller already passed to
    ///     `.background(_:in:)`.
    ///   - fill: The opaque card color.
    func interfaceCardSurface<SurfaceShape: Shape>(
        in shape: SurfaceShape,
        fill: Color = DSColor.surface
    ) -> some View {
        modifier(InterfaceCardSurfaceModifier(shape: shape, fill: fill))
    }

    /// `interfaceCardSurface(in:)` for cards that had a bare `.background(_)` — the
    /// rounding is done by a `clipShape` further out, so the surface itself is square.
    func interfaceCardSurface(fill: Color = DSColor.surface) -> some View {
        modifier(InterfaceCardSurfaceModifier(shape: Rectangle(), fill: fill))
    }
}

/// 毛玻璃 + 透明度 painted as a background, without the glow. The one place the app
/// builds that surface: `floatingSurface`, `interfaceSectionSurface` and
/// `interfaceCardSurface` all route through here and differ only in what gates the
/// glass and how the result gets attached.
private struct InterfaceSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let fill: Color
    /// The caller's own gate. Floating chrome passes `true` — it is the functional
    /// layer, where the system design puts glass unconditionally. Content-layer
    /// cards pass 分組卡片, which is opt-in.
    let glassAllowed: Bool

    @Bindable private var settings = GlobalSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// Reduce Transparency is a system-level request for solid surfaces; it outranks
    /// a cosmetic preference, so it forces the opaque fill regardless of the toggle.
    private var usesFrostedGlass: Bool {
        glassAllowed && settings.interfaceFrostedGlass && !reduceTransparency
    }

    /// The active theme's card artwork for this appearance, or nil for the plain fill.
    private var cardLayer: AppearanceCardBackgroundLayer? {
        guard let background = settings.appearanceCardBackground, !background.isEmpty else {
            return nil
        }
        let layer = background.layer(for: colorScheme == .dark ? .dark : .light)
        return layer.isEmpty ? nil : layer
    }

    /// Opacity of whatever is painted over the glass: 透明度 100% leaves the glass
    /// untouched, and the paint fades in as it drops.
    private var paintOpacity: Double {
        1 - settings.interfaceGlassTransparency
    }

    func body(content: Content) -> some View {
        if usesFrostedGlass {
            // Card artwork is the card's *paint*, not what the card is made of. It used
            // to replace the whole surface, so a pack carrying a plain white card
            // background (山风 - 春水漾) left 分組卡片 and every floating control opaque
            // white no matter how 毛玻璃 and 透明度 were set. The artwork now takes the
            // plain fill's place over the glass and fades with 透明度 the same way.
            if let cardLayer {
                content
                    .background(
                        AppearanceCardArtwork(layer: cardLayer, paintOpacity: paintOpacity)
                            .clipShape(shape)
                    )
                    .modifier(FrostedGlassBackground(shape: shape))
            } else {
                content
                    // Fades in over the blur as 透明度 drops; invisible at 100%.
                    .background(fill.opacity(paintOpacity), in: shape)
                    .modifier(FrostedGlassBackground(shape: shape))
            }
        } else if let cardLayer {
            // Without glass the artwork replaces the plain fill entirely — a card
            // painting is the whole surface, and layering it over the themed colour
            // would tint it.
            content
                .background(AppearanceCardArtwork(layer: cardLayer).clipShape(shape))
        } else {
            content.background(fill, in: shape)
        }
    }
}

/// Draws one card-background layer: an optional flat fill, the artwork over it
/// (stretched, or nine-sliced so a drawn border keeps its corners), and an optional
/// hairline border on top.
private struct AppearanceCardArtwork: View {
    let layer: AppearanceCardBackgroundLayer
    /// Scales the fill and the picture, never the border: over glass the paint fades
    /// with 透明度, while the edge stays as crisp as the pack drew it.
    var paintOpacity: Double = 1

    var body: some View {
        ZStack {
            ZStack {
                if let fillHex = layer.fillHex {
                    Color(uiColor: AppearanceThemePreset.hex(fillHex))
                        .opacity(layer.fillOpacity)
                }
                if let image = artworkImage {
                    imageView(image)
                        .opacity(layer.imageOpacity)
                }
            }
            .opacity(paintOpacity)
            if let borderHex = layer.borderHex, layer.borderWidth > 0 {
                Rectangle()
                    .strokeBorder(
                        Color(uiColor: AppearanceThemePreset.hex(borderHex))
                            .opacity(layer.borderOpacity),
                        lineWidth: layer.borderWidth
                    )
            }
        }
    }

    private var artworkImage: UIImage? {
        guard let name = layer.imageFileName, !name.isEmpty else { return nil }
        return AppearanceCardBackgroundImageStore.shared.image(fileName: name)
    }

    @ViewBuilder
    private func imageView(_ image: UIImage) -> some View {
        switch layer.mode {
        case .stretch:
            Image(uiImage: image).resizable()
        case .nineSlice:
            // Cap insets are stored as fractions of the image, so they survive the
            // store's downsampling; SwiftUI wants them in the image's own points.
            Image(uiImage: image).resizable(
                capInsets: EdgeInsets(
                    top: image.size.height * layer.sliceTop,
                    leading: image.size.width * layer.sliceLeft,
                    bottom: image.size.height * layer.sliceBottom,
                    trailing: image.size.width * layer.sliceRight
                ),
                resizingMode: .stretch
            )
        }
    }
}

private struct InterfaceCardSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let fill: Color

    @Bindable private var settings = GlobalSettings.shared

    func body(content: Content) -> some View {
        content.modifier(
            InterfaceSurfaceModifier(
                shape: shape,
                fill: fill,
                glassAllowed: settings.interfaceGlassCards
            )
        )
    }
}

/// Content-layer cards, which Apple's HIG keeps Liquid Glass out of, so they only go
/// glass when the user opts in via 分組卡片.
///
/// `listRowBackground` paints this per row and the list clips it to the card's
/// rounded corners, so the surface is a plain rectangle and the rounding stays the
/// list's job. One consequence on iOS 26: each row carries its own glass edge, so
/// row boundaries inside a section can show a faint seam that a single section-wide
/// glass would not have. SwiftUI has no section-level material to paint instead; if
/// one ships, this is the place to switch.
private struct InterfaceSectionSurfaceModifier: ViewModifier {
    let fill: Color

    @Bindable private var settings = GlobalSettings.shared

    func body(content: Content) -> some View {
        content.listRowBackground(
            Color.clear.modifier(
                InterfaceSurfaceModifier(
                    shape: Rectangle(),
                    fill: fill,
                    glassAllowed: settings.interfaceGlassCards
                )
            )
        )
    }
}

private struct FloatingSurfaceModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let fill: Color
    let glowTint: Color?

    func body(content: Content) -> some View {
        content
            // Floating chrome is the functional layer: it follows 毛玻璃 directly,
            // with no extra opt-in.
            .modifier(InterfaceSurfaceModifier(shape: shape, fill: fill, glassAllowed: true))
            .interfaceGlow(in: shape, tint: glowTint)
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

extension ActiveAppThemes {
    /// The glow's colour when none is picked in 界面效果: the app theme's accent.
    /// Dynamic like every other themed color, so it follows the appearance at draw time.
    var glowAccent: Color {
        guard isActive else { return DSColor.accent }
        let themes = self
        return Color(uiColor: UIColor { traits in
            themes.theme(for: traits.userInterfaceStyle)?.accent ?? .tintColor
        })
    }
}

private struct InterfaceGlowModifier<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    let tint: Color?

    @Bindable private var settings = GlobalSettings.shared
    /// From the environment, not `AppearanceThemePreset.activeAppThemes`: a global gives
    /// SwiftUI nothing to observe, and this modifier no longer redraws for every setting.
    @Environment(\.appThemes) private var appThemes

    private var intensity: Double {
        settings.interfaceGlowIntensity
    }

    /// The caller's tint, else the colour picked in 界面效果, else the theme's accent.
    private var resolvedTint: Color {
        if let tint { return tint }
        if let picked = settings.interfaceGlowColor {
            return Color(uiColor: AppearanceThemePreset.hex(picked))
        }
        return appThemes.glowAccent
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

/// Both card kinds over a patterned backdrop — a list section and a hand-drawn card,
/// which must look identical for 分組卡片 to read as one setting. Toggle 界面效果 ›
/// 分組卡片 in the running app to see the material switch; the preview deliberately
/// reads the live setting rather than forcing it, so what shows here is what the
/// user's own device shows.
#Preview("界面效果 — 分組卡片") {
    ZStack {
        LinearGradient(
            colors: [DSColor.accent.opacity(0.35), DSColor.groupedBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        Form {
            Section {
                Text("List section")
                    .font(DSFont.body)
                Text("第二列，檢查列與列之間的接縫")
                    .font(DSFont.body)
            } footer: {
                Text("玻璃取樣的是卡片背後的內容，純色主題下與不透明卡片幾乎無異。")
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            // The 外觀主題 pattern: a card drawn by the view, not by the list. It has
            // to match the section above at every setting.
            Section {
                Text("自繪卡片")
                    .font(DSFont.body)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .interfaceCardSurface(
                        in: RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
    }
}
