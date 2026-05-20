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
            configuration.icon
                .font(.system(size: 17, weight: .medium))
                .frame(width: 28, height: 28)
            configuration.title
        }
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
                .font(.system(size: 48))
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
