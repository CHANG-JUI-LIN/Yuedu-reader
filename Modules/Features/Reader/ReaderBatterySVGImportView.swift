import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReaderBatterySVGImportView: View {
    @Environment(\.dismiss) private var dismiss

    let store: ReaderOverlaySVGAssetStore
    let referencedAssetIDs: Set<UUID>

    @State private var assets: [ReaderOverlaySVGAsset] = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var showingImporter = false
    @State private var issue: ReaderBatterySVGImportIssue?
    @State private var assetPendingRename: ReaderOverlaySVGAsset?
    @State private var renameDraft = ""
    @State private var assetPendingDeletion: ReaderOverlaySVGAsset?

    init(
        store: ReaderOverlaySVGAssetStore,
        referencedAssetIDs: Set<UUID> = []
    ) {
        self.store = store
        self.referencedAssetIDs = referencedAssetIDs
    }

    var body: some View {
        NavigationStack {
            List {
                if let issue {
                    Section {
                        Label(localized(issue.messageKey), systemImage: "exclamationmark.triangle")
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.destructive)
                            .accessibilityElement(children: .combine)
                        if issue == .loadFailed {
                            Button(localized("重試")) {
                                isLoading = true
                                Task { await reload() }
                            }
                        }
                    }
                    .listRowBackground(DSColor.surface)
                }

                Section {
                    content
                } header: {
                    Text(localized("電量 SVG 模板"))
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label(localized("匯入 SVG"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)
                } footer: {
                    Text(localized("只會匯入通過安全驗證的 SVG，動態標記會保留供分享。"))
                }
            }
            .navigationTitle(localized("電量 SVG 模板"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isImporting)
                    .accessibilityLabel(localized("匯入 SVG"))
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: Self.svgContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .alert(
            localized("重新命名"),
            isPresented: Binding(
                get: { assetPendingRename != nil },
                set: { if !$0 { assetPendingRename = nil } }
            )
        ) {
            TextField(localized("模板名稱"), text: $renameDraft)
            Button(localized("取消"), role: .cancel) {
                assetPendingRename = nil
            }
            Button(localized("儲存")) {
                renamePendingAsset()
            }
        }
        .confirmationDialog(
            localized("刪除 SVG 模板？"),
            isPresented: Binding(
                get: { assetPendingDeletion != nil },
                set: { if !$0 { assetPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: assetPendingDeletion
        ) { asset in
            Button(localized("刪除"), role: .destructive) {
                delete(asset)
            }
            Button(localized("取消"), role: .cancel) {
                assetPendingDeletion = nil
            }
        } message: { asset in
            if referencedAssetIDs.contains(asset.id) {
                Text(localized("此模板仍被頁首頁尾使用。刪除後會自動改用系統電池圖示。"))
            } else {
                Text(localized("此模板會被永久刪除。"))
            }
        }
        .task {
            await reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack(spacing: DSSpacing.sm) {
                ProgressView()
                Text(localized("正在載入 SVG 模板"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if assets.isEmpty {
            ContentUnavailableView {
                Label(localized("尚無電量 SVG 模板"), systemImage: "battery.100")
            } description: {
                Text(localized("匯入 SVG 模板後，可用於閱讀頁的電量元件。"))
            } actions: {
                Button(localized("匯入 SVG")) {
                    showingImporter = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ForEach(assets) { asset in
                ReaderBatterySVGAssetRow(
                    asset: asset,
                    store: store,
                    onRename: { beginRename(asset) },
                    onDelete: { assetPendingDeletion = asset },
                    onError: { issue = $0 }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        assetPendingDeletion = asset
                    } label: {
                        Label(localized("刪除"), systemImage: "trash")
                    }
                    Button {
                        beginRename(asset)
                    } label: {
                        Label(localized("重新命名"), systemImage: "pencil")
                    }
                    .tint(DSColor.accent)
                }
            }
        }

        if isImporting {
            HStack(spacing: DSSpacing.sm) {
                ProgressView()
                Text(localized("正在驗證 SVG 模板"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static let svgContentTypes: [UTType] = [
        UTType(filenameExtension: "svg") ?? .xml,
        .xml
    ]

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            isImporting = true
            issue = nil
            Task {
                do {
                    _ = try await store.importSVG(from: url)
                    await reload()
                } catch {
                    issue = .importFailed
                }
                isImporting = false
            }
        case .failure:
            issue = .importFailed
        }
    }

    private func beginRename(_ asset: ReaderOverlaySVGAsset) {
        renameDraft = asset.displayName
        assetPendingRename = asset
    }

    private func renamePendingAsset() {
        guard let asset = assetPendingRename else { return }
        let draft = renameDraft
        assetPendingRename = nil
        Task {
            do {
                _ = try await store.rename(id: asset.id, displayName: draft)
                await reload()
            } catch ReaderOverlaySVGAssetStoreError.invalidDisplayName {
                issue = .invalidName
            } catch {
                issue = .operationFailed
            }
        }
    }

    private func delete(_ asset: ReaderOverlaySVGAsset) {
        assetPendingDeletion = nil
        Task {
            do {
                try await store.delete(id: asset.id)
                await reload()
            } catch {
                issue = .operationFailed
            }
        }
    }

    @MainActor
    private func reload() async {
        do {
            assets = try await store.assets()
            issue = nil
        } catch {
            assets = []
            issue = .loadFailed
        }
        isLoading = false
    }
}

private struct ReaderBatterySVGAssetRow: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    let asset: ReaderOverlaySVGAsset
    let store: ReaderOverlaySVGAssetStore
    let onRename: () -> Void
    let onDelete: () -> Void
    let onError: (ReaderBatterySVGImportIssue) -> Void

    @State private var previewImage: UIImage?
    @State private var exportURL: URL?
    @State private var usesFallbackPreview = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            preview

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(asset.displayName)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                if usesFallbackPreview {
                    Label(
                        localized("模板無法載入，將使用系統電池。"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                }
            }

            Spacer(minLength: DSSpacing.sm)

            Menu {
                Button(action: onRename) {
                    Label(localized("重新命名"), systemImage: "pencil")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(localized("分享 SVG"), systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label(localized("刪除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(
                        minWidth: DSLayout.readerAppleBooksControlSize,
                        minHeight: DSLayout.readerAppleBooksControlSize
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(localized("更多操作"))
        }
        .task(id: asset) {
            await loadPreviewAndExport()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .frame(
                    width: DSLayout.readerBatterySVGPreviewWidth,
                    height: DSLayout.readerBatterySVGPreviewHeight
                )
                .accessibilityHidden(true)
        } else {
            Image(systemName: "battery.100")
                .font(DSFont.title2)
                .foregroundStyle(DSColor.textPrimary)
                .frame(
                    width: DSLayout.readerBatterySVGPreviewWidth,
                    height: DSLayout.readerBatterySVGPreviewHeight
                )
                .accessibilityHidden(true)
        }
    }

    @MainActor
    private func loadPreviewAndExport() async {
        do {
            let source = try await store.source(for: asset.id)
            let template = try ReaderBatterySVGTemplate(source: source)
            let rgbaHex = try UIColor(DSColor.textPrimary).rgbaHex(for: colorScheme)
            let pixelSize = CGSize(
                width: DSLayout.readerBatterySVGPreviewWidth * displayScale,
                height: DSLayout.readerBatterySVGPreviewHeight * displayScale
            )
            previewImage = try await SVGWebViewRasterizer.shared.renderBattery(
                template: template,
                level: 0.72,
                isCharging: false,
                colorHex: rgbaHex,
                pixelSize: pixelSize,
                displayScale: displayScale
            )
            usesFallbackPreview = previewImage == nil
        } catch {
            previewImage = nil
            usesFallbackPreview = true
        }

        do {
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReaderOverlaySVGExports", isDirectory: true)
            exportURL = try await store.exportURL(for: asset.id, in: exportDirectory)
        } catch {
            exportURL = nil
            onError(.operationFailed)
        }
    }
}

private enum ReaderBatterySVGImportIssue: Identifiable, Equatable {
    case importFailed
    case loadFailed
    case invalidName
    case operationFailed

    var id: String { messageKey }

    var messageKey: String {
        switch self {
        case .importFailed:
            "SVG 模板匯入失敗。請確認檔案是安全且有效的 SVG。"
        case .loadFailed:
            "SVG 模板載入失敗。"
        case .invalidName:
            "模板名稱不能為空白。"
        case .operationFailed:
            "SVG 模板操作失敗。"
        }
    }
}

private enum ReaderBatterySVGPreviewError: Error {
    case unresolvedColor
}

private extension UIColor {
    func rgbaHex(for colorScheme: ColorScheme) throws -> String {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            throw ReaderBatterySVGPreviewError.unresolvedColor
        }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
            Int((alpha * 255).rounded())
        )
    }
}

#Preview {
    ReaderBatterySVGImportView(
        store: ReaderOverlaySVGAssetStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ReaderBatterySVGImportPreview", isDirectory: true)
        )
    )
}
