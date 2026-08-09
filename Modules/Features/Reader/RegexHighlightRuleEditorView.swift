import CoreText
import SwiftUI
import UIKit

struct RegexHighlightRuleEditorView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case basic
        case background
        case spacing
        case css

        var id: Self { self }
        var titleKey: String {
            switch self {
            case .basic: "基礎"
            case .background: "背景圖"
            case .spacing: "邊距"
            case .css: "CSS"
            }
        }
    }

    private enum BackgroundKind: String, CaseIterable, Identifiable {
        case none
        case color
        case gradient
        case image

        var id: Self { self }
        var titleKey: String {
            switch self {
            case .none: "無背景"
            case .color: "純色"
            case .gradient: "漸層"
            case .image: "圖片"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var model: RegexHighlightRuleEditorModel
    @State private var selectedTab = Tab.basic
    @State private var appearance = ReaderStyleAppearance.light
    @State private var cssSource = ""
    @State private var showingAssets = false
    @State private var confirmLowContrast = false

    init(rule: RegexHighlightRule, onSave: @escaping (RegexHighlightRule) throws -> Void) {
        _model = StateObject(wrappedValue: RegexHighlightRuleEditorModel(rule: rule, onSave: onSave))
    }

    var body: some View {
        Form {
            Section {
                Picker(localized("編輯頁面"), selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(localized(tab.titleKey)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch selectedTab {
            case .basic:
                basicSections
            case .background:
                backgroundSections
            case .spacing:
                spacingSections
            case .css:
                cssSections
            }
        }
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("編輯規則"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(localized("儲存"), action: requestSave)
            }
        }
        .onAppear { synchronizeCSS() }
        .onChange(of: appearance) { _, _ in synchronizeCSS() }
        .onChange(of: selectedTab) { _, tab in
            if tab == .css { synchronizeCSS() }
        }
        .sheet(isPresented: $showingAssets) {
            NavigationStack {
                ReaderStyleAssetLibraryView(
                    referenceScope: "regex-rule-editor.\(model.original.id)",
                    references: assetReferences,
                    onSelect: { asset in
                        mutateStyle {
                            $0.decoration.backgroundColorHex = nil
                            $0.decoration.backgroundGradient = nil
                            $0.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: asset.id)
                        }
                        showingAssets = false
                    },
                    onDeleteReferencedAsset: { id in
                        guard await model.deleteAsset(id: id, store: .shared) else {
                            throw model.saveError ?? ReaderStyleAssetStoreError.writeFailed
                        }
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(localized("關閉")) { showingAssets = false }
                    }
                }
            }
        }
        .alert(localized("對比度偏低"), isPresented: $confirmLowContrast) {
            Button(localized("取消"), role: .cancel) {}
            Button(localized("仍要儲存")) { performSave() }
        } message: {
            Text(localized("文字與背景的對比度低於 4.5:1，可能不易閱讀。"))
        }
    }

    @ViewBuilder
    private var basicSections: some View {
        Section(localized("匹配模板")) {
            Toggle(localized("啟用此規則"), isOn: $model.isEnabled)
            TextField(localized("名稱"), text: $model.name)
                .disabled(model.isBuiltIn)
            Text(localized("正則"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
            TextEditor(text: $model.pattern)
                .font(DSFont.body.monospaced())
                .frame(minHeight: 72)
                .disabled(model.isBuiltIn)
                .accessibilityLabel(localized("正則"))
            if model.isBuiltIn {
                Text(localized("內置規則的名稱與正則模板固定；可調整樣式，或複製為自定義規則後修改。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
            Toggle(localized("忽略大小寫"), isOn: optionBinding(.caseInsensitive))
            Toggle(localized("匹配不跨段"), isOn: optionBinding(.doesNotCrossParagraph))
            errorText(model.regexError.map(String.init(describing:)))
            errorText(model.saveError?.localizedDescription)
        }
        appearanceSection
        Section(localized("文字")) {
                Menu {
                    Button(localized("跟隨閱讀字體")) { mutateStyle { $0.text.fontPostScriptName = nil } }
                    ForEach(settings.userFonts, id: \.postScriptName) { font in
                        Button(font.displayName) { mutateStyle { $0.text.fontPostScriptName = font.postScriptName } }
                    }
                } label: {
                    LabeledContent(localized("字體"), value: fontDisplayName(activeStyle.text.fontPostScriptName))
                }
                ColorPicker(
                    localized("文字顏色"),
                    selection: colorBinding(
                        hex: activeStyle.text.colorHex ?? defaultTextHex,
                        update: { value in mutateStyle { $0.text.colorHex = value } }
                    ),
                    supportsOpacity: false
                )
                metricSlider(
                    localized("字號"),
                    value: styleDoubleBinding(\.text.fontSize, fallback: 18),
                    range: 8...72,
                    step: 1,
                    unit: "pt"
                )
                Stepper(value: styleIntBinding(\.text.fontWeight, fallback: 400), in: 100...900, step: 100) {
                    LabeledContent(localized("字重"), value: "\(activeStyle.text.fontWeight ?? 400)")
                }
                Toggle(localized("斜體"), isOn: styleBoolBinding(\.text.italic))
                Toggle(localized("底線"), isOn: styleBoolBinding(\.text.underline))
                Toggle(localized("刪除線"), isOn: styleBoolBinding(\.text.strikethrough))
        }
        Section(localized("即時測試")) {
            TextEditor(text: $model.testText)
                .frame(minHeight: 96)
                .accessibilityLabel(localized("即時測試"))
            highlightedPreview
            Text(String(format: localized("命中 %d 處"), model.matches.count))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
    }

    @ViewBuilder
    private var backgroundSections: some View {
        appearanceSection
        Section(localized("背景")) {
                Picker(localized("背景類型"), selection: backgroundKindBinding) {
                    ForEach(BackgroundKind.allCases) { kind in
                        Text(localized(kind.titleKey)).tag(kind)
                    }
                }
                switch activeBackgroundKind {
                case .none:
                    Text(localized("不繪製背景，只套用文字樣式。"))
                        .foregroundStyle(.secondary)
                case .color:
                    ColorPicker(
                        localized("背景顏色"),
                        selection: colorBinding(
                            hex: activeStyle.decoration.backgroundColorHex ?? defaultBackgroundHex,
                            update: { value in mutateStyle { $0.decoration.backgroundColorHex = value } }
                        ),
                        supportsOpacity: false
                    )
                case .gradient:
                    gradientControls
                case .image:
                    imageControls
                }
                metricSlider(
                    localized("透明度"),
                    value: styleDoubleBinding(\.decoration.opacity, fallback: 1),
                    range: 0...1,
                    step: 0.05,
                    unit: "%",
                    multiplier: 100
                )
        }
        contrastWarningSection
    }

    @ViewBuilder
    private var spacingSections: some View {
        appearanceSection
        Section(localized("內距")) {
                ForEach(ReaderStyleEdge.allCases, id: \.rawValue) { edge in
                    metricSlider(
                        String(format: localized("%@內距"), localized(edge.editorTitleKey)),
                        value: edgeBinding(edge),
                        range: 0...48,
                        step: 1,
                        unit: "pt"
                    )
                }
                metricSlider(
                    localized("片段間隔"),
                    value: styleDoubleBinding(\.decoration.visualGap, fallback: 0),
                    range: 0...24,
                    step: 1,
                    unit: "pt"
                )
                metricSlider(
                    localized("圓角"),
                    value: styleDoubleBinding(\.decoration.cornerRadius, fallback: 0),
                    range: 0...48,
                    step: 1,
                    unit: "pt"
                )
        }
        Section(localized("每邊邊框")) {
                ForEach(ReaderStyleEdge.allCases, id: \.rawValue) { edge in
                    DisclosureGroup(localized(edge.editorTitleKey)) {
                        let border = activeStyle.decoration.borders?[edge]
                            ?? ReaderStyleBorder(width: 0, colorHex: 0x8E8E93)
                        metricSlider(
                            localized("粗細"),
                            value: borderWidthBinding(edge, fallback: border),
                            range: 0...12,
                            step: 0.5,
                            unit: "pt"
                        )
                        ColorPicker(
                            localized("顏色"),
                            selection: colorBinding(hex: border.colorHex) { updateBorder(edge, color: $0) },
                            supportsOpacity: false
                        )
                    }
                }
        }
        Section(localized("陰影")) {
                Button {
                    mutateStyle { $0.decoration.shadows.append(.init(colorHex: 0, radius: 4, x: 0, y: 2)) }
                } label: {
                    Label(localized("新增陰影"), systemImage: "plus")
                }
                ForEach(Array(activeStyle.decoration.shadows.enumerated()), id: \.offset) { index, shadow in
                    DisclosureGroup(String(format: localized("陰影 %d"), index + 1)) {
                        ColorPicker(
                            localized("陰影顏色"),
                            selection: colorBinding(hex: shadow.colorHex) { color in
                                updateShadow(index) { $0.colorHex = color }
                            },
                            supportsOpacity: false
                        )
                        metricSlider(localized("模糊"), value: shadowBinding(index, \.radius, shadow.radius), range: 0...48, step: 1, unit: "pt")
                        metricSlider(localized("水平位移"), value: shadowBinding(index, \.x, shadow.x), range: -48...48, step: 1, unit: "pt")
                        metricSlider(localized("垂直位移"), value: shadowBinding(index, \.y, shadow.y), range: -48...48, step: 1, unit: "pt")
                        Button(role: .destructive) {
                            mutateStyle {
                                guard $0.decoration.shadows.indices.contains(index) else { return }
                                $0.decoration.shadows.remove(at: index)
                            }
                        } label: {
                            Label(localized("刪除陰影"), systemImage: "trash")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var cssSections: some View {
        appearanceSection
        Section(localized("CSS 宣告")) {
                Text(localized("只接受單一規則的 declaration block，不接受 selector、HTML 或絕對定位。"))
                    .font(DSFont.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $cssSource)
                    .font(DSFont.body.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                errorText(model.cssError.map(String.init(describing:)))
            Button {
                synchronizeCSS()
            } label: {
                Label(localized("重新產生標準 CSS"), systemImage: "arrow.clockwise")
            }
            Button {
                if model.applyCSS(cssSource, appearance: appearance) { synchronizeCSS() }
            } label: {
                Label(localized("套用 CSS"), systemImage: "checkmark")
                }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(localized("編輯外觀"), selection: $appearance) {
                Text(localized("亮色模式")).tag(ReaderStyleAppearance.light)
                Text(localized("深色模式")).tag(ReaderStyleAppearance.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var gradientControls: some View {
        let gradient = activeStyle.decoration.backgroundGradient ?? defaultGradient
        metricSlider(
            localized("漸層角度"),
            value: gradientAngleBinding,
            range: 0...360,
            step: 1,
            unit: "°"
        )
        ForEach(gradient.stops.indices, id: \.self) { index in
            ColorPicker(
                String(format: localized("漸層顏色 %d"), index + 1),
                selection: colorBinding(hex: gradient.stops[index].colorHex) { color in
                    mutateStyle {
                        guard $0.decoration.backgroundGradient?.stops.indices.contains(index) == true else { return }
                        $0.decoration.backgroundGradient?.stops[index].colorHex = color
                    }
                },
                supportsOpacity: false
            )
        }
    }

    @ViewBuilder
    private var imageControls: some View {
        Button { showingAssets = true } label: {
            Label(
                activeStyle.decoration.backgroundImage == nil
                    ? localized("選擇背景圖片")
                    : localized("更換背景圖片"),
                systemImage: "photo.on.rectangle"
            )
        }
        if let image = activeStyle.decoration.backgroundImage {
            Picker(localized("圖片填充方式"), selection: imageModeBinding) {
                ForEach(ReaderStyleImageContentMode.allCases, id: \.self) { mode in
                    Text(localized(mode.editorTitleKey)).tag(mode)
                }
            }
            metricSlider(localized("圖片焦點 X"), value: imageDoubleBinding(\.focalX, image.focalX), range: 0...1, step: 0.05, unit: "%", multiplier: 100)
            metricSlider(localized("圖片焦點 Y"), value: imageDoubleBinding(\.focalY, image.focalY), range: 0...1, step: 0.05, unit: "%", multiplier: 100)
            metricSlider(localized("圖片透明度"), value: imageDoubleBinding(\.opacity, image.opacity), range: 0...1, step: 0.05, unit: "%", multiplier: 100)
        } else {
            Text(localized("請從共用素材庫選擇或匯入圖片。"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contrastWarningSection: some View {
        if let warning = currentContrastWarning {
            Section {
                Label(
                    String(format: localized("文字與背景對比度為 %.1f:1。"), warning.ratio),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(DSColor.warning)
            }
        }
    }

    @ViewBuilder
    private var highlightedPreview: some View {
        switch Result(catching: { try model.previewAttributedString(appearance: appearance) }) {
        case .success(let attributed):
            RegexHighlightLivePreview(attributed: attributed)
                .frame(minHeight: DSLayout.minimumTapTarget * 3)
                .padding(.vertical, DSSpacing.sm)
                .accessibilityLabel(model.testText)
        case .failure(let error):
            Label(localized("預覽失敗"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(DSColor.warning)
                .accessibilityValue(error.localizedDescription)
        }
    }

    private var activeStyle: ReaderStyleRuleStyle {
        appearance == .light ? model.lightStyle : model.darkStyle
    }

    private func mutateStyle(_ mutation: (inout ReaderStyleRuleStyle) -> Void) {
        switch appearance {
        case .light: mutation(&model.lightStyle)
        case .dark: mutation(&model.darkStyle)
        }
    }

    private var activeBackgroundKind: BackgroundKind {
        let decoration = activeStyle.decoration
        if decoration.backgroundImage != nil { return .image }
        if decoration.backgroundGradient != nil { return .gradient }
        if decoration.backgroundColorHex != nil { return .color }
        return .none
    }

    private var backgroundKindBinding: Binding<BackgroundKind> {
        Binding(get: { activeBackgroundKind }) { kind in
            mutateStyle { style in
                style.decoration.backgroundColorHex = nil
                style.decoration.backgroundGradient = nil
                style.decoration.backgroundImage = nil
                switch kind {
                case .none, .image: break
                case .color: style.decoration.backgroundColorHex = defaultBackgroundHex
                case .gradient: style.decoration.backgroundGradient = defaultGradient
                }
            }
            if kind == .image { showingAssets = true }
        }
    }

    private var defaultGradient: ReaderStyleGradient {
        RegexHighlightEditorDefaults.gradient(for: appearance)
    }

    private var gradientAngleBinding: Binding<Double> {
        Binding(
            get: { activeStyle.decoration.backgroundGradient?.angleDegrees ?? 90 },
            set: { value in mutateStyle { $0.decoration.backgroundGradient?.angleDegrees = value } }
        )
    }

    private var imageModeBinding: Binding<ReaderStyleImageContentMode> {
        Binding(
            get: { activeStyle.decoration.backgroundImage?.contentMode ?? .fill },
            set: { value in mutateStyle { $0.decoration.backgroundImage?.contentMode = value } }
        )
    }

    private func imageDoubleBinding(
        _ keyPath: WritableKeyPath<ReaderStyleImagePresentation, Double>,
        _ fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { activeStyle.decoration.backgroundImage?[keyPath: keyPath] ?? fallback },
            set: { value in mutateStyle { $0.decoration.backgroundImage?[keyPath: keyPath] = value } }
        )
    }

    private func optionBinding(_ option: RegexHighlightOptions) -> Binding<Bool> {
        Binding(
            get: { model.options.contains(option) },
            set: { enabled in
                if enabled { model.options.insert(option) } else { model.options.remove(option) }
            }
        )
    }

    private func styleDoubleBinding(
        _ keyPath: WritableKeyPath<ReaderStyleRuleStyle, Double?>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { activeStyle[keyPath: keyPath] ?? fallback },
            set: { value in mutateStyle { $0[keyPath: keyPath] = value } }
        )
    }

    private func styleIntBinding(
        _ keyPath: WritableKeyPath<ReaderStyleRuleStyle, Int?>,
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { activeStyle[keyPath: keyPath] ?? fallback },
            set: { value in mutateStyle { $0[keyPath: keyPath] = value } }
        )
    }

    private func styleBoolBinding(_ keyPath: WritableKeyPath<ReaderStyleRuleStyle, Bool?>) -> Binding<Bool> {
        Binding(
            get: { activeStyle[keyPath: keyPath] ?? false },
            set: { value in mutateStyle { $0[keyPath: keyPath] = value } }
        )
    }

    private func edgeBinding(_ edge: ReaderStyleEdge) -> Binding<Double> {
        Binding(
            get: { (activeStyle.decoration.padding ?? .init()).editorValue(for: edge) },
            set: { value in
                mutateStyle {
                    var edges = $0.decoration.padding ?? .init()
                    edges.setEditorValue(value, for: edge)
                    $0.decoration.padding = edges
                }
            }
        )
    }

    private func borderWidthBinding(
        _ edge: ReaderStyleEdge,
        fallback: ReaderStyleBorder
    ) -> Binding<Double> {
        Binding(
            get: { activeStyle.decoration.borders?[edge]?.width ?? fallback.width },
            set: { value in
                mutateStyle {
                    var borders = $0.decoration.borders ?? [:]
                    let color = borders[edge]?.colorHex ?? fallback.colorHex
                    borders[edge] = .init(width: value, colorHex: color)
                    $0.decoration.borders = borders
                }
            }
        )
    }

    private func updateBorder(_ edge: ReaderStyleEdge, color: UInt32) {
        mutateStyle {
            var borders = $0.decoration.borders ?? [:]
            borders[edge] = .init(width: borders[edge]?.width ?? 1, colorHex: color)
            $0.decoration.borders = borders
        }
    }

    private func shadowBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ReaderStyleShadow, Double>,
        _ fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                let shadows = activeStyle.decoration.shadows
                return shadows.indices.contains(index) ? shadows[index][keyPath: keyPath] : fallback
            },
            set: { value in updateShadow(index) { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateShadow(_ index: Int, _ mutation: (inout ReaderStyleShadow) -> Void) {
        mutateStyle {
            guard $0.decoration.shadows.indices.contains(index) else { return }
            mutation(&$0.decoration.shadows[index])
        }
    }

    @ViewBuilder
    private func metricSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        multiplier: Double = 1
    ) -> some View {
        let formatted = String(format: "%.0f %@", value.wrappedValue * multiplier, unit)
        LabeledContent(title, value: formatted)
        Slider(value: value, in: range, step: step)
            .accessibilityLabel(title)
            .accessibilityValue(formatted)
    }

    @ViewBuilder
    private func errorText(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.destructive)
        }
    }

    private var currentContrastWarning: ReaderStyleContrastWarning? {
        guard let foreground = activeStyle.text.colorHex,
              let background = activeStyle.decoration.backgroundColorHex else { return nil }
        return ReaderStyleContrastEvaluator.warning(foregroundHex: foreground, backgroundHex: background)
    }

    private var hasLowContrast: Bool {
        [model.lightStyle, model.darkStyle].contains { style in
            guard let foreground = style.text.colorHex,
                  let background = style.decoration.backgroundColorHex else { return false }
            return ReaderStyleContrastEvaluator.warning(
                foregroundHex: foreground,
                backgroundHex: background
            ) != nil
        }
    }

    private func requestSave() {
        model.refreshMatches()
        guard model.regexError == nil else {
            selectedTab = .basic
            return
        }
        if hasLowContrast {
            confirmLowContrast = true
        } else {
            performSave()
        }
    }

    private func performSave() {
        if model.save() { dismiss() }
    }

    private func synchronizeCSS() {
        cssSource = model.encodedCSS(for: appearance)
    }

    private var assetReferences: [UUID: [ReaderStyleAssetReference]] {
        var result: [UUID: [ReaderStyleAssetReference]] = [:]
        for id in [
            model.lightStyle.decoration.backgroundImage?.assetID,
            model.darkStyle.decoration.backgroundImage?.assetID,
        ].compactMap({ $0 }) {
            result[id, default: []].append(.regexRule(model.name))
        }
        return result
    }

    private func colorBinding(hex: UInt32, update: @escaping (UInt32) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(readerStyleHex: hex)) },
            set: { update($0.editorRGBHex ?? hex) }
        )
    }

    private func fontDisplayName(_ postScriptName: String?) -> String {
        guard let postScriptName else { return localized("跟隨閱讀字體") }
        return settings.userFonts.first(where: { $0.postScriptName == postScriptName })?.displayName
            ?? postScriptName
    }

    private var defaultTextHex: UInt32 { appearance == .light ? 0x1C1C1E : 0xF2F2F7 }
    private var defaultBackgroundHex: UInt32 { appearance == .light ? 0xFFFFFF : 0x1C1C1E }
}

enum RegexHighlightEditorDefaults {
    static func gradient(for appearance: ReaderStyleAppearance) -> ReaderStyleGradient {
        ReaderStyleGradient(
            angleDegrees: 90,
            stops: [
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xFFE1C7 : 0x5A321C,
                    location: 0
                ),
                ReaderStyleGradientStop(
                    colorHex: appearance == .light ? 0xD8E8FF : 0x3A4658,
                    location: 1
                ),
            ]
        )
    }
}

private struct RegexHighlightLivePreview: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> RegexHighlightLivePreviewView {
        RegexHighlightLivePreviewView()
    }

    func updateUIView(_ view: RegexHighlightLivePreviewView, context: Context) {
        view.attributed = attributed
    }
}

private final class RegexHighlightLivePreviewView: UIView {
    var attributed = NSAttributedString() {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard attributed.length > 0,
              bounds.width > 1,
              bounds.height > 1,
              let context = UIGraphicsGetCurrentContext() else { return }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        CoreTextHorizontalLineDrawer.drawLines(
            of: frame,
            contentWidth: bounds.width,
            contentMinX: 0,
            contentMinY: 0,
            isLastPage: true,
            attrStr: attributed,
            hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
            bottomJustified: false,
            in: context
        )
        context.restoreGState()
    }
}

private extension ReaderStyleEdge {
    var editorTitleKey: String {
        switch self {
        case .top: "上"
        case .leading: "左"
        case .bottom: "下"
        case .trailing: "右"
        }
    }
}

private extension ReaderStyleEdges {
    func editorValue(for edge: ReaderStyleEdge) -> Double {
        switch edge {
        case .top: top
        case .leading: leading
        case .bottom: bottom
        case .trailing: trailing
        }
    }

    mutating func setEditorValue(_ value: Double, for edge: ReaderStyleEdge) {
        switch edge {
        case .top: top = value
        case .leading: leading = value
        case .bottom: bottom = value
        case .trailing: trailing = value
        }
    }
}

private extension ReaderStyleImageContentMode {
    var editorTitleKey: String {
        switch self {
        case .fill: "填滿"
        case .fit: "適應"
        case .tile: "平鋪"
        case .stretch: "拉伸"
        }
    }
}

private extension Color {
    var editorRGBHex: UInt32? {
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return nil }
        return UInt32((red * 255).rounded()) << 16
            | UInt32((green * 255).rounded()) << 8
            | UInt32((blue * 255).rounded())
    }
}
