import SwiftUI
import UniformTypeIdentifiers

/// 外觀 → 閱讀界面 → 自定義 → 按鈕圖示. Which reader buttons are drawn and what
/// artwork each one uses.
///
/// The tools are the bottom bar's capsule; the actions are the book card that opens
/// from the cover circle, and the AI ones the bottom bar's 更多.
struct ReaderChromeIconSettingsView: View {
    @Bindable private var settings = GlobalSettings.shared
    @State private var importError: ReaderChromeIconImportError?
    /// Drives the reorder handles of the 底部工具 rows (#36); only that section has `onMove`.
    @State private var editMode: EditMode

    init(startsReordering: Bool = false) {
        _editMode = State(initialValue: startsReordering ? .active : .inactive)
    }

    var body: some View {
        Form {
            section(
                items: settings.orderedReaderChromeToolItems,
                headerKey: "底部工具",
                footerKey: "關掉的按鈕會整個離開工具列。主題固定顯示——它是回到閱讀設定的唯一入口。",
                reorder: ToolReorder(
                    move: { settings.moveReaderChromeTools(fromOffsets: $0, toOffset: $1) },
                    shift: { settings.moveReaderChromeTool($0, by: $1) }
                )
            )
            section(
                items: ReaderChromeActionItem.allCases.filter { !$0.isInMoreMenu },
                headerKey: "書籍動作",
                footerKey: "這些動作都在點封面圓圈之後的書卡裡。原本就不適用這本書的動作仍然不會出現。"
            )
            section(
                items: ReaderChromeActionItem.allCases.filter(\.isInMoreMenu),
                headerKey: "更多",
                footerKey: "這些動作在底部工具列的「更多」裡。"
            )
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("按鈕圖示"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        // Below the toolbar, so `EditButton` toggles this page's edit mode rather than the
        // one of the screen this page is pushed from (see `RootTabCustomizationView`).
        .environment(\.editMode, $editMode)
        .themedAppSurface(for: .settings)
        .alert(item: $importError) { error in
            Alert(
                title: Text(localized("圖標導入失敗")),
                message: Text(error.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    /// How a section's rows are rearranged; nil for the sections whose order is fixed.
    fileprivate struct ToolReorder {
        let move: (IndexSet, Int) -> Void
        let shift: (ReaderChromeToolItem, Int) -> Void
    }

    private func section<Item: ReaderChromeIconItem>(
        items: [Item],
        headerKey: String,
        footerKey: String,
        reorder: ToolReorder? = nil
    ) -> some View {
        Section {
            ForEach(items) { item in
                row(for: item, reorder: reorder)
            }
            .onMove(perform: reorder?.move)
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

    private func row<Item: ReaderChromeIconItem>(for item: Item, reorder: ToolReorder?) -> some View {
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
                // The row's name as one element, which carries the reorder actions: on the
                // row's VStack they would land on the picker and the switch as well.
                .accessibilityElement(children: .combine)
                .modifier(ToolReorderActions(item: item as? ReaderChromeToolItem, reorder: reorder))

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

/// 上移／下移 for VoiceOver and Switch Control, which cannot drag a handle — as
/// `MetadataFillSourcesView` does. Nothing for a row whose section keeps a fixed order.
private struct ToolReorderActions: ViewModifier {
    let item: ReaderChromeToolItem?
    let reorder: ReaderChromeIconSettingsView.ToolReorder?

    func body(content: Content) -> some View {
        if let item, let reorder {
            content
                .accessibilityAction(named: localized("上移")) { reorder.shift(item, -1) }
                .accessibilityAction(named: localized("下移")) { reorder.shift(item, 1) }
        } else {
            content
        }
    }
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

#Preview("Reordering") {
    NavigationStack {
        ReaderChromeIconSettingsView(startsReordering: true)
    }
}
