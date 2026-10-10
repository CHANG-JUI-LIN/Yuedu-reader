import SwiftUI
import UIKit

/// Making or editing one saved reading background: its name, a colour or a picture, and
/// its text colour. Pushed inside the reader's quick panel — a page in the panel's own
/// navigation, not a sheet over it.
struct ReaderCustomBackgroundEditorView: View {
    enum Kind: Hashable {
        case color
        case picture
    }

    /// Nil for a new background.
    let original: ReaderCustomBackground?
    let onSave: (ReaderCustomBackground) -> Void
    let onDelete: () -> Void
    let onRequestPaywall: (PremiumFeature) -> Void

    @Bindable private var settings = GlobalSettings.shared
    @ObservedObject private var subscriptionStore = SubscriptionStore.shared
    @State private var name: String
    @State private var kind: Kind
    @State private var color: Color
    @State private var picture: ReaderBackgroundPicture?
    @State private var automaticTextColor: Bool
    @State private var textColor: Color
    @State private var importFailure: String?
    @State private var showDeleteConfirmation = false
    /// Pictures imported on this page, deleted when it closes unless a saved background
    /// shows them — a picture tried and replaced, or a page left without saving.
    @State private var importedFileNames: [String] = []

    init(
        original: ReaderCustomBackground?,
        onSave: @escaping (ReaderCustomBackground) -> Void,
        onDelete: @escaping () -> Void,
        onRequestPaywall: @escaping (PremiumFeature) -> Void
    ) {
        self.original = original
        self.onSave = onSave
        self.onDelete = onDelete
        self.onRequestPaywall = onRequestPaywall
        _name = State(initialValue: original?.name ?? "")
        _kind = State(initialValue: original?.isImage == true ? .picture : .color)
        _color = State(initialValue: Color(uiColor: AppearanceThemePreset.hex(original?.colorHex ?? 0xF4F5F7)))
        _picture = State(initialValue: original.flatMap { background in
            background.imageFileName.map {
                ReaderBackgroundPicture(fileName: $0, averageColorHex: background.colorHex, isDark: background.isDark)
            }
        })
        _automaticTextColor = State(initialValue: original?.textColorHex == nil)
        _textColor = State(initialValue: Color(uiColor: AppearanceThemePreset.hex(
            original?.resolvedTextColorHex ?? ReaderCustomBackground.darkTextHex
        )))
    }

    var body: some View {
        Form {
            Section {
                preview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                TextField(localized("名稱"), text: $name, prompt: Text(defaultName))
                    .font(DSFont.body)
            } header: {
                Text(localized("名稱"))
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                Picker(localized("類型"), selection: $kind) {
                    Text(localized("顏色")).tag(Kind.color)
                    Text(localized("圖片")).tag(Kind.picture)
                }
                .pickerStyle(.segmented)

                switch kind {
                case .color:
                    ColorPicker(selection: $color, supportsOpacity: false) {
                        SettingsRowLabel(localized("背景顏色"), systemImage: "paintpalette")
                    }
                case .picture:
                    pictureRow
                }
            } header: {
                Text(localized("背景"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                if kind == .picture {
                    Text(localized("圖片會直接顯示在閱讀背景與主題預覽中。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            Section {
                Toggle(isOn: $automaticTextColor) {
                    SettingsRowLabel(localized("自動文字顏色"), systemImage: "paintbrush")
                }
                if !automaticTextColor {
                    ColorPicker(selection: $textColor, supportsOpacity: false) {
                        SettingsRowLabel(localized("文字顏色"), systemImage: "paintbrush.pointed")
                    }
                }
            } header: {
                Text(localized("文字"))
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            if original != nil {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRowLabel(localized("刪除這個背景"), systemImage: "trash", role: .destructive)
                    }
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
        .navigationTitle(localized("自定義閱讀背景"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: save) {
                    Image(systemName: "checkmark")
                }
                .disabled(!canSave)
                .accessibilityLabel(localized("儲存"))
            }
        }
        .alert(
            localized("閱讀背景匯入失敗"),
            isPresented: Binding(
                get: { importFailure != nil },
                set: { if !$0 { importFailure = nil } }
            )
        ) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(importFailure ?? "")
        }
        .alert(
            String(format: localized("刪除「%@」？"), original?.name ?? ""),
            isPresented: $showDeleteConfirmation
        ) {
            Button(localized("刪除"), role: .destructive) {
                guard let original else { return }
                settings.deleteReaderCustomBackground(id: original.id)
                onDelete()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("正在使用這個背景的地方會改用內建的閱讀背景。"))
        }
        .onDisappear {
            for fileName in importedFileNames {
                settings.discardReaderBackgroundPicture(fileName: fileName)
            }
        }
    }

    // MARK: - Pieces

    /// The page as it will read: the background, and a line of text in its text colour.
    private var preview: some View {
        ZStack {
            Rectangle().fill(previewPageColor)
            if kind == .picture,
               let fileName = picture?.fileName,
               let image = ReaderCustomBackgroundStorageManager.shared.thumbnail(fileName: fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            Text(localized("這是閱讀時文字的樣子。"))
                .font(DSFont.body)
                .foregroundStyle(Color(uiColor: AppearanceThemePreset.hex(previewTextHex)))
                .padding(DSSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DSLayout.readerQuickPanelReadingBackgroundTileHeight * 1.6)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                .stroke(DSColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("預覽"))
    }

    @ViewBuilder
    private var pictureRow: some View {
        if ReaderPremiumVisibilityPolicy(isProActive: subscriptionStore.isProActive).showsBackgroundImageImport {
            ImageSourcePickerButton(
                accessibilityTitle: localized("導入圖片背景"),
                onPick: importPicture
            ) {
                SettingsRowLabel(localized("導入圖片背景"), systemImage: "photo", role: .action)
            }
        } else {
            SettingsLockedRow(title: localized("導入圖片背景"), systemImage: "photo") {
                onRequestPaywall(.readerBackgroundImport)
            }
        }
    }

    // MARK: - State

    private var defaultName: String {
        original?.name ?? ReaderCustomBackgroundLibrary.unusedName(
            base: localized("自訂背景"),
            among: settings.readerCustomBackgrounds
        )
    }

    private var canSave: Bool {
        kind == .color || picture != nil
    }

    private var colorHex: UInt32 {
        UIColor(color).rgbHex ?? 0xF4F5F7
    }

    private var isDark: Bool {
        switch kind {
        case .color: return ReaderBackgroundTone.isDark(rgbHex: colorHex)
        case .picture: return picture?.isDark ?? false
        }
    }

    private var previewPageColor: Color {
        let hex = kind == .picture ? (picture?.averageColorHex ?? 0xF4F5F7) : colorHex
        return Color(uiColor: AppearanceThemePreset.hex(hex))
    }

    private var previewTextHex: UInt32 {
        if !automaticTextColor, let custom = UIColor(textColor).rgbHex { return custom }
        return isDark ? ReaderCustomBackground.lightTextHex : ReaderCustomBackground.darkTextHex
    }

    // MARK: - Actions

    private func importPicture(_ result: Result<PickedImageSource, PickedImageError>) {
        do {
            let imported: ReaderBackgroundPicture
            switch result {
            case .success(.data(let data)):
                imported = try settings.importReaderBackgroundPicture(data: data)
            case .success(.file(let url)):
                imported = try settings.importReaderBackgroundPicture(from: url)
            case .failure(let error):
                importFailure = localized(error.messageKey)
                return
            }
            importedFileNames.append(imported.fileName)
            picture = imported
        } catch let error as ReaderCustomBackgroundStorageError {
            importFailure = localized(error.messageKey)
        } catch {
            AppLogger.error("⟐ reading background picture import failed", error: error)
            importFailure = localized("無法匯入圖片背景。")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesPicture = kind == .picture
        guard !usesPicture || picture != nil else { return }
        let saved = settings.saveReaderCustomBackground(ReaderCustomBackground(
            id: original?.id ?? UUID(),
            name: trimmed.isEmpty ? defaultName : trimmed,
            colorHex: usesPicture ? (picture?.averageColorHex ?? colorHex) : colorHex,
            imageFileName: usesPicture ? picture?.fileName : nil,
            textColorHex: automaticTextColor ? nil : UIColor(textColor).rgbHex,
            isDark: isDark
        ))
        onSave(saved)
    }
}

#Preview {
    NavigationStack {
        ReaderCustomBackgroundEditorView(
            original: nil,
            onSave: { _ in },
            onDelete: {},
            onRequestPaywall: { _ in }
        )
    }
}
