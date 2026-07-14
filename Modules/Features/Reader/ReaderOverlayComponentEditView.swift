import SwiftUI
import UIKit

struct ReaderOverlayComponentDraft: Equatable {
    let original: ReaderOverlayComponent
    var value: ReaderOverlayComponent

    init(_ component: ReaderOverlayComponent) {
        original = component
        value = component
    }

    func cancelled() -> ReaderOverlayComponent {
        original
    }

    func committed() -> ReaderOverlayComponent {
        value.normalized
    }
}

struct ReaderOverlayComponentEditView: View {
    @Environment(\.dismiss) private var dismiss

    let originalComponent: ReaderOverlayComponent
    let readerStyle: ReaderOverlayReaderStyle
    let importedFonts: [UserFontInfo]
    let svgAssetStore: ReaderOverlaySVGAssetStore
    let referencedAssetIDs: Set<UUID>
    let onSave: (ReaderOverlayComponent) -> Void

    @State private var component: ReaderOverlayComponent
    @State private var customTextDraft: String
    @State private var svgAssets: [ReaderOverlaySVGAsset] = []
    @State private var svgIsLoading = false
    @State private var svgLoadFailed = false
    @State private var showingSVGPicker = false

    init(
        component: ReaderOverlayComponent,
        readerStyle: ReaderOverlayReaderStyle,
        importedFonts: [UserFontInfo],
        svgAssetStore: ReaderOverlaySVGAssetStore,
        referencedAssetIDs: Set<UUID>,
        onSave: @escaping (ReaderOverlayComponent) -> Void
    ) {
        originalComponent = component
        self.readerStyle = readerStyle
        self.importedFonts = importedFonts
        self.svgAssetStore = svgAssetStore
        self.referencedAssetIDs = referencedAssetIDs
        self.onSave = onSave

        var initialComponent = component
        let formats = ReaderOverlayComponentEditing.compatibleFormats(for: component.kind)
        if !formats.isEmpty,
           !formats.contains(initialComponent.configuration.displayFormat),
           let fallback = formats.first {
            initialComponent.configuration.displayFormat = fallback
        }
        let storedText = initialComponent.configuration.customText
        let initialText = storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localized("自訂文字")
            : storedText
        if initialComponent.kind == .customText,
           storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialComponent.configuration.customText = initialText
        }
        _component = State(initialValue: initialComponent.normalized)
        _customTextDraft = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                if component.kind == .customText {
                    customTextSection
                }

                fontSection
                colorSection
                opacitySection

                if !compatibleFormats.isEmpty {
                    formatSection
                }

                if component.kind == .battery {
                    batterySection
                }
            }
            .formStyle(.grouped)
            .themedAppSurface()
            .navigationTitle(component.kind.localizedTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { saveAndDismiss() } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("儲存"))
                }
            }
        }
        .task {
            ensureValidInitialConfiguration()
            if component.kind == .battery {
                await reloadSVGAssets()
            }
        }
        .sheet(isPresented: $showingSVGPicker, onDismiss: {
            Task { await reloadSVGAssets() }
        }) {
            ReaderBatterySVGImportView(
                store: svgAssetStore,
                referencedAssetIDs: allReferencedAssetIDs,
                selectedAssetID: component.configuration.svgAssetID,
                onSelectAsset: { asset in
                    updateComponent { component in
                        component.configuration.batteryVisual = .importedSVG
                        component.configuration.svgAssetID = asset.id
                    }
                }
            )
        }
    }

    private var customTextSection: some View {
        Section {
            TextField(localized("文字內容"), text: customTextBinding)
                .textInputAutocapitalization(.sentences)
        } footer: {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(
                    String(
                        format: localized("ReaderOverlay.Format.CountLimit"),
                        customTextDraft.count,
                        ReaderOverlayComponentConfiguration.maximumCustomTextLength
                    )
                )
                if !customTextIsValid {
                    Text(localized("自訂文字不能為空白，將保留上一個有效內容。"))
                        .foregroundStyle(DSColor.destructive)
                }
            }
            .font(DSFont.caption)
        }
        .listRowBackground(DSColor.surface)
    }

    private var fontSection: some View {
        Section(localized("字體")) {
            NavigationLink {
                ReaderOverlayFontPickerView(
                    selection: fontBinding,
                    readerFont: readerStyle.font,
                    importedFonts: importedFonts
                )
            } label: {
                LabeledContent(localized("字體來源"), value: fontDisplayName)
            }

            if let missingFontName {
                Label(
                    String(
                        format: localized(
                            "找不到字體「%@」，目前使用系統字體。重新匯入後會自動恢復。"
                        ),
                        missingFontName
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(DSFont.caption)
                .foregroundStyle(DSColor.warning)
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack {
                    Text(localized("字體大小"))
                    Spacer()
                    Text(pointsText)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Slider(value: fontSizeBinding, in: 8...72, step: 1)
                    .accessibilityLabel(localized("字體大小"))
                    .accessibilityValue(pointsText)
            }

            Picker(localized("字重"), selection: fontWeightBinding) {
                ForEach(ReaderOverlayFontWeight.allCasesForEditor, id: \.rawValue) { weight in
                    Text(weight.localizedTitle).tag(weight)
                }
            }
        }
        .listRowBackground(DSColor.surface)
    }

    private var colorSection: some View {
        Section(localized("顏色")) {
            Picker(localized("顏色來源"), selection: colorSourceBinding) {
                Text(localized("閱讀文字顏色")).tag(ReaderOverlayColorSource.readerText)
                Text(localized("自訂顏色")).tag(ReaderOverlayColorSource.custom)
            }

            if component.style.color.source == .custom {
                ColorPicker(
                    localized("自訂顏色"),
                    selection: customColorBinding,
                    supportsOpacity: false
                )
            }
        }
        .listRowBackground(DSColor.surface)
    }

    private var opacitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack {
                    Text(localized("透明度"))
                    Spacer()
                    Text(percentText)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Slider(value: opacityBinding, in: 0.1...1, step: 0.05)
                    .accessibilityLabel(localized("透明度"))
                    .accessibilityValue(percentText)
            }
        }
        .listRowBackground(DSColor.surface)
    }

    private var formatSection: some View {
        Section(localized("顯示格式")) {
            Picker(localized("格式"), selection: displayFormatBinding) {
                ForEach(compatibleFormats, id: \.rawValue) { format in
                    Text(format.localizedTitle).tag(format)
                }
            }
        }
        .listRowBackground(DSColor.surface)
    }

    private var batterySection: some View {
        Section(localized("電量")) {
            Picker(localized("電量圖示"), selection: batteryVisualBinding) {
                Text(localized("系統電池圖示")).tag(ReaderBatteryVisualKind.system)
                Text(localized("SVG 模板")).tag(ReaderBatteryVisualKind.importedSVG)
            }

            Toggle(localized("顯示百分比"), isOn: showsBatteryPercentageBinding)

            if component.configuration.batteryVisual == .importedSVG {
                Button {
                    showingSVGPicker = true
                } label: {
                    HStack {
                        Text(localized("選擇 SVG 模板"))
                        Spacer()
                        Text(selectedSVGAsset?.displayName ?? localized("尚未選擇"))
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                }

                if svgIsLoading {
                    HStack(spacing: DSSpacing.sm) {
                        ProgressView()
                        Text(localized("正在載入 SVG 模板"))
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if svgLoadFailed {
                    Label(localized("SVG 模板載入失敗。"), systemImage: "exclamationmark.triangle")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.destructive)
                } else if let selectedSVGAsset {
                    ReaderBatterySVGStatePreviewStrip(
                        assetID: selectedSVGAsset.id,
                        store: svgAssetStore,
                        color: resolvedStyle.color
                    )
                } else {
                    Text(localized("選擇或匯入一個 SVG 模板；缺少模板時會使用系統電池圖示。"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .listRowBackground(DSColor.surface)
    }

    private var customTextBinding: Binding<String> {
        Binding(
            get: { customTextDraft },
            set: { newValue in
                let limited = String(
                    newValue.prefix(ReaderOverlayComponentConfiguration.maximumCustomTextLength)
                )
                customTextDraft = limited
                guard !limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                updateComponent { $0.configuration.customText = limited }
            }
        )
    }

    private var fontBinding: Binding<ReaderOverlayFontReference> {
        binding(\.style.font)
    }

    private var fontSizeBinding: Binding<Double> {
        binding(\.style.fontSize)
    }

    private var fontWeightBinding: Binding<ReaderOverlayFontWeight> {
        binding(\.style.fontWeight)
    }

    private var colorSourceBinding: Binding<ReaderOverlayColorSource> {
        Binding(
            get: { component.style.color.source },
            set: { source in
                updateComponent { component in
                    component.style.color.source = source
                    if source == .custom, component.style.color.hexRGBA == nil {
                        component.style.color.hexRGBA = ReaderOverlayColorCodec.hexRGBA(
                            readerStyle.textColor
                        )
                    }
                }
            }
        )
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hexRGBA = component.style.color.hexRGBA {
                    return ReaderOverlayColorCodec.color(hexRGBA: hexRGBA)
                }
                return Color(uiColor: readerStyle.textColor)
            },
            set: { color in
                guard let rgba = ReaderOverlayColorCodec.hexRGBA(UIColor(color)) else { return }
                updateComponent { component in
                    component.style.color = ReaderOverlayColorReference(
                        source: .custom,
                        hexRGBA: rgba
                    )
                }
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        binding(\.style.opacity)
    }

    private var pointsText: String {
        String(
            format: localized("ReaderOverlay.Format.Points"),
            Int(component.style.fontSize.rounded())
        )
    }

    private var percentText: String {
        String(
            format: localized("ReaderOverlay.Format.Percent"),
            Int((component.style.opacity * 100).rounded())
        )
    }

    private var displayFormatBinding: Binding<ReaderOverlayDisplayFormat> {
        binding(\.configuration.displayFormat)
    }

    private var batteryVisualBinding: Binding<ReaderBatteryVisualKind> {
        binding(\.configuration.batteryVisual)
    }

    private var showsBatteryPercentageBinding: Binding<Bool> {
        binding(\.configuration.showsBatteryPercentage)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<ReaderOverlayComponent, Value>
    ) -> Binding<Value> {
        Binding(
            get: { component[keyPath: keyPath] },
            set: { value in
                updateComponent { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func updateComponent(
        _ update: (inout ReaderOverlayComponent) -> Void
    ) {
        var updated = component
        update(&updated)
        component = updated.normalized
    }

    private func saveAndDismiss() {
        var draft = ReaderOverlayComponentDraft(originalComponent)
        draft.value = component
        onSave(draft.committed())
        dismiss()
    }

    private var compatibleFormats: [ReaderOverlayDisplayFormat] {
        ReaderOverlayComponentEditing.compatibleFormats(for: component.kind)
    }

    private var customTextIsValid: Bool {
        !customTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fontDisplayName: String {
        switch component.style.font.kind {
        case .system:
            localized("系統字體")
        case .reader:
            localized("目前閱讀字體")
        case .imported:
            importedFonts.first {
                $0.postScriptName == component.style.font.postScriptName
            }?.displayName ?? component.style.font.postScriptName ?? localized("未指定")
        }
    }

    private var missingFontName: String? {
        guard component.style.font.kind == .imported,
              let name = component.style.font.postScriptName,
              (!readerStyle.availablePostScriptNames.contains(name)
                  || UIFont(name: name, size: CGFloat(component.style.fontSize)) == nil) else {
            return nil
        }
        return name
    }

    private var selectedSVGAsset: ReaderOverlaySVGAsset? {
        guard let id = component.configuration.svgAssetID else { return nil }
        return svgAssets.first { $0.id == id }
    }

    private var allReferencedAssetIDs: Set<UUID> {
        guard let selectedID = component.configuration.svgAssetID else {
            return referencedAssetIDs
        }
        return referencedAssetIDs.union([selectedID])
    }

    private var resolvedStyle: ReaderOverlayResolvedStyle {
        ReaderOverlayPresentationResolver.resolveStyle(
            component.style,
            readerFont: readerStyle.font,
            readerTextColor: readerStyle.textColor,
            availablePostScriptNames: readerStyle.availablePostScriptNames
        )
    }

    private func ensureValidInitialConfiguration() {
        if component.kind == .customText,
           component.configuration.customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateComponent { $0.configuration.customText = customTextDraft }
        }
        if !compatibleFormats.isEmpty,
           !compatibleFormats.contains(component.configuration.displayFormat),
           let fallback = compatibleFormats.first {
            updateComponent { $0.configuration.displayFormat = fallback }
        }
    }

    @MainActor
    private func reloadSVGAssets() async {
        svgIsLoading = true
        defer { svgIsLoading = false }
        do {
            svgAssets = try await svgAssetStore.assets()
            svgLoadFailed = false
        } catch {
            svgAssets = []
            svgLoadFailed = true
        }
    }
}

private extension ReaderOverlayFontWeight {
    static let allCasesForEditor: [ReaderOverlayFontWeight] = [
        .regular,
        .medium,
        .semibold,
        .bold
    ]

    var localizedTitle: String {
        switch self {
        case .regular: localized("一般")
        case .medium: localized("中等")
        case .semibold: localized("半粗體")
        case .bold: localized("粗體")
        }
    }
}

private extension ReaderOverlayDisplayFormat {
    var localizedTitle: String {
        switch self {
        case .automatic: localized("自動")
        case .compact: localized("精簡")
        case .detailed: localized("詳細")
        case .fraction: localized("目前／總數")
        case .percentage: localized("百分比")
        case .hourMinute24: localized("24 小時制")
        case .hourMinute12: localized("12 小時制")
        }
    }
}

enum ReaderOverlayColorCodec {
    static func color(hexRGBA value: UInt32) -> Color {
        Color(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255
        )
    }

    static func hexRGBA(_ color: UIColor) -> UInt32? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (byte(red) << 24) | (byte(green) << 16) | (byte(blue) << 8) | byte(alpha)
    }

    private static func byte(_ value: CGFloat) -> UInt32 {
        UInt32((min(max(value, 0), 1) * 255).rounded())
    }
}

#if DEBUG
private struct ReaderOverlayComponentEditPreviewHarness: View {
    @State private var component = ReaderOverlayComponent.make(
        kind: .battery,
        position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.5)
    )
    private let store = ReaderOverlaySVGAssetStore(
        rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderOverlayComponentEditPreview", isDirectory: true)
    )

    var body: some View {
        ReaderOverlayComponentEditView(
            component: $component,
            readerStyle: ReaderOverlayReaderStyle(
                font: UIFont.preferredFont(forTextStyle: .body),
                textColor: .label,
                availablePostScriptNames: []
            ),
            importedFonts: [],
            svgAssetStore: store,
            referencedAssetIDs: []
        )
    }
}

#Preview {
    ReaderOverlayComponentEditPreviewHarness()
}
#endif
