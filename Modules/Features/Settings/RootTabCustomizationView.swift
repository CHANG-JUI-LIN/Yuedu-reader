import SwiftUI
import UniformTypeIdentifiers

struct RootTabCustomizationView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var showPaywall = false
    @State private var iconImportError: RootTabIconImportError?

    private var canCustomize: Bool {
        subscriptionStore.hasAccess(.bottomBarCustomization)
    }

    var body: some View {
        Form {
            if !canCustomize {
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        Label(localized("底部 Tab 自定義需要 Pro"), systemImage: "lock.fill")
                    }
                }
                .interfaceSectionSurface()
            }

            visibleTabsSection
            tabPresentationSection

            ForEach(RootTabItem.allCases) { tab in
                iconSection(for: tab)
            }
        }
        .navigationTitle(localized("底部 Tab"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .alert(item: $iconImportError) { error in
            Alert(
                title: Text(localized("圖標導入失敗")),
                message: Text(error.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(highlightedFeature: .bottomBarCustomization)
                .environmentObject(subscriptionStore)
        }
    }

    private var visibleTabsSection: some View {
        Section(
            header: Text(localized("顯示頁面")),
            footer: Text(localized("至少保留一個內容頁，設定固定顯示，避免無法恢復頁面。"))
        ) {
            ForEach(RootTabItem.allCases) { tab in
                if tab.isAlwaysVisible {
                    HStack {
                        Label(localized(tab.titleKey), systemImage: tab.defaultSystemImage)
                            .labelStyle(IconConsistentLabelStyle())
                        Spacer(minLength: DSSpacing.md)
                        Text(localized("固定顯示"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } else {
                    Toggle(isOn: visibleBinding(for: tab)) {
                        Label(localized(tab.titleKey), systemImage: tab.defaultSystemImage)
                            .labelStyle(IconConsistentLabelStyle())
                    }
                    .disabled(!canCustomize)
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var tabPresentationSection: some View {
        Section(
            header: Text(localized("Tab 圖標")),
            footer: Text(localized("不調整時保持系統 Tab 默認大小；開啟自訂大小後才套用滑桿。"))
        ) {
            Toggle(isOn: hidesLabelsBinding) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(localized("隱藏標籤文字"))
                    Text(localized("開啟後 Tab 欄只顯示圖標，不顯示文字標籤"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            .disabled(!canCustomize)

            Toggle(isOn: customIconSizeEnabledBinding) {
                HStack {
                    Text(localized("自訂圖標大小"))
                    Spacer(minLength: DSSpacing.md)
                    Text(settings.usesCustomRootTabIconSize ? iconSizeText : localized("系統默認"))
                        .font(settings.usesCustomRootTabIconSize ? DSFont.body.monospacedDigit() : DSFont.body)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            .disabled(!canCustomize)

            if settings.usesCustomRootTabIconSize {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    HStack {
                        Text(localized("圖標大小"))
                        Spacer()
                        Text(iconSizeText)
                            .font(DSFont.body.monospacedDigit())
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    Slider(
                        value: iconSizeBinding,
                        in: 22...36,
                        step: 1
                    )
                    .disabled(!canCustomize)
                    // A bare Slider has no name and announces a fraction of its
                    // range instead of the size printed above it.
                    // docs/design.md §7.1, third trap.
                    .accessibilityLabel(localized("圖標大小"))
                    .accessibilityValue(iconSizeText)
                }
            }
        }
        .interfaceSectionSurface()
    }

    private func iconSection(for tab: RootTabItem) -> some View {
        Section(header: Text(localized(tab.titleKey))) {
            ForEach(RootTabIconSlot.allCases) { slot in
                iconRow(tab: tab, slot: slot)
            }
        }
        .interfaceSectionSurface()
    }

    private func iconRow(tab: RootTabItem, slot: RootTabIconSlot) -> some View {
        let asset = settings.rootTabIconAsset(for: tab, slot: slot)
        return HStack(spacing: DSSpacing.md) {
            tabIconPreview(tab: tab, slot: slot)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized(slot.titleKey))
                    .foregroundStyle(DSColor.textPrimary)
                Text(asset?.originalFileName ?? localized("未選擇圖片"))
                    .font(DSFont.caption)
                    .foregroundStyle(asset == nil ? DSColor.textSecondary : DSColor.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: DSSpacing.md)

            ImageSourcePickerButton(
                accessibilityTitle: "\(localized(tab.titleKey)) · \(localized(slot.titleKey))",
                contentTypes: Self.iconContentTypes,
                extraActions: asset == nil ? [] : [
                    ImageSourcePickerAction(
                        title: localized("移除圖片"),
                        systemImage: "trash",
                        isDestructive: true,
                        action: { settings.deleteRootTabIcon(tab: tab, slot: slot) }
                    )
                ],
                onPick: { result in handleIconPick(result, tab: tab, slot: slot) }
            ) {
                Label(localized("選擇圖片"), systemImage: "photo")
                    .font(DSFont.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(!canCustomize)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func tabIconPreview(tab: RootTabItem, slot: RootTabIconSlot) -> some View {
        if let asset = settings.rootTabIconAsset(for: tab, slot: slot),
           let url = settings.rootTabIconURL(for: asset),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: tab.defaultSystemImage)
                .font(DSFont.fixed(size: 24, weight: .regular))
                .foregroundStyle(DSColor.textPrimary)
                .frame(width: 44, height: 44)
        }
    }

    private var hidesLabelsBinding: Binding<Bool> {
        Binding(
            get: { settings.rootTabHidesLabels },
            set: { value in
                guard canCustomize else {
                    showPaywall = true
                    return
                }
                settings.rootTabHidesLabels = value
            }
        )
    }

    /// The one source for the printed size and the slider's VoiceOver value, so what
    /// is spoken can never drift from what is shown. Only read while
    /// `usesCustomRootTabIconSize` is true, which is when both call sites render.
    private var iconSizeText: String {
        "\(Int(settings.rootTabIconSize)) pt"
    }

    private var iconSizeBinding: Binding<Double> {
        Binding(
            get: {
                settings.usesCustomRootTabIconSize
                    ? settings.rootTabIconSize
                    : GlobalSettings.initialCustomRootTabIconSize
            },
            set: { value in
                guard canCustomize else {
                    showPaywall = true
                    return
                }
                settings.rootTabIconSize = value
            }
        )
    }

    private var customIconSizeEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.usesCustomRootTabIconSize },
            set: { value in
                guard canCustomize else {
                    showPaywall = true
                    return
                }
                settings.rootTabIconSize = value
                    ? GlobalSettings.initialCustomRootTabIconSize
                    : GlobalSettings.defaultRootTabIconSize
            }
        )
    }

    private func visibleBinding(for tab: RootTabItem) -> Binding<Bool> {
        Binding(
            get: { settings.isRootTabVisible(tab) },
            set: { value in
                guard canCustomize else {
                    showPaywall = true
                    return
                }
                settings.setRootTab(tab, visible: value)
            }
        )
    }

    private func handleIconPick(
        _ result: Result<PickedImageSource, PickedImageError>,
        tab: RootTabItem,
        slot: RootTabIconSlot
    ) {
        guard canCustomize else {
            showPaywall = true
            return
        }
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importRootTabIcon(
                    data: data,
                    // Photos gives no file name; the row shows this under the slot.
                    originalFileName: localized("相簿圖片"),
                    tab: tab,
                    slot: slot
                )
            case .success(.file(let url)):
                try settings.importRootTabIcon(from: url, tab: tab, slot: slot)
            case .failure(let error):
                iconImportError = RootTabIconImportError(message: localized(error.messageKey))
            }
        } catch {
            iconImportError = RootTabIconImportError(message: error.localizedDescription)
        }
    }

    private static let iconContentTypes: [UTType] = [
        .image,
        UTType(filenameExtension: "webp") ?? .data,
    ]
}

private struct RootTabIconImportError: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    NavigationStack {
        RootTabCustomizationView()
            .environmentObject(SubscriptionStore.shared)
    }
}
