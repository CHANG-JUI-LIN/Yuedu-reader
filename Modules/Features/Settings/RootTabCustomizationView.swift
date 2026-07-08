import SwiftUI
import UniformTypeIdentifiers

struct RootTabCustomizationView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @State private var showPaywall = false
    @State private var showingIconImporter = false
    @State private var iconImportTarget: RootTabIconImportTarget?
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
            }

            visibleTabsSection
            tabPresentationSection

            ForEach(RootTabItem.allCases) { tab in
                iconSection(for: tab)
            }
        }
        .navigationTitle(localized("底部 Tab"))
        .toolbarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingIconImporter,
            allowedContentTypes: Self.iconContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleIconImport(result)
        }
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
                    Text(settings.usesCustomRootTabIconSize ? "\(Int(settings.rootTabIconSize)) pt" : localized("系統默認"))
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
                        Text("\(Int(settings.rootTabIconSize)) pt")
                            .font(DSFont.body.monospacedDigit())
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    Slider(
                        value: iconSizeBinding,
                        in: 22...36,
                        step: 1
                    )
                    .disabled(!canCustomize)
                }
            }
        }
    }

    private func iconSection(for tab: RootTabItem) -> some View {
        Section(header: Text(localized(tab.titleKey))) {
            ForEach(RootTabIconSlot.allCases) { slot in
                iconRow(tab: tab, slot: slot)
            }
        }
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

            Menu {
                Button {
                    guard canCustomize else {
                        showPaywall = true
                        return
                    }
                    iconImportTarget = RootTabIconImportTarget(tab: tab, slot: slot)
                    showingIconImporter = true
                } label: {
                    Label(localized("選擇圖片"), systemImage: "photo")
                }

                if asset != nil {
                    Button(role: .destructive) {
                        guard canCustomize else {
                            showPaywall = true
                            return
                        }
                        settings.deleteRootTabIcon(tab: tab, slot: slot)
                    } label: {
                        Label(localized("移除圖片"), systemImage: "trash")
                    }
                }
            } label: {
                Label(localized("選擇圖片"), systemImage: "chevron.down")
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
                .font(.system(size: 24, weight: .regular))
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

    private func handleIconImport(_ result: Result<[URL], Error>) {
        do {
            guard canCustomize else {
                showPaywall = true
                return
            }
            guard let target = iconImportTarget,
                  let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try settings.importRootTabIcon(from: url, tab: target.tab, slot: target.slot)
            iconImportTarget = nil
        } catch {
            iconImportError = RootTabIconImportError(message: error.localizedDescription)
        }
    }

    private static let iconContentTypes: [UTType] = [
        .image,
        UTType(filenameExtension: "webp") ?? .data,
    ]
}

private struct RootTabIconImportTarget: Identifiable {
    var id: String { "\(tab.rawValue)-\(slot.rawValue)" }
    let tab: RootTabItem
    let slot: RootTabIconSlot
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
