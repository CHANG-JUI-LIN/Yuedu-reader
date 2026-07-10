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
    @State private var showingNewStyleConfirmation = false
    @State private var svgDraft = ""
    @State private var customNameDraft = ""
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
                    ForEach(ReaderCommentBubblePresetMode.allCases) { mode in
                        styleButton(mode: mode)
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
                Button(action: requestNewStyle) {
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

                if !settings.commentBubbleCustomSVG.isEmpty {
                    Button(role: .destructive, action: removeCustomStyle) {
                        Label(localized("移除自訂氣泡"), systemImage: "trash")
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

            if settings.commentBubblePresetMode == .custom || !svgDraft.isEmpty {
                Section(header: Text(localized("自訂氣泡 SVG"))) {
                    TextField(localized("樣式名稱"), text: $customNameDraft)

                    TextEditor(text: $svgDraft)
                        .font(DSFont.monospaced())
                        .frame(minHeight: DSLayout.readerSVGEditorHeight)

                    Button {
                        applySVG(svgDraft)
                    } label: {
                        Label(localized("套用 SVG"), systemImage: "checkmark")
                    }
                    .disabled(svgDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle(localized("氣泡設定"))
        .toolbarTitleDisplayMode(.inline)
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
            localized("建立新樣式？"),
            isPresented: $showingNewStyleConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("新建樣式"), role: .destructive) {
                createNewStyle()
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("這會取代目前的自訂氣泡樣式。"))
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized(alert.titleKey)),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
        .onAppear {
            svgDraft = settings.commentBubbleCustomSVG
            customNameDraft = settings.commentBubbleCustomStyleName
        }
    }

    private func styleButton(mode: ReaderCommentBubblePresetMode) -> some View {
        let isSelected = settings.commentBubblePresetMode == mode
        let title = title(for: mode)

        return Button {
            settings.commentBubblePresetMode = mode
            settings.commentBubbleFollowsSourceSVG = false
            notifyReaderLayoutChanged()
        } label: {
            VStack(spacing: DSSpacing.sm) {
                if let preview = previewImage(for: mode) {
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
                    .stroke(isSelected ? DSColor.accent : DSColor.border, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func title(for mode: ReaderCommentBubblePresetMode) -> String {
        guard mode == .custom else { return localized(mode.titleKey) }
        let name = settings.commentBubbleCustomStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? localized("自訂 SVG") : name
    }

    private func previewImage(for mode: ReaderCommentBubblePresetMode) -> UIImage? {
        let svg = CommentBubbleSVGRecognizer.templateSVG(
            for: mode,
            customSVG: settings.commentBubbleCustomSVG
        )
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
            customSVG: settings.commentBubbleCustomSVG
        )
    }

    private static let svgContentType = UTType(filenameExtension: "svg") ?? .data

    private static let svgContentTypes: [UTType] = [
        svgContentType,
        .plainText,
        .data,
    ]

    private var exportFilename: String {
        let candidate = title(for: settings.commentBubblePresetMode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (candidate.isEmpty ? "comment-bubble" : candidate) + ".svg"
    }

    private func requestNewStyle() {
        if settings.commentBubbleCustomSVG.isEmpty {
            createNewStyle()
        } else {
            showingNewStyleConfirmation = true
        }
    }

    private func createNewStyle() {
        let name = localized("自訂樣式")
        let template = CommentBubbleSVGRecognizer.builtinBubbleSVG
        settings.commentBubblePresetMode = .custom
        settings.commentBubbleFollowsSourceSVG = false
        settings.commentBubbleCustomStyleName = name
        settings.commentBubbleCustomSVG = template
        customNameDraft = name
        svgDraft = template
        notifyReaderLayoutChanged()
    }

    private func removeCustomStyle() {
        svgDraft = ""
        customNameDraft = ""
        settings.commentBubbleCustomSVG = ""
        settings.commentBubbleCustomStyleName = ""
        settings.commentBubblePresetMode = .builtin
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
                showInvalidSVGAlert(messageKey: "檔案不是可讀取的 SVG。")
                return
            }
            let styleName = url.deletingPathExtension().lastPathComponent
            customNameDraft = styleName
            svgDraft = svg
            applySVG(svg, styleName: styleName, successTitleKey: "SVG 匯入成功")
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

    private func applySVG(
        _ svg: String,
        styleName: String? = nil,
        successTitleKey: String = "SVG 匯入成功"
    ) {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased().contains("<svg"),
              CommentBubbleSVGRecognizer.recognize(src: "", svgContent: trimmed) != nil else {
            showInvalidSVGAlert(for: trimmed)
            return
        }

        let requestedName = (styleName ?? customNameDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = requestedName.isEmpty ? localized("自訂 SVG") : requestedName

        svgDraft = trimmed
        customNameDraft = resolvedName
        settings.commentBubbleCustomSVG = trimmed
        settings.commentBubbleCustomStyleName = resolvedName
        settings.commentBubblePresetMode = .custom
        settings.commentBubbleFollowsSourceSVG = false
        notifyReaderLayoutChanged()
        importAlert = BubbleImportAlert(
            titleKey: successTitleKey,
            message: localized("已套用自訂段評氣泡 SVG。")
        )
    }

    private func showInvalidSVGAlert(for svg: String) {
        if svg.utf8.count > CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount {
            showInvalidSVGAlert(messageKey: "SVG 檔案過大，請使用小於 %d KB 的氣泡樣式。")
        } else if !svg.lowercased().contains("<svg") {
            showInvalidSVGAlert(messageKey: "檔案不是可讀取的 SVG。")
        } else {
            showInvalidSVGAlert(messageKey: "SVG 需要包含一個可替換的文字節點，才能作為段評氣泡。")
        }
    }

    private func showInvalidSVGAlert(messageKey: String) {
        let message: String
        if messageKey.contains("%d") {
            message = String(
                format: localized(messageKey),
                CommentBubbleSVGRecognizer.maximumRecognizableSVGByteCount / 1024
            )
        } else {
            message = localized(messageKey)
        }
        importAlert = BubbleImportAlert(
            titleKey: "SVG 匯入失敗",
            message: message
        )
    }

    private func notifyReaderLayoutChanged() {
        readerConfig.refresh.send(.layout)
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
