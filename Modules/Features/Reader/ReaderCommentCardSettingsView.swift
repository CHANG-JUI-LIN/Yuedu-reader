import SwiftUI
import UIKit

/// 氣泡設定 › 本章說 / 作者說 / 神評論: the template one kind of review card is redrawn from.
struct ReaderCommentCardSettingsView: View {
    @Bindable private var settings = GlobalSettings.shared
    let kind: ReaderCommentCardKind
    /// 匯入樣式, handed to the first-level document picker; nil hides it.
    var onOpenImporter: (() -> Void)?
    @State private var editorDraft: CommentCardStyleDraft?
    @State private var stylePendingDeletion: ReaderCommentCardCustomStyle?

    var body: some View {
        Form {
            Section(header: Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)) {
                CommentCardTemplatePreview(
                    source: selectedSource,
                    kind: kind,
                    colorHex: selectedStyle?.colorHex(isNight: isNightReading),
                    isNight: isNightReading
                )
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("樣式")).foregroundStyle(DSColor.textSecondary)) {
                Picker(localized("樣式"), selection: selectionBinding) {
                    Text(localized("玻璃")).tag(UUID?.none)
                    ForEach(styles) { style in
                        Text(style.name).tag(UUID?.some(style.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .interfaceSectionSurface()

            Section {
                Toggle(localized("優先使用選取的樣式"), isOn: prefersSelectedBinding)
                    .foregroundStyle(DSColor.textPrimary)
            } header: {
                Text(localized("顯示偏好"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("開啟後以選取的樣式重繪卡片；關閉或卡片無法辨識時，顯示來源配置提供的樣式。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("管理")).foregroundStyle(DSColor.textSecondary)) {
                Button(action: openNewStyleEditor) {
                    SettingsRowLabel(localized("新建樣式"), systemImage: "plus.circle", role: .action)
                }
                if let onOpenImporter {
                    Button(action: onOpenImporter) {
                        SettingsRowLabel(localized("匯入樣式"), systemImage: "square.and.arrow.down", role: .action)
                    }
                }
                exportLink
                if let selectedStyle {
                    Button {
                        editorDraft = CommentCardStyleDraft(kind: kind, style: selectedStyle, source: selectedStyle.svg)
                    } label: {
                        SettingsRowLabel(localized("編輯目前樣式"), systemImage: "pencil", role: .action)
                    }
                    Button(role: .destructive) {
                        stylePendingDeletion = selectedStyle
                    } label: {
                        SettingsRowLabel(localized("刪除目前樣式"), systemImage: "trash", role: .destructive)
                    }
                }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(kind.localizedTitle)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .navigationDestination(item: $editorDraft) { draft in
            CommentCardStyleEditorView(draft: draft)
        }
        .alert(
            localized("刪除目前樣式？"),
            isPresented: Binding(
                get: { stylePendingDeletion != nil },
                set: { if !$0 { stylePendingDeletion = nil } }
            ),
            presenting: stylePendingDeletion
        ) { style in
            Button(localized("刪除目前樣式"), role: .destructive) {
                settings.deleteCommentCardStyle(id: style.id)
                stylePendingDeletion = nil
            }
            Button(localized("取消"), role: .cancel) {}
        } message: { style in
            Text(String(format: localized("「%@」會被永久刪除，此操作無法復原。"), style.name))
        }
    }

    // MARK: - Selection

    private var styles: [ReaderCommentCardCustomStyle] {
        settings.commentCardStyles(of: kind)
    }

    /// The custom template picked for this kind; nil is 玻璃, as is a pick deleted since.
    private var selectedStyle: ReaderCommentCardCustomStyle? {
        guard let id = settings.commentCardChoices[kind].selectedStyleID else { return nil }
        return styles.first { $0.id == id }
    }

    private var selectedSource: String {
        selectedStyle?.svg ?? ReviewCardTemplate.builtinSource(for: kind)
    }

    /// The preview is drawn on the reading theme, as the card would be.
    private var isNightReading: Bool {
        ReaderTheme.loadPersisted() == .night
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedStyle?.id },
            set: { settings.selectCommentCardStyle(id: $0, for: kind) }
        )
    }

    private var prefersSelectedBinding: Binding<Bool> {
        Binding(
            get: { settings.commentCardChoices[kind].prefersSelectedStyle },
            set: { settings.setCommentCardPrefersSelectedStyle($0, for: kind) }
        )
    }

    // MARK: - Export

    /// A template with its own colours travels as a package, which keeps them and its kind;
    /// anything else as the SVG.
    @ViewBuilder
    private var exportLink: some View {
        let label = SettingsRowLabel(localized("匯出當前樣式"), systemImage: "square.and.arrow.up", role: .action)
        if let style = selectedStyle, style.dayColor != nil || style.nightColor != nil,
           let payload = Self.packageExport(style) {
            ShareLink(item: payload, preview: SharePreview(style.name)) { label }
        } else {
            let name = selectedStyle?.name ?? localized("玻璃")
            ShareLink(item: CommentStyleSVGExport(name: name, svg: selectedSource), preview: SharePreview(name)) {
                label
            }
        }
    }

    private static func packageExport(_ style: ReaderCommentCardCustomStyle) -> CommentStyleJSONExport? {
        do {
            return try CommentStyleJSONExport(card: style)
        } catch {
            AppLogger.error("comment card package export not encoded", error: error)
            return nil
        }
    }

    // MARK: - Editor

    /// A new template starts from the one picked now, so 玻璃 can be adjusted rather than
    /// rewritten.
    private func openNewStyleEditor() {
        editorDraft = CommentCardStyleDraft(kind: kind, style: nil, source: selectedSource)
    }
}

struct CommentCardStyleDraft: Identifiable, Hashable {
    let id = UUID()
    let kind: ReaderCommentCardKind
    /// The template being edited; nil makes a new one.
    let style: ReaderCommentCardCustomStyle?
    /// What the SVG field starts with.
    let source: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 新建樣式 / 編輯樣式 for a card template: its name, SVG and `${color}`, with the sample card
/// drawn by day and by night. Leaving without 儲存 keeps the template as it was.
struct CommentCardStyleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = GlobalSettings.shared
    let draft: CommentCardStyleDraft

    @State private var name: String
    @State private var svg: String
    @State private var dayColor: String?
    @State private var nightColor: String?
    @State private var validationMessage: String?

    init(draft: CommentCardStyleDraft) {
        self.draft = draft
        _name = State(initialValue: draft.style?.name ?? "")
        _svg = State(initialValue: draft.source)
        _dayColor = State(initialValue: draft.style?.dayColor)
        _nightColor = State(initialValue: draft.style?.nightColor)
    }

    var body: some View {
        Form {
            Section(header: Text(localized("樣式名稱")).foregroundStyle(DSColor.textSecondary)) {
                TextField(localized("樣式名稱"), text: $name)
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)) {
                CommentCardTemplatePreview(source: svg, kind: draft.kind, colorHex: dayColor, isNight: false)
                CommentCardTemplatePreview(source: svg, kind: draft.kind, colorHex: nightColor, isNight: true)
            }
            .interfaceSectionSurface()

            Section {
                TextEditor(text: $svg)
                    .font(DSFont.monospaced())
                    .frame(minHeight: DSLayout.readerSVGEditorHeight)
                    .accessibilityLabel(localized("SVG 模板"))
                Button {
                    if let pasted = UIPasteboard.general.string { svg = pasted }
                } label: {
                    SettingsRowLabel(localized("從剪貼簿貼上 SVG"), systemImage: "doc.on.clipboard", role: .action)
                }
            } header: {
                Text(localized("SVG 模板")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("可用 ${title}、${count}、${num}、${user}、${likes}、${content}、${color} 與 ${accent}（閱讀背景的強調色）；帶 data-yd-repeat 的元素會為每則評論重複一次，帶 data-yd-glass 的元素會畫成系統玻璃。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                OptionalHexColorRows(
                    toggleTitle: localized("自訂白天顏色"),
                    pickerTitle: localized("白天顏色"),
                    hex: $dayColor,
                    initialColor: ReaderTheme.white.uiTextColor
                )
                OptionalHexColorRows(
                    toggleTitle: localized("自訂夜間顏色"),
                    pickerTitle: localized("夜間顏色"),
                    hex: $nightColor,
                    initialColor: ReaderTheme.night.uiTextColor
                )
            } header: {
                Text(localized("顏色")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("未設定時 ${color} 跟隨閱讀文字顏色。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized(draft.style == nil ? "新建樣式" : "編輯樣式"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    Image(systemName: "checkmark")
                }
                .disabled(svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(localized("儲存"))
            }
        }
        .alert(
            localized("無法儲存樣式"),
            isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )
        ) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private func save() {
        let source = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try ReviewCardTemplate(source: source)
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.upsertCommentCardStyle(ReaderCommentCardCustomStyle(
            id: draft.style?.id ?? UUID(),
            kind: draft.kind,
            name: trimmedName.isEmpty ? localized("自訂模板") : trimmedName,
            svg: source,
            updatedAt: draft.style?.updatedAt,
            dayColor: dayColor,
            nightColor: nightColor
        ))
        dismiss()
    }
}

#Preview("本章說") {
    NavigationStack {
        ReaderCommentCardSettingsView(kind: .chapterSay, onOpenImporter: {})
    }
}

#Preview("Card editor") {
    NavigationStack {
        CommentCardStyleEditorView(draft: CommentCardStyleDraft(
            kind: .hotComment,
            style: nil,
            source: ReviewCardTemplate.builtinSource(for: .hotComment)
        ))
    }
}
