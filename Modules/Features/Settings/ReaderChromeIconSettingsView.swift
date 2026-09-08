import SwiftUI
import UniformTypeIdentifiers

/// 外觀 → 閱讀界面 → 自定義 → 按鈕圖示. Which reader buttons are drawn and what
/// artwork each one uses.
///
/// Both lists are shared by 經典 and 現代 — the reader uses one interface at a
/// time, and re-importing the same artwork per interface would be busywork. Which
/// *surface* each list appears on differs: the tools sit in the bottom bar of both,
/// while the actions are 經典's floating circles and 現代's book card.
struct ReaderChromeIconSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @State private var importError: ReaderChromeIconImportError?

    var body: some View {
        Form {
            section(
                items: ReaderChromeToolItem.allCases,
                headerKey: "底部工具",
                footerKey: "關掉的按鈕會整個離開工具列。設置固定顯示——它是回到閱讀設定的唯一入口。"
            )
            section(
                items: ReaderChromeActionItem.allCases,
                headerKey: "書籍動作",
                footerKey: "經典把這四個畫成浮在正文上的圓鈕，現代放在點封面圓圈之後的書卡裡。原本就不適用這本書的動作仍然不會出現。"
            )
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("按鈕圖示"))
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

    private func section<Item: ReaderChromeIconItem>(
        items: [Item],
        headerKey: String,
        footerKey: String
    ) -> some View {
        Section {
            ForEach(items) { item in
                row(for: item)
            }
        } header: {
            Text(localized(headerKey))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
        } footer: {
            Text(localized(footerKey))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private func row<Item: ReaderChromeIconItem>(for item: Item) -> some View {
        let asset = settings.readerChromeIcon(for: item)
        return VStack(spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.md) {
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
                            action: { settings.deleteReaderChromeIcon(for: item) }
                        )
                    ],
                    onPick: { result in handleIconPick(result, item: item) }
                ) {
                    Label(localized("選擇圖片"), systemImage: "photo")
                        .labelStyle(.iconOnly)
                        .font(DSFont.subheadline)
                }
                .buttonStyle(.bordered)
            }

            if item.isAlwaysVisible {
                HStack {
                    Text(localized("顯示"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                    Spacer(minLength: DSSpacing.md)
                    Text(localized("固定顯示"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            } else {
                Toggle(isOn: visibleBinding(for: item)) {
                    Text(localized("顯示"))
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .padding(.vertical, DSSpacing.xs)
    }

    @ViewBuilder
    private func glyphPreview<Item: ReaderChromeIconItem>(for item: Item) -> some View {
        if let image = settings.readerChromeIconImage(for: item) {
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

    private func visibleBinding<Item: ReaderChromeIconItem>(for item: Item) -> Binding<Bool> {
        Binding(
            get: { settings.isReaderChromeItemVisible(item) },
            set: { settings.setReaderChromeItem(item, visible: $0) }
        )
    }

    private func handleIconPick<Item: ReaderChromeIconItem>(
        _ result: Result<PickedImageSource, PickedImageError>,
        item: Item
    ) {
        do {
            switch result {
            case .success(.data(let data)):
                try settings.importReaderChromeIcon(
                    data: data,
                    // Photos gives no file name; the row shows this under the title.
                    originalFileName: localized("相簿圖片"),
                    item: item
                )
            case .success(.file(let url)):
                try settings.importReaderChromeIcon(from: url, item: item)
            case .failure(let error):
                importError = ReaderChromeIconImportError(message: localized(error.messageKey))
            }
        } catch {
            importError = ReaderChromeIconImportError(message: error.localizedDescription)
        }
    }

    private static let iconContentTypes: [UTType] = [
        .image,
        UTType(filenameExtension: "webp") ?? .data,
    ]
}

private struct ReaderChromeIconImportError: Identifiable {
    let id = UUID()
    let message: String
}

#Preview {
    NavigationStack {
        ReaderChromeIconSettingsView()
    }
}
