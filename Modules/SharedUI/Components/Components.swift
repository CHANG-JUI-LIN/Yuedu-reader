import SwiftUI

// MARK: - Design System: Shared Components

/// Common search bar shared by HomeView and BookSourceListView.
struct DSSearchBar: View {
    let placeholder: String
    @Binding var text: String
    
    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DSColor.textSecondary)
            TextField(placeholder, text: $text)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(DSColor.textSecondary)
                }
            }
        }
        .padding(10)
        .background(DSColor.textSecondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
    }
}

/// Settings navigation row with icon, title, optional detail, and chevron.
struct DSSettingsRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
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
                Image(systemName: "chevron.right")
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
        }
    }
}


struct IconConsistentLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            themedIcon(configuration.icon)
            configuration.title
        }
    }

    /// Row icons pick up the theme accent when an app theme is active; with no
    /// theme (classic) they keep whatever color the label was given (primary).
    @ViewBuilder
    private func themedIcon(_ icon: Configuration.Icon) -> some View {
        let sized = icon
            .font(DSFont.fixed(size: 17, weight: .medium))
            .frame(width: 28, height: 28)
        if AppearanceThemePreset.activeAppTheme != nil {
            sized.foregroundStyle(DSColor.accent)
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
    @ObservedObject private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DSColor.groupedBackground
            if subscriptionStore.hasAccess(.readerThemePacks),
               let slice = gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme) {
                AppearancePageBackgroundLayerView(slice: slice)
            }
        }
    }
}

private struct ThemedAppSurfaceModifier: ViewModifier {
    let scope: AppearancePageBackgroundScope
    @ObservedObject private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var slice: AppearancePageBackgroundSlice? {
        guard subscriptionStore.hasAccess(.readerThemePacks) else { return nil }
        return gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme)
    }

    func body(content: Content) -> some View {
        if let slice {
            content
                .scrollContentBackground(.hidden)
                .background {
                    ZStack {
                        DSColor.groupedBackground
                        AppearancePageBackgroundLayerView(slice: slice)
                    }
                    .ignoresSafeArea()
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        } else if AppearanceThemePreset.activeAppTheme != nil {
            content
                .scrollContentBackground(.hidden)
                .background(DSColor.groupedBackground.ignoresSafeArea())
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(DSColor.groupedBackground.ignoresSafeArea())
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// Hides the navigation bar's default material background when a page
/// background or app theme is active, so the background shows through the
/// nav-bar region (behind the title and toolbar buttons).
private struct PageBackgroundToolbarModifier: ViewModifier {
    let scope: AppearancePageBackgroundScope
    @ObservedObject private var gs = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var hasBackground: Bool {
        if subscriptionStore.hasAccess(.readerThemePacks),
           gs.resolvedPageBackgroundSlice(for: scope, colorScheme: colorScheme) != nil {
            return true
        }
        return AppearanceThemePreset.activeAppTheme != nil
    }

    func body(content: Content) -> some View {
        if hasBackground {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
        }
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
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        .shadow(color: DSColor.shadow, radius: 6, x: 0, y: 4)
    }
}

/// Selectable chip button for filter and sort bars.
struct DSChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DSFont.caption )
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, DSSpacing.sm - 2)
                .background(isSelected ? DSColor.accent : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : DSColor.textPrimary)
                .clipShape(Capsule())
        }
    }
}

/// Toast banner for success/error messages.
struct DSToast: View {
    let message: String
    let color: Color
    
    var body: some View {
        Text(message)
            .font(DSFont.subheadline)
            .foregroundColor(.white)
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            .background(color.opacity(0.92))
            .clipShape(Capsule())
            .shadow(color: DSColor.shadow, radius: 4, y: 2)
            .padding(.top, DSSpacing.sm)
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
