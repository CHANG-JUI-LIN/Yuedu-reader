import SwiftUI
import UIKit

/// 氣泡設定 › 段評氣泡: the count bubble drawn beside a paragraph that has 段評.
struct ReaderParagraphBubbleSettingsView: View {
    @Bindable private var settings = GlobalSettings.shared
    /// 匯入樣式, handed to the first-level document picker; nil hides it.
    var onOpenImporter: (() -> Void)?
    @State private var editorDraft: CommentBubbleStyleDraft?
    @State private var stylePendingDeletion: ReaderCommentBubbleCustomStyle?

    var body: some View {
        Form {
            Section(header: Text(localized("氣泡樣式")).foregroundStyle(DSColor.textSecondary)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DSSpacing.sm) {
                        ForEach([ReaderCommentBubblePresetMode.builtin, .square]) { mode in
                            builtinStyleButton(mode: mode)
                        }
                        ForEach(settings.commentBubbleCustomStyles) { style in
                            customStyleButton(style: style)
                        }
                    }
                }
                .padding(.vertical, DSSpacing.sm)
            }
            .interfaceSectionSurface()

            Section {
                Toggle(localized("優先使用選取的氣泡樣式"), isOn: prioritizeSelectedBubbleBinding)
                    .foregroundStyle(DSColor.textPrimary)
            } header: {
                Text(localized("顯示偏好"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("開啟後優先使用選取的氣泡樣式；關閉後依來源配置提供的 SVG 顯示。"))
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
                if let activeCustomStyle {
                    Button {
                        openStyleEditor(for: activeCustomStyle)
                    } label: {
                        SettingsRowLabel(localized("編輯目前樣式"), systemImage: "pencil", role: .action)
                    }
                    Button(role: .destructive) {
                        stylePendingDeletion = activeCustomStyle
                    } label: {
                        SettingsRowLabel(localized("刪除目前樣式"), systemImage: "trash", role: .destructive)
                    }
                }
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("整體大小")).foregroundStyle(DSColor.textSecondary)) {
                SettingsSliderRow(
                    title: localized("當前樣式大小"),
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    valueText: String(format: "%.2f×", settings.commentBubbleScale),
                    value: bubbleScaleBinding,
                    range: GlobalSettings.commentBubbleScaleRange,
                    step: 0.05
                )
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("段評氣泡"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .navigationDestination(item: $editorDraft) { draft in
            CommentBubbleStyleEditorView(draft: draft)
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
                settings.deleteCommentBubbleCustomStyle(id: style.id)
                stylePendingDeletion = nil
            }
            Button(localized("取消"), role: .cancel) {}
        } message: { style in
            Text(String(format: localized("「%@」會被永久刪除，此操作無法復原。"), style.name))
        }
    }

    // MARK: - Styles

    private func builtinStyleButton(mode: ReaderCommentBubblePresetMode) -> some View {
        BubbleStyleTile(
            title: localized(mode.titleKey),
            preview: Self.previewImage(svg: CommentBubbleSVGRecognizer.templateSVG(for: mode, customSVG: "")),
            isSelected: settings.commentBubblePresetMode == mode
        ) {
            switch mode {
            case .builtin: settings.selectCommentBubbleBuiltinStyle()
            case .square: settings.selectCommentBubbleSquareStyle()
            case .custom: return
            }
            settings.commentBubbleFollowsSourceSVG = false
        }
    }

    private func customStyleButton(style: ReaderCommentBubbleCustomStyle) -> some View {
        let name = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Colour placeholders resolved the way the reader does, for "99".
        let previewSVG = CommentBubbleSVGRecognizer.materializeTemplateColors(
            style.svg,
            style: style,
            count: "99",
            themeTextColor: .label
        )
        return BubbleStyleTile(
            title: name.isEmpty ? localized("自訂 SVG") : name,
            preview: Self.previewImage(svg: previewSVG),
            isSelected: settings.commentBubblePresetMode == .custom
                && settings.commentBubbleSelectedCustomStyleID == style.id
        ) {
            settings.selectCommentBubbleCustomStyle(id: style.id)
            settings.commentBubbleFollowsSourceSVG = false
        }
    }

    static func previewImage(svg: String, textColor: UIColor = .label) -> UIImage? {
        guard let bubble = CommentBubbleSVGRecognizer.recognizeUserTemplate(svg) else { return nil }
        return CommentBubbleSVGRecognizer.draw(
            svg: bubble.replacingDisplayText(with: "99"),
            pointSize: 34,
            themeTextColor: textColor,
            textFace: .reader
        )
    }

    private var activeCustomStyle: ReaderCommentBubbleCustomStyle? {
        guard settings.commentBubblePresetMode == .custom else { return nil }
        return settings.commentBubbleSelectedCustomStyle
    }

    private var prioritizeSelectedBubbleBinding: Binding<Bool> {
        Binding(
            get: { !settings.commentBubbleFollowsSourceSVG },
            set: { settings.commentBubbleFollowsSourceSVG = !$0 }
        )
    }

    private var bubbleScaleBinding: Binding<Double> {
        Binding(
            get: { settings.commentBubbleScale },
            set: { value in
                settings.commentBubbleScale = value
                settings.commentBubbleFollowsSourceSVG = false
            }
        )
    }

    // MARK: - Export

    /// A custom style with colours or a size travels as `bubble.json`, which keeps them;
    /// anything else as the SVG.
    @ViewBuilder
    private var exportLink: some View {
        let label = SettingsRowLabel(localized("匯出當前樣式"), systemImage: "square.and.arrow.up", role: .action)
        if let style = activeCustomStyle, style.needsPackageToExport, let payload = Self.packageExport(style) {
            ShareLink(item: payload, preview: SharePreview(style.name)) { label }
        } else {
            let name = exportName
            ShareLink(item: CommentStyleSVGExport(name: name, svg: currentStyleSVG), preview: SharePreview(name)) {
                label
            }
        }
    }

    private static func packageExport(_ style: ReaderCommentBubbleCustomStyle) -> CommentStyleJSONExport? {
        do {
            return try CommentStyleJSONExport(bubble: style)
        } catch {
            AppLogger.error("bubble.json export not encoded", error: error)
            return nil
        }
    }

    private var currentStyleSVG: String {
        CommentBubbleSVGRecognizer.templateSVG(
            for: settings.commentBubblePresetMode,
            customSVG: settings.commentBubbleSelectedCustomStyle?.svg ?? ""
        )
    }

    private var exportName: String {
        switch settings.commentBubblePresetMode {
        case .builtin, .square:
            return localized(settings.commentBubblePresetMode.titleKey)
        case .custom:
            let name = settings.commentBubbleSelectedCustomStyle?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "comment-bubble" : name
        }
    }

    // MARK: - Editor

    private func openNewStyleEditor() {
        editorDraft = CommentBubbleStyleDraft(style: nil)
    }

    private func openStyleEditor(for style: ReaderCommentBubbleCustomStyle) {
        editorDraft = CommentBubbleStyleDraft(style: style)
    }
}

private struct BubbleStyleTile: View {
    let title: String
    let preview: UIImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.sm) {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(height: DSSpacing.xl)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "text.bubble")
                        .font(DSFont.title2)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(DSFont.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isSelected ? DSColor.accent : DSColor.textPrimary)
            .frame(
                minWidth: DSLayout.readerBubblePreviewTileWidth,
                maxWidth: DSLayout.readerBubblePreviewTileWidth,
                minHeight: DSLayout.readerBubblePreviewHeight
            )
            .background(isSelected ? DSColor.accentLight : DSColor.surfaceTertiary)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .stroke(isSelected ? DSColor.accent : DSColor.border, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct CommentBubbleStyleDraft: Identifiable, Hashable {
    let id = UUID()
    /// The style being edited; nil makes a new one.
    let style: ReaderCommentBubbleCustomStyle?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 新建樣式 / 編輯樣式 for a 段評 bubble: its name, SVG and colour slots, with a preview of
/// "99" in day and in night. Leaving without 儲存 keeps the style as it was.
struct CommentBubbleStyleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = GlobalSettings.shared
    let draft: CommentBubbleStyleDraft

    @State private var name: String
    @State private var svg: String
    @State private var dayNormalColor: String?
    @State private var dayEmphasisColor: String?
    @State private var nightNormalColor: String?
    @State private var nightEmphasisColor: String?
    @State private var validationMessage: String?

    init(draft: CommentBubbleStyleDraft) {
        self.draft = draft
        _name = State(initialValue: draft.style?.name ?? "")
        _svg = State(initialValue: draft.style?.svg ?? "")
        _dayNormalColor = State(initialValue: draft.style?.dayNormalColor)
        _dayEmphasisColor = State(initialValue: draft.style?.dayEmphasisColor)
        _nightNormalColor = State(initialValue: draft.style?.nightNormalColor)
        _nightEmphasisColor = State(initialValue: draft.style?.nightEmphasisColor)
    }

    var body: some View {
        Form {
            Section(header: Text(localized("樣式名稱")).foregroundStyle(DSColor.textSecondary)) {
                TextField(localized("樣式名稱"), text: $name)
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)) {
                HStack(spacing: DSSpacing.sm) {
                    bubblePreview(isNight: false)
                    bubblePreview(isNight: true)
                }
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("SVG / TXT")).foregroundStyle(DSColor.textSecondary)) {
                TextEditor(text: $svg)
                    .font(DSFont.monospaced())
                    .frame(minHeight: DSLayout.readerSVGEditorHeight)
                    .accessibilityLabel(localized("SVG / TXT"))
                Button {
                    if let pasted = UIPasteboard.general.string { svg = pasted }
                } label: {
                    SettingsRowLabel(localized("從剪貼簿貼上 SVG"), systemImage: "doc.on.clipboard", role: .action)
                }
            }
            .interfaceSectionSurface()

            Section {
                OptionalHexColorRows(
                    toggleTitle: localized("自訂白天一般顏色"),
                    pickerTitle: localized("白天一般顏色"),
                    hex: $dayNormalColor,
                    initialColor: ReaderTheme.white.uiTextColor
                )
                OptionalHexColorRows(
                    toggleTitle: localized("自訂白天強調顏色"),
                    pickerTitle: localized("白天強調顏色"),
                    hex: $dayEmphasisColor,
                    initialColor: ReaderTheme.white.uiTextColor
                )
                OptionalHexColorRows(
                    toggleTitle: localized("自訂夜間一般顏色"),
                    pickerTitle: localized("夜間一般顏色"),
                    hex: $nightNormalColor,
                    initialColor: ReaderTheme.night.uiTextColor
                )
                OptionalHexColorRows(
                    toggleTitle: localized("自訂夜間強調顏色"),
                    pickerTitle: localized("夜間強調顏色"),
                    hex: $nightEmphasisColor,
                    initialColor: ReaderTheme.night.uiTextColor
                )
            } header: {
                Text(localized("顏色")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("強調顏色用於 99+ 與 100 以上的數字；未設定時 ${color} 為灰色，__TEXT__ 跟隨閱讀文字顏色。"))
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

    /// The style as the editor holds it now — the same one 儲存 writes and the preview draws.
    private var editedStyle: ReaderCommentBubbleCustomStyle {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReaderCommentBubbleCustomStyle(
            id: draft.style?.id ?? UUID(),
            name: trimmedName.isEmpty ? localized("自訂 SVG") : trimmedName,
            svg: svg.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: draft.style?.updatedAt,
            sizeScale: draft.style?.sizeScale,
            dayEmphasisColor: dayEmphasisColor,
            dayNormalColor: dayNormalColor,
            nightEmphasisColor: nightEmphasisColor,
            nightNormalColor: nightNormalColor
        )
    }

    private func bubblePreview(isNight: Bool) -> some View {
        let theme: ReaderTheme = CommentStylePreviewContext.current(isNight: isNight).theme
        let style = editedStyle
        let materialized = CommentBubbleSVGRecognizer.materializeTemplateColors(
            style.svg,
            style: style,
            count: "99",
            themeTextColor: theme.uiTextColor
        )
        let image = ReaderParagraphBubbleSettingsView.previewImage(svg: materialized, textColor: theme.uiTextColor)
        return ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: DSLayout.readerBubblePreviewHeight)
            } else {
                Image(systemName: "text.bubble")
                    .font(DSFont.title2)
                    .foregroundStyle(Color(uiColor: theme.uiTextColor))
            }
        }
        .frame(maxWidth: .infinity, minHeight: DSLayout.readerBubblePreviewHeight)
        .padding(.vertical, DSSpacing.sm)
        .background(Color(uiColor: theme.uiBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized(isNight ? "夜間預覽" : "白天預覽"))
        .accessibilityValue(image == nil ? localized("預覽無法繪製。") : "")
    }

    private func save() {
        let style = editedStyle
        if let message = ReaderCommentStyleImporter.bubbleValidationMessage(for: style.svg) {
            validationMessage = message
            return
        }
        settings.upsertCommentBubbleCustomStyle(style)
        settings.commentBubbleFollowsSourceSVG = false
        dismiss()
    }
}

#Preview("段評氣泡") {
    NavigationStack {
        ReaderParagraphBubbleSettingsView(onOpenImporter: {})
    }
}

#Preview("Bubble editor") {
    NavigationStack {
        CommentBubbleStyleEditorView(draft: CommentBubbleStyleDraft(style: nil))
    }
}
