import SwiftUI

// The maintainer, 2026-10-27, after an Emby client's home editor: 編輯首頁 opens on the
// 首頁配置 it edits, in the 頂部輪播圖's place. Its photo, with a camera badge, changes the
// photo (`HomeConfigurationPhotoPicker`, the form's own); its name pushes 首頁配置's page, where
// it is switched, added and renamed; 選擇輪播數據 pushes 選擇內容來源 for the 輪播圖 alone; and
// 關閉輪播圖 hides it, keeping what it shows, or 開啟輪播圖 shows it again.

struct HomeEditorHeader: View {
    /// Pushes 首頁配置's page.
    let openConfigurations: () -> Void
    /// Pushes 選擇輪播數據.
    let chooseCarousel: () -> Void

    @ObservedObject private var pageStore = HomePageStore.shared
    @ObservedObject private var photos = HomePageStore.shared.photos

    private var configurationID: HomeConfigurationID { pageStore.selectedConfiguration }

    private var name: String {
        pageStore.configurations.first { $0.id == configurationID }?.name ?? ""
    }

    private var carousel: HomeSection? { pageStore.page?.carouselSection }

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            HomeConfigurationPhotoPicker(configurationID: configurationID) {
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

            VStack(spacing: DSSpacing.xs) {
                Button(action: chooseCarousel) {
                    Text(localized("選擇輪播數據"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("homeEditor.chooseCarousel")

                if let carousel {
                    Button {
                        pageStore.edit { $0.setCarouselShown(!carousel.isEnabled) }
                    } label: {
                        Text(localized(carousel.isEnabled ? "關閉輪播圖" : "開啟輪播圖"))
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textSecondary)
                            .frame(minHeight: DSLayout.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("homeEditor.toggleCarousel")
                }
            }
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
            HomeEditorHeader(openConfigurations: {}, chooseCarousel: {})
        }
        .background(PageBackgroundView(scope: .explore).ignoresSafeArea())
    }
}

#Preview("編輯首頁的頂部，輔助使用字級") {
    NavigationStack {
        ScrollView {
            HomeEditorHeader(openConfigurations: {}, chooseCarousel: {})
        }
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
