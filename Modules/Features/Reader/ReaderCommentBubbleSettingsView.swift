import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReaderCommentBubbleSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared
    @State private var showingSVGImporter = false
    @State private var showingSVGExporter = false
    @State private var editorDraft: CommentBubbleStyleEditorDraft?
    @State private var stylePendingDeletion: ReaderCommentBubbleCustomStyle?
    @State private var importAlert: BubbleImportAlert?

    private let previewColumns = [
        GridItem(.fixed(DSLayout.readerBubblePreviewTileWidth), spacing: DSSpacing.sm),
        GridItem(.fixed(DSLayout.readerBubblePreviewTileWidth), spacing: DSSpacing.sm),
        GridItem(.fixed(DSLayout.readerBubblePreviewTileWidth), spacing: DSSpacing.sm),
    ]

    var body: some View {
        Form {
            Section(header: Text(localized("氣泡樣式"))) {
                LazyVGrid(columns: previewColumns, alignment: .leading, spacing: DSSpacing.sm) {
                    ForEach([
                        ReaderCommentBubblePresetMode.builtin,
                        ReaderCommentBubblePresetMode.square,
                    ]) { mode in
                        builtinStyleButton(mode: mode)
                    }

                    ForEach(settings.commentBubbleCustomStyles) { style in
                        customStyleButton(style: style)
                    }
                }
                .padding(.vertical, DSSpacing.sm)
            }

            Section {
                Toggle(localized("優先使用選取的氣泡樣式"), isOn: prioritizeSelectedBubbleBinding)
            } header: {
                Text(localized("顯示偏好"))
            } footer: {
                Text(localized("開啟後優先使用選取的氣泡樣式；關閉後依書源提供的 SVG 顯示。"))
            }

            Section(header: Text(localized("管理"))) {
                Button(action: openNewStyleEditor) {
                    Label(localized("新建樣式"), systemImage: "plus.circle")
                }

                Button {
                    showingSVGImporter = true
                } label: {
                    Label(localized("匯入樣式"), systemImage: "square.and.arrow.down")
                }

                Button {
                    showingSVGExporter = true
                } label: {
                    Label(localized("匯出當前樣式"), systemImage: "square.and.arrow.up")
                }

                if let activeCustomStyle {
                    Button {
                        openStyleEditor(for: activeCustomStyle)
                    } label: {
                        Label(localized("編輯目前樣式"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        stylePendingDeletion = activeCustomStyle
                    } label: {
                        Label(localized("刪除目前樣式"), systemImage: "trash")
                    }
                }
            }

            Section(header: Text(localized("整體大小"))) {
                BubbleSliderRow(
                    title: localized("當前樣式大小"),
                    valueText: String(format: "%.2f×", settings.commentBubbleScale),
                    value: bubbleScaleBinding,
                    range: GlobalSettings.commentBubbleScaleRange,
                    step: 0.05
                )
                Text(localized("這裡調整目前選取氣泡樣式的整體大小。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Section(header: Text(localized("文字大小"))) {
                BubbleSliderRow(
                    title: localized("數字字號比例"),
                    valueText: "\(Int((settings.commentBubbleTextScale * 100).rounded()))%",
                    value: bubbleTextScaleBinding,
                    range: GlobalSettings.commentBubbleTextScaleRange,
                    step: 0.05
                )
                Text(localized("這裡調整段評數字相對於氣泡的大小。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .navigationTitle(localized("氣泡設定"))
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $editorDraft) { draft in
            CommentBubbleStyleEditorView(
                draft: draft,
                onSave: saveEditorDraft
            )
            .presentationDetents([.large])
        }
        .fileImporter(
            isPresented: $showingSVGImporter,
            allowedContentTypes: Self.svgContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSVGImport
        )
        .fileExporter(
            isPresented: $showingSVGExporter,
            document: CommentBubbleSVGDocument(svg: currentStyleSVG),
            contentType: Self.svgContentType,
            defaultFilename: exportFilename,
            onCompletion: handleSVGExport
        )
        .confirmationDialog(
            localized("刪除目前樣式？"),
            isPresented: Binding(
                get: { stylePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        stylePendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: stylePendingDeletion
        ) { style in
            Button(localized("刪除目前樣式"), role: .destructive) {
                deleteCustomStyle(style)
            }
            Button(localized("取消"), role: .cancel) {}
        } message: { style in
            Text(
                String(
                    format: localized("「%@」會被永久刪除，此操作無法復原。"),
                    style.name
                )
            )
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized(alert.titleKey)),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    private func builtinStyleButton(mode: ReaderCommentBubblePresetMode) -> some View {
        let title = localized(mode.titleKey)
        let svg = CommentBubbleSVGRecognizer.templateSVG(for: mode, customSVG: "")
        let isSelected = settings.commentBubblePresetMode == mode

        return styleButton(
            title: title,
            svg: svg,
            isSelected: isSelected
        ) {
            selectBuiltinStyle(mode)
        }
    }

    private func customStyleButton(style: ReaderCommentBubbleCustomStyle) -> some View {
        let trimmedName = style.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? localized("自訂 SVG") : trimmedName
        let isSelected = settings.commentBubblePresetMode == .custom
            && settings.commentBubbleSelectedCustomStyleID == style.id

        return styleButton(
            title: title,
            svg: style.svg,
            isSelected: isSelected
        ) {
            settings.selectCommentBubbleCustomStyle(id: style.id)
            settings.commentBubbleFollowsSourceSVG = false
            notifyReaderLayoutChanged()
        }
    }

    private func styleButton(
        title: String,
        svg: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.sm) {
                if let preview = previewImage(svg: svg) {
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
            .frame(maxWidth: .infinity, minHeight: DSLayout.readerBubblePreviewHeight)
            .background(isSelected ? DSColor.accentLight : DSColor.surfaceTertiary)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .stroke(
                        isSelected ? DSColor.accent : DSColor.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func previewImage(svg: String) -> UIImage? {
        guard let bubble = CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg) else {
            return nil
        }
        return CommentBubbleSVGRecognizer.draw(
            svg: bubble.replacingDisplayText(with: "99"),
            pointSize: 34,
            themeTextColor: .label,
            textScaleRatio: CGFloat(GlobalSettings.defaultCommentBubbleTextScale)
        )
    }

    private var activeCustomStyle: ReaderCommentBubbleCustomStyle? {
        guard settings.commentBubblePresetMode == .custom else { return nil }
        return settings.commentBubbleSelectedCustomStyle
    }

    private var prioritizeSelectedBubbleBinding: Binding<Bool> {
        Binding(
            get: { !settings.commentBubbleFollowsSourceSVG },
            set: { prioritizesSelectedStyle in
                settings.commentBubbleFollowsSourceSVG = !prioritizesSelectedStyle
                notifyReaderLayoutChanged()
            }
        )
    }

    private var bubbleScaleBinding: Binding<Double> {
        Binding(
            get: { settings.commentBubbleScale },
            set: { value in
                settings.commentBubbleScale = value
                settings.commentBubbleFollowsSourceSVG = false
                notifyReaderLayoutChanged()
            }
        )
    }

    private var bubbleTextScaleBinding: Binding<Double> {
        Binding(
            get: { settings.commentBubbleTextScale },
            set: { value in
                settings.commentBubbleTextScale = value
                settings.commentBubbleFollowsSourceSVG = false
                notifyReaderLayoutChanged()
            }
        )
    }

    private var currentStyleSVG: String {
        CommentBubbleSVGRecognizer.templateSVG(
            for: settings.commentBubblePresetMode,
            customSVG: settings.commentBubbleSelectedCustomStyle?.svg ?? ""
        )
    }

    private static let svgContentType = UTType(filenameExtension: "svg") ?? .data

    private static let svgContentTypes: [UTType] = [
        svgContentType,
        .plainText,
        .data,
    ]

    private var exportFilename: String {
        let candidate: String
        switch settings.commentBubblePresetMode {
        case .builtin, .square:
            candidate = localized(settings.commentBubblePresetMode.titleKey)
        case .custom:
            candidate = settings.commentBubbleSelectedCustomStyle?.name ?? localized("自訂 SVG")
        }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedCandidate.isEmpty ? "comment-bubble" : trimmedCandidate) + ".svg"
    }

    private func selectBuiltinStyle(_ mode: ReaderCommentBubblePresetMode) {
        switch mode {
        case .builtin:
            settings.selectCommentBubbleBuiltinStyle()
        case .square:
            settings.selectCommentBubbleSquareStyle()
        case .custom:
            return
        }
        settings.commentBubbleFollowsSourceSVG = false
        notifyReaderLayoutChanged()
    }

    private func openNewStyleEditor() {
        editorDraft = CommentBubbleStyleEditorDraft(
            styleID: nil,
            titleKey: "新建樣式",
            name: "",
            svg: ""
        )
    }

    private func openStyleEditor(for style: ReaderCommentBubbleCustomStyle) {
        editorDraft = CommentBubbleStyleEditorDraft(
            styleID: style.id,
            titleKey: "編輯樣式",
            name: style.name,
            svg: style.svg
        )
    }

    private func saveEditorDraft(
        styleID: UUID?,
        name: String,
        svg: String
    ) -> String? {
        let trimmedSVG = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationMessage = validationMessage(for: trimmedSVG) {
            return validationMessage
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? localized("自訂 SVG") : trimmedName
        settings.upsertCommentBubbleCustomStyle(
            ReaderCommentBubbleCustomStyle(
                id: styleID ?? UUID(),
                name: resolvedName,
                svg: trimmedSVG
            )
        )
        settings.commentBubbleFollowsSourceSVG = false
        notifyReaderLayoutChanged()
        return nil
    }

    private func deleteCustomStyle(_ style: ReaderCommentBubbleCustomStyle) {
        settings.deleteCommentBubbleCustomStyle(id: style.id)
        stylePendingDeletion = nil
        notifyReaderLayoutChanged()
    }

    private func handleSVGImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let svg = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                showInvalidSVGAlert(message: localized("檔案不是可讀取的 SVG。"))
                return
            }

            let trimmedSVG = svg.trimmingCharacters(in: .whitespacesAndNewlines)
            if let validationMessage = validationMessage(for: trimmedSVG) {
                showInvalidSVGAlert(message: validationMessage)
                return
            }

            let fileName = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let styleName = fileName.isEmpty ? localized("自訂 SVG") : fileName
            settings.upsertCommentBubbleCustomStyle(
                ReaderCommentBubbleCustomStyle(name: styleName, svg: trimmedSVG)
            )
            settings.commentBubbleFollowsSourceSVG = false
            notifyReaderLayoutChanged()
            importAlert = BubbleImportAlert(
                titleKey: "SVG 匯入成功",
                message: localized("已套用自訂段評氣泡 SVG。")
            )
        } catch {
            importAlert = BubbleImportAlert(
                titleKey: "SVG 匯入失敗",
                message: error.localizedDescription
            )
        }
    }

    private func handleSVGExport(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            importAlert = BubbleImportAlert(
                titleKey: "操作失敗",
                message: error.localizedDescription
            )
        }
    }

    private func validationMessage(for svg: String) -> String? {
        if svg.utf8.count > CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount {
            return String(
                format: localized("SVG 檔案過大，請使用小於 %d KB 的氣泡樣式。"),
                CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount / 1024
            )
        }
        guard svg.lowercased().contains("<svg") else {
            return localized("檔案不是可讀取的 SVG。")
        }
        guard CommentBubbleSVGRecognizer.recognize(src: "", svgContent: svg) != nil else {
            return localized("SVG 需要包含一個可替換的文字節點，才能作為段評氣泡。")
        }
        return nil
    }

    private func showInvalidSVGAlert(message: String) {
        importAlert = BubbleImportAlert(
            titleKey: "SVG 匯入失敗",
            message: message
        )
    }

    private func notifyReaderLayoutChanged() {
        readerConfig.refresh.send(.layout)
    }
}

private struct CommentBubbleStyleEditorDraft: Identifiable {
    let id = UUID()
    let styleID: UUID?
    let titleKey: String
    let name: String
    let svg: String
}

private struct CommentBubbleStyleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft: String
    @State private var svgDraft: String
    @State private var validationMessage: String?

    let draft: CommentBubbleStyleEditorDraft
    let onSave: (UUID?, String, String) -> String?

    init(
        draft: CommentBubbleStyleEditorDraft,
        onSave: @escaping (UUID?, String, String) -> String?
    ) {
        self.draft = draft
        self.onSave = onSave
        _nameDraft = State(initialValue: draft.name)
        _svgDraft = State(initialValue: draft.svg)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("樣式名稱"))) {
                    TextField(localized("樣式名稱"), text: $nameDraft)
                }

                Section(header: Text(localized("SVG / TXT"))) {
                    TextEditor(text: $svgDraft)
                        .font(DSFont.monospaced())
                        .frame(minHeight: DSLayout.readerSVGEditorHeight)

                    Button {
                        if let pastedSVG = UIPasteboard.general.string {
                            svgDraft = pastedSVG
                        }
                    } label: {
                        Label(localized("從剪貼簿貼上 SVG"), systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle(localized(draft.titleKey))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let message = onSave(draft.styleID, nameDraft, svgDraft) {
                            validationMessage = message
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(svgDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(localized("儲存"))
                }
            }
            .alert(
                localized("SVG 匯入失敗"),
                isPresented: Binding(
                    get: { validationMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            validationMessage = nil
                        }
                    }
                )
            ) {
                Button(localized("確定"), role: .cancel) {}
            } message: {
                Text(validationMessage ?? "")
            }
        }
    }
}

private struct BubbleSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text(title)
                    .font(DSFont.body)
                Spacer()
                Text(valueText)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, DSSpacing.xs)
    }
}

private struct BubbleImportAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

private struct CommentBubbleSVGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "svg") ?? .data] }
    static var writableContentTypes: [UTType] { [UTType(filenameExtension: "svg") ?? .data] }

    var svg: String

    init(svg: String) {
        self.svg = svg
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        svg = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(svg.utf8))
    }
}

#Preview {
    NavigationStack {
        ReaderCommentBubbleSettingsView()
    }
}
