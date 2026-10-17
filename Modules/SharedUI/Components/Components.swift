import SwiftUI

// MARK: - Design System: Shared Components

/// A tab root's search field, pinned at the top of its page: 資源庫's and 搜索's.
///
/// Not the navigation bar's `.searchable`, which these pages had: the bar is the root stack's,
/// around the tab bar, and from iOS 18 a `.searchable` on the tab bar never reaches it, while
/// one that only some tabs carry rebuilds every tab as the selection changes
/// (`RootTabNavigationContractTests`; maintainer's choice, 2026-10-16). Drawn as the system's
/// field: the magnifier, the clear button while it holds text, and 取消 while it is typed in,
/// which empties it as the system's does.
struct DSSearchBar: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    /// The keyboard's Search.
    var onSubmit: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $text)
                    .focused(isFocused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .accessibilityAddTraits(.isSearchField)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DSColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized("清除"))
                }
            }
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.sm)
            .background(DSColor.neutralControlFill, in: SearchFieldShape())
            if isFocused.wrappedValue {
                Button(localized("取消")) {
                    text = ""
                    isFocused.wrappedValue = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : DSAnimation.standard, value: isFocused.wrappedValue)
    }
}

/// The system search field's outline: a capsule from iOS 26, a rounded rectangle before.
private struct SearchFieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        if #available(iOS 26.0, *) {
            Capsule().path(in: rect)
        } else {
            RoundedRectangle(cornerRadius: DSRadius.lg).path(in: rect)
        }
    }
}

/// Settings navigation row with icon, title, optional detail, and chevron.
struct DSSettingsRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    /// Needs Pro the user does not have: the chevron becomes a lock, as on 外觀's 啟動圖
    /// row, and `action` is expected to open the paywall.
    var isLocked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundColor(DSColor.textPrimary)
                    .labelStyle(IconConsistentLabelStyle())
                Spacer()
                if let detail {
                    Text(detail)
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }
        }
    }
}


struct IconConsistentLabelStyle: LabelStyle {
    /// Off for a row whose title carries its own colour — an action or a destructive
    /// row — so its symbol matches the title instead of turning accent-coloured.
    var themesIcon = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            themedIcon(configuration.icon)
            configuration.title
        }
    }

    /// A row's symbol wears the tint — 強調色 — in every theme, 默認 included, as the
    /// symbol leading a list row does on iOS (user's call, 2026-09-29). `.tint` resolves
    /// from the environment when the symbol draws, so a theme switch or a 強調色 edit
    /// reaches rows SwiftUI does not rebuild. Deciding here from
    /// `AppearanceThemePreset.activeAppThemes`, a global SwiftUI cannot observe, left
    /// those rows in the colour they were first drawn in — black beside red ones.
    @ViewBuilder
    private func themedIcon(_ icon: Configuration.Icon) -> some View {
        let sized = icon
            .font(DSFont.fixed(size: 17, weight: .medium))
            .frame(width: 28, height: 28)
        if themesIcon {
            sized.foregroundStyle(.tint)
        } else {
            sized
        }
    }
}

/// Reusable page background: the themed grouped background plus, when the user
/// configured a page background (Pro), the gradient/image layer for the given
/// scope. Use inside `ZStack` or `.background { }` on any surface that should
/// show the page background — tabs, sheets, and standalone views alike.
struct PageBackgroundView: View {
    let scope: AppearancePageBackgroundScope
    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DSColor.groupedBackground
            if let slice = Self.slice(for: scope, colorScheme: colorScheme, settings: gs,
                                      subscriptions: subscriptionStore) {
                AppearancePageBackgroundLayerView(slice: slice)
            }
        }
    }

    /// The theme's picture this background draws over the page colour, if any. A view that
    /// must stand aside for it (a detail page's cover wash) asks the same question.
    @MainActor
    static func slice(
        for scope: AppearancePageBackgroundScope, colorScheme: ColorScheme,
        settings: GlobalSettings, subscriptions: SubscriptionStore
    ) -> AppearancePageBackgroundSlice? {
        guard subscriptions.hasAccess(.readerThemePacks) else { return nil }
        return settings.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme)
    }
}

private struct ThemedAppSurfaceModifier: ViewModifier {
    let scope: AppearancePageBackgroundScope
    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var slice: AppearancePageBackgroundSlice? {
        guard subscriptionStore.hasAccess(.readerThemePacks) else { return nil }
        return gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme)
    }

    /// Single structure for every state — branching over `content` would change
    /// the modified view's identity when a page background appears or vanishes,
    /// and SwiftUI rebuilds what changed identity, dropping its `@State` and any
    /// screen it had pushed. Branch inside `.background` instead.
    /// (The two theme-less branches this replaced were already byte-identical.)
    func body(content: Content) -> some View {
        let slice = self.slice
        return content
            .scrollContentBackground(.hidden)
            .background {
                ZStack {
                    DSColor.groupedBackground
                    if let slice {
                        AppearancePageBackgroundLayerView(slice: slice)
                    }
                }
                .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Hides the navigation bar's default material background when a page
/// background or app theme is active, so the background shows through the
/// nav-bar region (behind the title and toolbar buttons).
private struct PageBackgroundToolbarModifier: ViewModifier {
    let scope: AppearancePageBackgroundScope
    /// The page wears `themedAppSurface`, whose bar is clear whatever the theme.
    var alwaysHidden = false
    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme
    /// The themes from the environment rather than `AppearanceThemePreset.activeAppThemes`,
    /// which SwiftUI cannot observe: this modifier redraws only for what it reads.
    @Environment(\.appThemes) private var appThemes

    private var hasBackground: Bool {
        if alwaysHidden { return true }
        if subscriptionStore.hasAccess(.readerThemePacks),
           gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme) != nil {
            return true
        }
        // 默認 with its 背景 as shipped keeps the system's page, and the bar that goes with it.
        guard let theme = appThemes.theme(for: colorScheme) else { return false }
        return !theme.keepsSystemBackgrounds
    }

    /// Always the same modifier, only its visibility changes (`.automatic` is
    /// the default bar background, i.e. what "not applied" looked like). An
    /// `if/else` here re-identified the whole screen whenever the theme moved
    /// between 默認 and a real theme: 外觀主題 uses this modifier, so switching
    /// themes from it reset its own `@State` and popped it back to 設定.
    func body(content: Content) -> some View {
        content.toolbarBackground(hasBackground ? .hidden : .automatic, for: .navigationBar)
    }
}

extension View {
    /// Retints a scrollable `Form`/`List` to the active app theme and paints
    /// the page background layer for `scope`. The background is painted
    /// directly behind the `Form`/`List` (with `ignoresSafeArea` so it extends
    /// behind the navigation bar), and the navigation bar's default material is
    /// hidden so the background shows through the nav-bar region. A no-op when
    /// no theme is active and no page background is configured. Apply directly
    /// on the `Form`/`List`.
    func themedAppSurface(for scope: AppearancePageBackgroundScope = .global) -> some View {
        modifier(ThemedAppSurfaceModifier(scope: scope))
    }

    /// Hides the navigation bar's default material when a page background or app
    /// theme is active. Use on views that paint their own background via
    /// `PageBackgroundView` (non-`Form`/`List` surfaces like `ScrollView`,
    /// `ZStack`, etc.) so the nav-bar region shows the page background.
    func pageBackgroundToolbar(for scope: AppearancePageBackgroundScope = .global) -> some View {
        modifier(PageBackgroundToolbarModifier(scope: scope))
    }

    /// The bar background of the selected tab root, which `ContentView` puts on the tab bar:
    /// the bar is the root stack's, and a tab page's own `themedAppSurface` or
    /// `pageBackgroundToolbar` does not reach it. `paintsSurface`: the page wears
    /// `themedAppSurface`. One modifier for every tab, so selecting another never changes the
    /// tab bar's identity.
    func tabRootToolbarBackground(for scope: AppearancePageBackgroundScope, paintsSurface: Bool) -> some View {
        modifier(PageBackgroundToolbarModifier(scope: scope, alwaysHidden: paintsSurface))
    }
}

/// Card container with uniform padding, rounded corners, and shadow.
struct DSCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            content
        }
        .padding(DSSpacing.lg)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        .shadow(color: DSColor.shadow, radius: 6, x: 0, y: 4)
    }
}

/// The capsule every chip, filter and quick action in a bar is drawn as. Unselected it
/// sits on the app's floating surface — glass with 外觀主題 › 界面效果 › 毛玻璃 on, its
/// fill without — so it matches the controls floating over the page; selected it is the
/// accent with white text. The label is subheadline at medium weight: a semantic text
/// style, so it scales with Dynamic Type and keeps the system's tracking, with the
/// weight rather than the size setting it apart from body text.
struct DSCapsuleLabel: View {
    let title: String
    /// A symbol before the title.
    var systemImage: String? = nil
    /// A symbol after it — `chevron.down` on a menu, `arrow.up.right` on a link out.
    var trailingSystemImage: String? = nil
    var isSelected = false
    /// Takes the width it is offered, its title centred — a chip in a grid of equal
    /// columns, which gives a long title as many columns as it needs; a title wider than
    /// the whole row takes a second line. Off, the capsule hugs its one line.
    var fillsWidth = false
    /// On a card that is glass itself: a plain gray fill when not selected, since glass
    /// on glass turns muddy.
    var onCard = false
    /// A value after the title on the same line, in the secondary colour — what an input
    /// holds, or that it is empty. It is cut short before the title is.
    var detail: String? = nil
    /// The narrowest the capsule gets, its title centred: a one-character title would
    /// otherwise make a capsule narrower than it is tall.
    var minWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(fillsWidth ? 2 : 1)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .fontWeight(.regular)
                    .foregroundStyle(isSelected ? DSColor.textOnAccent : DSColor.textSecondary)
                    .lineLimit(1)
            }
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(DSFont.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(DSFont.subheadline.weight(.medium))
        .foregroundStyle(isSelected ? DSColor.textOnAccent : DSColor.textPrimary)
        .padding(.horizontal, fillsWidth ? DSSpacing.sm : DSSpacing.md)
        .padding(.vertical, fillsWidth ? DSSpacing.xs : 0)
        .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil, minHeight: DSLayout.capsuleControlHeight)
        .background {
            if isSelected {
                Capsule().fill(DSColor.accent)
            } else if onCard {
                Capsule().fill(DSColor.neutralControlFill)
            } else {
                Color.clear.floatingSurfaceBackground(in: Capsule())
            }
        }
        .contentShape(Capsule())
    }
}

/// Selectable chip button for filter and sort bars.
struct DSChip: View {
    let title: String
    let isSelected: Bool
    /// See `DSCapsuleLabel.minWidth`.
    var minWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DSCapsuleLabel(title: title, isSelected: isSelected, minWidth: minWidth)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Empty state placeholder view.
struct DSEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    
    var body: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(DSFont.fixed(size: 48))
                .foregroundColor(DSColor.textSecondary.opacity(0.5))
            Text(title)
                .font(DSFont.headline)
                .foregroundColor(DSColor.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DSSpacing.xl)
    }
}
