import SwiftUI
import UniformTypeIdentifiers

/// 外觀 → 閱讀界面 → 經典 → 自定義 → 底部圖示. Which of 目錄／書籤／深色／設置 the
/// classic bottom bar draws, and what artwork each one uses.
struct ReaderClassicToolIconSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @State private var importError: ReaderClassicToolIconImportError?

    var body: some View {
        Form {
            visibilitySection
            iconSection
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("底部圖示"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .alert(item: $importError) { error in
            Alert(
                title: Text(localized("圖標導入失敗")),
                message: Text(error.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    private var visibilitySection: some View {
        Section {
            ForEach(ReaderClassicToolItem.allCases) { item in
                if item.isAlwaysVisible {
                    HStack {
                        Label(localized(item.titleKey), systemImage: item.defaultSystemImage)
                            .labelStyle(IconConsistentLabelStyle())
                        Spacer(minLength: DSSpacing.md)
                        Text(localized("固定顯示"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } else {
                    Toggle(isOn: visibleBinding(for: item)) {
                        Label(localized(item.titleKey), systemImage: item.defaultSystemImage)
                            .labelStyle(IconConsistentLabelStyle())
                    }
                }
            }
        } header: {
            Text(localized("顯示"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
        } footer: {
            Text(localized("關掉的按鈕會整個離開工具列。設置固定顯示——它是經典介面回到閱讀設定的唯一入口。"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    private var iconSection: some View {
        Section {
            ForEach(ReaderClassicToolItem.allCases) { item in
                iconRow(for: item)
            }
        } header: {
            Text(localized("圖示"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
        } footer: {
            Text(localized("匯入的圖片會以自己的顏色顯示，不跟著底部圖示顏色變。"))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    private func iconRow(for item: ReaderClassicToolItem) -> some View {
        let asset = settings.readerClassicToolIcon(for: item)
        return HStack(spacing: DSSpacing.md) {
            glyphPreview(for: item)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(localized(item.titleKey))
                    .foregroundStyle(DSColor.textPrimary)
                Text(asset?.originalFileName ?? localized("未選擇圖片"))
                    .font(DSFont.caption)
                    .foregroundStyle(asset == nil ? DSColor.textSecondary : DSColor.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: DSSpacing.md)

            ImageSourcePickerButton(
                accessibilityTitle: localized(item.titleKey),
                contentTypes: Self.iconContentTypes,
                extraActions: asset == nil ? [] : [
                    ImageSourcePickerAction(
                        title: localized("移除圖片"),
                        systemImage: "trash",
                        isDestructive: true,
                        action: { settings.deleteReaderClassicToolIcon(for: item) }
                    )
                ],
                onPick: { result in handleIconPick(result, item: item) }
            ) {
                Label(localized("選擇圖片"), systemImage: "photo")
                    .font(DSFont.subheadline)
            }
            .buttonStyle(.bordered)
        }
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private func glyphPreview(for item: ReaderClassicToolItem) -> some View {
        if let image = settings.readerClassicToolIconImage(for: item) {
            Image(uiImage: image)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: item.defaultSystemImage)
                .font(DSFont.fixed(size: 22, weight: .regular))
                .foregroundStyle(DSColor.textPrimary)
                .frame(width: 44, height: 44)
        }
    }

    private func visibleBinding(for item: ReaderClassicToolItem) -> Binding<Bool> {
        Binding(
            get: { settings.isReaderClassicToolVisible(item) },
            set: { settings.setReaderClassicTool(item, visible: $0) }
        )
    }

    private func handleIconPick(
        _ result: Result<PickedImageSource, PickedImageError>,
        item: ReaderClassicToolItem
    ) {
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importReaderClassicToolIcon(
                    data: data,
                    // Photos gives no file name; the row shows this under the title.
                    originalFileName: localized("相簿圖片"),
                    item: item
                )
            case .success(.file(let url)):
                try settings.importReaderClassicToolIcon(from: url, item: item)
            case .failure(let error):
                importError = ReaderClassicToolIconImportError(message: localized(error.messageKey))
            }
        } catch {
            importError = ReaderClassicToolIconImportError(message: error.localizedDescription)
        }
    }

    private static let iconContentTypes: [UTType] = [
        .image,
        UTType(filenameExtension: "webp") ?? .data,
    ]
}

private struct ReaderClassicToolIconImportError: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    NavigationStack {
        ReaderClassicToolIconSettingsView()
    }
}
