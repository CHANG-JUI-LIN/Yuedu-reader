import SwiftUI

// 首頁配置's own page (maintainer, 2026-10-22, after Rex's 管理配置), from its button on the
// home, where ••• had a submenu until then. Every 首頁配置 with the photo the reader gave it; a
// tap switches to it and stays here. 編輯 reorders and deletes the reader's own — 預設 and 空白
// keep the top — and opens a configuration's photo and name, as its swipe does. New ones come
// from the two templates under the list.

struct HomeConfigurationsPage: View {
    @ObservedObject private var store = HomePageStore.shared
    @ObservedObject private var photos = HomePageStore.shared.photos
    @State private var prompt: HomeConfigurationPrompt?
    @State private var editMode: EditMode = .inactive
    /// The configuration whose photo and name are open.
    @State private var opened: HomeConfigurationID?

    var body: some View {
        let listings = store.configurations
        let own = listings.filter { !$0.id.isBuiltIn }
        List {
            Section {
                ForEach(listings.filter(\.id.isBuiltIn)) { row($0) }
                ForEach(own) { row($0) }
                    .onMove { store.moveConfigurations(fromOffsets: $0, toOffset: $1) }
                    // 編輯's delete asks first, as the swipe's does: the sections go with it.
                    .onDelete { offsets in
                        if let first = offsets.first { prompt = .delete(own[first]) }
                    }
            } header: {
                Text(localized("配置列表"))
            } footer: {
                Text(localized("點一下切換設定；進入編輯模式可調整順序。"))
                    .dsSectionFooter()
            }
            Section(localized("從設定範本新增")) {
                template(localized("空白模板"), subtitle: localized("沒有欄目，之後自行新增"),
                         systemImage: "rectangle.dashed", start: .blank)
                template(localized("預設配置"), subtitle: localized("從預設的欄目開始"),
                         systemImage: "square.stack", start: .defaults)
            }
        }
        .navigationTitle(localized("首頁配置"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .environment(\.editMode, $editMode)
        .navigationDestination(item: $opened) { id in
            HomeConfigurationForm(configurationID: id).hidesRootTabBar()
        }
        .homeConfigurationPrompts($prompt)
        .onAppear { photos.loadIfNeeded() }
    }

    private func row(_ configuration: HomeConfigurationListing) -> some View {
        let isSelected = configuration.id == store.selectedConfiguration
        return Button {
            if editMode.isEditing {
                opened = configuration.id
            } else {
                store.select(configuration.id)
            }
        } label: {
            HStack(spacing: DSSpacing.md) {
                HomeConfigurationPhoto(name: configuration.name, image: photos.images[configuration.id],
                                       size: DSLayout.homeConfigurationRowPhotoSize)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(configuration.name)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                    if let subtitle = subtitle(of: configuration.id) {
                        Text(subtitle)
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DSFont.body.weight(.semibold))
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // 編輯 folds the delete control into the row (「移除、名稱」), so what a double tap does
        // there is the list's: the photo and name are an action instead, as the swipe's are outside it.
        .accessibilityHint(editMode.isEditing || isSelected ? "" : localized("點兩下切換到這個首頁配置"))
        .accessibilityActions {
            if editMode.isEditing {
                Button(localized("編輯")) { opened = configuration.id }
            }
        }
        .accessibilityIdentifier("homeConfigurations.row.\(configuration.id.rawValue)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No destructive role: that takes the row away before the dialog has asked.
            if !configuration.id.isBuiltIn {
                Button { prompt = .delete(configuration) } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
                .tint(DSColor.destructive)
            }
            Button { opened = configuration.id } label: {
                Label(localized("編輯"), systemImage: "pencil")
            }
        }
    }

    /// 預設 and 空白 say what they are, as Rex's 默認 does; the reader's own are their name.
    private func subtitle(of id: HomeConfigurationID) -> String? {
        switch id {
        case .defaults: localized("內建的完整探索首頁")
        case .blank: localized("內建的空白首頁")
        default: nil
        }
    }

    private func template(_ title: String, subtitle: String, systemImage: String, start: HomeConfigurationID) -> some View {
        Button { prompt = .create(from: start) } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: systemImage)
                    .font(DSFont.title2)
                    .foregroundStyle(DSColor.textPrimary)
                    .frame(width: DSLayout.homeConfigurationRowPhotoSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(title)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(subtitle)
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editMode.isEditing)
        .accessibilityIdentifier("homeConfigurations.template.\(start.rawValue)")
    }
}

/// A 首頁配置's photo, round; without one, the first letter of its name. Decorative: the name
/// is beside it.
struct HomeConfigurationPhoto: View {
    let name: String
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(name.prefix(1))
                    .font(DSFont.fixed(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(DSColor.homeConfigurationMonogramForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DSColor.homeConfigurationMonogramFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// A 首頁配置's photo, from 相簿 or 檔案, and for the reader's own its name.
struct HomeConfigurationForm: View {
    let configurationID: HomeConfigurationID
    @ObservedObject private var store = HomePageStore.shared
    @ObservedObject private var photos = HomePageStore.shared.photos
    @State private var name = ""
    @State private var photoFailure: String?

    private var listing: HomeConfigurationListing? {
        store.configurations.first { $0.id == configurationID }
    }

    private var photo: UIImage? { photos.images[configurationID] }

    var body: some View {
        Form {
            Section {
                VStack(spacing: DSSpacing.md) {
                    HomeConfigurationPhoto(name: listing?.name ?? "", image: photo,
                                           size: DSLayout.homeConfigurationFormPhotoSize)
                    ImageSourcePickerButton(
                        accessibilityTitle: localized(photo == nil ? "加入照片" : "更換照片"),
                        extraActions: photo == nil ? [] : [
                            ImageSourcePickerAction(title: localized("移除照片"), systemImage: "trash", isDestructive: true) {
                                photos.removePhoto(for: configurationID)
                            },
                        ],
                        onPick: pick
                    ) {
                        Text(localized(photo == nil ? "加入照片" : "更換照片"))
                            .font(DSFont.body)
                    }
                    .accessibilityIdentifier("homeConfigurationForm.photo")
                }
                .frame(maxWidth: .infinity)
            }
            if !configurationID.isBuiltIn {
                Section(localized("名稱")) {
                    TextField(localized("名稱"), text: $name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                        .accessibilityIdentifier("homeConfigurationForm.name")
                }
            }
        }
        .navigationTitle(listing?.name ?? "")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            name = listing?.name ?? ""
            photos.loadIfNeeded()
        }
        // Back saves the name too: there is no 完成 on a pushed page.
        .onDisappear(perform: saveName)
        .alert(
            localized("無法加入照片"),
            isPresented: Binding(get: { photoFailure != nil }, set: { if !$0 { photoFailure = nil } })
        ) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(photoFailure ?? "")
        }
    }

    /// A blank name, or the one it has, changes nothing (`HomeConfigurations.rename`).
    private func saveName() {
        guard !configurationID.isBuiltIn, name != listing?.name else { return }
        store.renameConfiguration(configurationID, to: name)
    }

    private func pick(_ result: Result<PickedImageSource, PickedImageError>) {
        let data: Data
        switch result {
        case .success(.data(let picked)):
            data = picked
        case .success(.file(let url)):
            do {
                data = try Data(contentsOf: url)
            } catch {
                AppLogger.cache("⟐ 首頁配置 photo file could not be read", error: error, context: ["file": url.lastPathComponent])
                photoFailure = localized("無法讀取圖片。")
                return
            }
        case .failure(let error):
            AppLogger.cache("⟐ 首頁配置 photo could not be picked", error: error)
            photoFailure = localized(error.messageKey)
            return
        }
        Task {
            do {
                try await photos.setPhoto(data, for: configurationID)
            } catch {
                AppLogger.cache("⟐ 首頁配置 photo not saved", error: error, context: ["configuration": configurationID.rawValue])
                photoFailure = localized("無法讀取圖片。")
            }
        }
    }
}

#Preview("首頁配置") {
    NavigationStack {
        HomeConfigurationsPage()
    }
}

#Preview("照片，沒有照片時") {
    HStack(spacing: DSSpacing.lg) {
        HomeConfigurationPhoto(name: localized("預設"), image: nil, size: DSLayout.homeConfigurationRowPhotoSize)
        HomeConfigurationPhoto(name: "短劇", image: nil, size: DSLayout.homeConfigurationFormPhotoSize)
    }
}

#Preview("照片與名稱") {
    NavigationStack {
        HomeConfigurationForm(configurationID: .defaults)
    }
}
