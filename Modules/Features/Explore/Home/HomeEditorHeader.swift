import SwiftUI

// The maintainer, 2026-10-27, after an Emby client's home editor: 編輯首頁 opens on the
// 首頁配置 it edits. Its photo, with a camera badge, changes the photo (`HomePhotoPicker`, the
// form's own); its name pushes 首頁配置's page, where it is switched, added and renamed.

struct HomeEditorHeader: View {
    /// Pushes 首頁配置's page.
    let openConfigurations: () -> Void

    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var photos = HomePageStore.shared.photos

    private var configurationID: HomeConfigurationID { pageStore.selectedConfiguration }

    private var name: String {
        pageStore.configurations.first { $0.id == configurationID }?.name ?? ""
    }

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            HomePhotoPicker(photos: photos, id: configurationID) {
                HomeConfigurationPhoto(name: name, image: photos.images[configurationID], size: DSLayout.homeEditorPhotoSize)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(DSFont.caption2)
                            .foregroundStyle(DSColor.textPrimary)
                            .frame(width: DSLayout.homeEditorPhotoBadgeSize, height: DSLayout.homeEditorPhotoBadgeSize)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityHidden(true)
                    }
            }
            .accessibilityIdentifier("homeEditor.photo")

            Button(action: openConfigurations) {
                Text(name)
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: DSLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityHint(localized("首頁配置"))
            .accessibilityIdentifier("homeEditor.configuration")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.xl)
    }
}

#if DEBUG
#Preview("編輯首頁的頂部") {
    NavigationStack {
        ScrollView {
            HomeEditorHeader(openConfigurations: {})
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
    }
}

#Preview("編輯首頁的頂部，輔助使用字級") {
    NavigationStack {
        ScrollView {
            HomeEditorHeader(openConfigurations: {})
        }
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
