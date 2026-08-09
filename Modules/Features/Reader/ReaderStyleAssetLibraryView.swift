import SwiftUI
import UIKit

struct ReaderStyleAssetLibraryView: View {
    let referenceScope: String
    let references: [UUID: [ReaderStyleAssetReference]]
    let onSelect: (ReaderStyleAsset) -> Void
    let onDeleteReferencedAsset: (UUID) async throws -> Void

    @State private var assets: [ReaderStyleAsset] = []
    @State private var isLoading = true
    @State private var editingAsset: ReaderStyleAsset?
    @State private var pendingDeletion: ReaderStyleAsset?
    @State private var renameText = ""
    @State private var alert: ReaderStyleAssetLibraryAlert?

    init(
        referenceScope: String = "reader-style-library",
        references: [UUID: [ReaderStyleAssetReference]],
        onSelect: @escaping (ReaderStyleAsset) -> Void,
        onDeleteReferencedAsset: @escaping (UUID) async throws -> Void
    ) {
        self.referenceScope = referenceScope
        self.references = references
        self.onSelect = onSelect
        self.onDeleteReferencedAsset = onDeleteReferencedAsset
    }

    private var referenceFingerprint: String {
        references
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString):\($0.value.count)" }
            .joined(separator: "|")
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView(localized("正在載入素材"))
                    .frame(maxWidth: .infinity)
            } else if assets.isEmpty {
                ContentUnavailableView(
                    localized("尚無素材"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(localized("從相簿或檔案加入圖片，之後可供所有閱讀樣式重用。"))
                )
            } else {
                ForEach(assets) { asset in
                    assetRow(asset)
                }
            }
        }
        .navigationTitle(localized("素材庫"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ImageSourcePickerButton(
                    accessibilityTitle: localized("加入圖片"),
                    onPick: { handlePick($0, replacing: nil) }
                ) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
            }
        }
        .task(id: referenceFingerprint) {
            await ReaderStyleAssetStore.shared.replaceReferences(
                references,
                scope: referenceScope
            )
            await reload()
        }
        .alert(localized("重新命名素材"), isPresented: Binding(
            get: { editingAsset != nil },
            set: { if !$0 { editingAsset = nil } }
        )) {
            TextField(localized("名稱"), text: $renameText)
            Button(localized("取消"), role: .cancel) { editingAsset = nil }
            Button(localized("儲存")) { renameSelectedAsset() }
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { asset in
            Button(localized("取消"), role: .cancel) {}
            Button(localized("刪除"), role: .destructive) {
                delete(asset, removingReferences: !(references[asset.id] ?? []).isEmpty)
            }
        } message: { asset in
            Text(deleteMessage(for: asset))
        }
        .alert(item: $alert) { value in
            Alert(
                title: Text(localized(value.titleKey)),
                message: Text(value.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    private func assetRow(_ asset: ReaderStyleAsset) -> some View {
        Button { onSelect(asset) } label: {
            Label {
                LabeledContent(asset.name, value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
            } icon: {
                ReaderStyleAssetThumbnail(assetID: asset.id)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            }
        }
        .badge(references[asset.id]?.count ?? 0)
        .accessibilityLabel(asset.name)
        .accessibilityValue(assetAccessibilityValue(asset))
        .accessibilityHint(localized("套用這個素材"))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDeletion = asset } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
            Button { beginRename(asset) } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }
            .tint(DSColor.accent)
        }
        .contextMenu {
            Button { beginRename(asset) } label: {
                Label(localized("重新命名"), systemImage: "pencil")
            }
            ImageSourcePickerButton(
                accessibilityTitle: localized("替換圖片"),
                onPick: { handlePick($0, replacing: asset) }
            ) {
                Label(localized("替換圖片"), systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) { pendingDeletion = asset } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
        }
    }

    private func assetAccessibilityValue(_ asset: ReaderStyleAsset) -> String {
        let dimensions = "\(asset.pixelWidth) × \(asset.pixelHeight)"
        let count = references[asset.id]?.count ?? 0
        guard count > 0 else { return dimensions }
        return [dimensions, String(format: localized("%d 個引用"), count)]
            .joined(separator: localized("、"))
    }

    private var deleteTitle: String {
        guard let pendingDeletion else { return localized("刪除素材？") }
        return (references[pendingDeletion.id] ?? []).isEmpty
            ? localized("刪除素材？")
            : localized("刪除素材與引用？")
    }

    private func deleteMessage(for asset: ReaderStyleAsset) -> String {
        let count = references[asset.id]?.count ?? 0
        if count == 0 {
            return String(format: localized("「%@」會被永久刪除。"), asset.name)
        }
        let owners = (references[asset.id] ?? [])
            .map(\.displayName)
            .joined(separator: localized("、"))
        return String(
            format: localized("「%@」目前有 %d 個引用（%@）。強制刪除後，這些樣式會移除對該圖片的設定。"),
            asset.name,
            count,
            owners
        )
    }

    private func beginRename(_ asset: ReaderStyleAsset) {
        renameText = asset.name
        editingAsset = asset
    }

    private func renameSelectedAsset() {
        guard let asset = editingAsset else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingAsset = nil
        Task {
            do {
                try await ReaderStyleAssetStore.shared.rename(asset.id, to: name)
                await reload()
            } catch {
                showError(error)
            }
        }
    }

    private func handlePick(
        _ result: Result<PickedImageSource, PickedImageError>,
        replacing asset: ReaderStyleAsset?
    ) {
        do {
            let (data, name) = try pickedImageData(result)
            Task {
                do {
                    if let asset {
                        _ = try await ReaderStyleAssetStore.shared.replaceImage(
                            id: asset.id,
                            data: data,
                            suggestedName: name
                        )
                    } else {
                        _ = try await ReaderStyleAssetStore.shared.importImage(
                            data: data,
                            suggestedName: name
                        )
                    }
                    await reload()
                } catch {
                    showError(error)
                }
            }
        } catch {
            showError(error)
        }
    }

    private func pickedImageData(
        _ result: Result<PickedImageSource, PickedImageError>
    ) throws -> (Data, String) {
        switch try result.get() {
        case .data(let data):
            return (data, localized("相簿圖片"))
        case .file(let url):
            return (try Data(contentsOf: url), url.deletingPathExtension().lastPathComponent)
        }
    }

    private func delete(_ asset: ReaderStyleAsset, removingReferences: Bool) {
        pendingDeletion = nil
        Task {
            do {
                if removingReferences {
                    try await onDeleteReferencedAsset(asset.id)
                } else {
                    try await ReaderStyleAssetStore.shared.delete(
                        asset.id,
                        removingReferences: false
                    )
                }
                await reload()
            } catch {
                showError(error)
            }
        }
    }

    @MainActor
    private func reload() async {
        assets = await ReaderStyleAssetStore.shared.assets()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    @MainActor
    private func showError(_ error: Error) {
        alert = ReaderStyleAssetLibraryAlert(
            titleKey: "操作失敗",
            message: error.localizedDescription
        )
    }
}

private struct ReaderStyleAssetThumbnail: View {
    let assetID: UUID
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                DSColor.groupedBackground
                    .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(DSColor.textSecondary)
                        .accessibilityHidden(true)
                    }
            }
        }
        .task(id: assetID) {
            if let cached = await ReaderStyleAssetStore.shared.cachedImage(for: assetID) {
                image = cached
                return
            }
            image = try? await ReaderStyleAssetStore.shared.loadCachedImage(for: assetID)
        }
    }
}

private struct ReaderStyleAssetLibraryAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private extension ReaderStyleAssetReference {
    var displayName: String {
        switch self {
        case .chapterLayer(let name):
            return String(format: localized("章節圖層：%@"), name)
        case .regexRule(let name):
            return String(format: localized("正則規則：%@"), name)
        }
    }
}

#Preview {
    NavigationStack {
        ReaderStyleAssetLibraryView(
            references: [:],
            onSelect: { _ in },
            onDeleteReferencedAsset: { _ in }
        )
    }
}
