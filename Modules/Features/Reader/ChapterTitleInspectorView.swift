import SwiftUI

struct ChapterTitleInspectorView: View {
    @ObservedObject var model: ChapterTitleDesignerModel
    @ObservedObject private var settings = GlobalSettings.shared
    @State private var showingAssetLibrary = false
    @State private var contrastAcknowledged = false

    private var selectedLayer: ChapterTitleLayer? {
        guard let id = model.selectedLayerID else { return nil }
        return model.draft.layers.first { $0.id == id }
    }

    var body: some View {
        Form {
            if let layer = selectedLayer {
                appearanceSection.interfaceSectionSurface()
                identitySection(layer).interfaceSectionSurface()
                contentSection(layer).interfaceSectionSurface()
                typographySection(layer).interfaceSectionSurface()
                backgroundSection(layer).interfaceSectionSurface()
                spacingSection(layer).interfaceSectionSurface()
                borderSection(layer).interfaceSectionSurface()
                contrastSection(layer).interfaceSectionSurface()
            } else {
                ContentUnavailableView(
                    localized("未選擇元素"),
                    systemImage: "square.dashed",
                    description: Text(localized("在畫布或元素列表選擇一個圖層。"))
                )
            }
        }
        .sheet(isPresented: $showingAssetLibrary) {
            NavigationStack {
                ReaderStyleAssetLibraryView(
                    referenceScope: "chapter-title-designer",
                    references: assetReferences,
                    onSelect: { asset in
                        assignBackground(asset)
                        showingAssetLibrary = false
                    },
                    onDeleteReferencedAsset: { id in
                        guard await model.deleteAsset(id: id, store: .shared) else {
                            throw model.validationError ?? ReaderStyleAssetStoreError.writeFailed
                        }
                    }
                )
                .navigationTitle(localized("素材庫"))
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(localized("關閉")) { showingAssetLibrary = false }
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(localized("編輯外觀"), selection: $model.activeAppearance) {
                Text(localized("亮色模式")).tag(ReaderStyleAppearance.light)
                Text(localized("深色模式")).tag(ReaderStyleAppearance.dark)
            }
            .pickerStyle(.segmented)
        }
    }

    private func identitySection(_ layer: ChapterTitleLayer) -> some View {
        Section(localized("基本")) {
            TextField(
                localized("名稱"),
                text: Binding(
                    get: { selectedLayer?.name ?? layer.name },
                    set: { model.rename(id: layer.id, to: $0) }
                )
            )
            Toggle(
                localized("顯示"),
                isOn: Binding(
                    get: { selectedLayer?.isVisible ?? layer.isVisible },
                    set: { model.setVisible($0, id: layer.id) }
                )
            )
            Toggle(
                localized("鎖定"),
                isOn: Binding(
                    get: { selectedLayer?.isLocked ?? layer.isLocked },
                    set: { model.setLocked($0, id: layer.id) }
                )
            )
        }
    }

    @ViewBuilder
    private func contentSection(_ layer: ChapterTitleLayer) -> some View {
        if case let .text(text) = layer.content {
            Section(localized("內容")) {
                TextField(
                    localized("文字"),
                    text: Binding(
                        get: {
                            guard case let .text(current) = selectedLayer?.content else { return text }
                            return current
                        },
                        set: { model.updateContent(id: layer.id, content: .text($0)) }
                    ),
                    axis: .vertical
                )
            }
        } else if layer.kind == .image {
            Section(localized("內容")) {
                Button { showingAssetLibrary = true } label: {
                    Label(localized("選擇圖片"), systemImage: "photo")
                }
                if case let .image(assetID) = layer.content {
                    let presentation = appearanceStyle(layer).imagePresentation
                        ?? ReaderStyleImagePresentation(assetID: assetID, contentMode: .fit)
                    Picker(
                        localized("圖片填充方式"),
                        selection: contentImageBinding(
                            layer,
                            assetID: assetID,
                            keyPath: \.contentMode,
                            fallback: presentation.contentMode
                        )
                    ) {
                        ForEach(ReaderStyleImageContentMode.allCases, id: \.self) { mode in
                            Text(localized(mode.titleKey)).tag(mode)
                        }
                    }
                    metricSlider(
                        localized("圖片透明度"),
                        value: contentImageBinding(
                            layer,
                            assetID: assetID,
                            keyPath: \.opacity,
                            fallback: presentation.opacity
                        ),
                        range: 0...1,
                        step: 0.05,
                        unit: "%",
                        displayMultiplier: 100
                    )
                    Button(role: .destructive) {
                        model.updateContent(id: layer.id, content: .none)
                    } label: {
                        Label(localized("移除圖片"), systemImage: "trash")
                    }
                }
            }
        } else if case let .line(line) = layer.content {
            Section(localized("線條")) {
                metricSlider(
                    localized("線條粗細"),
                    value: doubleBinding(
                        get: {
                            guard case let .line(value) = selectedLayer?.content else { return line.width }
                            return value.width
                        },
                        set: { value in
                            var updated = line
                            if case let .line(current) = selectedLayer?.content { updated = current }
                            updated.width = value
                            model.updateContent(id: layer.id, content: .line(updated))
                        }
                    ),
                    range: 0.5...24,
                    step: 0.5,
                    unit: "pt"
                )
                ColorPicker(
                    localized("線條顏色"),
                    selection: colorBinding(hex: line.colorHex) { hex in
                        var updated = line
                        if case let .line(current) = selectedLayer?.content { updated = current }
                        updated.colorHex = hex
                        model.updateContent(id: layer.id, content: .line(updated))
                    },
                    supportsOpacity: false
                )
                Toggle(
                    localized("虛線"),
                    isOn: Binding(
                        get: {
                            guard case let .line(value) = selectedLayer?.content else { return line.isDashed }
                            return value.isDashed
                        },
                        set: { value in
                            var updated = line
                            if case let .line(current) = selectedLayer?.content { updated = current }
                            updated.isDashed = value
                            model.updateContent(id: layer.id, content: .line(updated))
                        }
                    )
                )
            }
        }
    }

    private func typographySection(_ layer: ChapterTitleLayer) -> some View {
        let style = appearanceStyle(layer)
        return Section(localized("文字")) {
            Menu {
                Button(localized("跟隨閱讀字體")) {
                    mutateStyle(layer) { $0.ruleStyle.text.fontPostScriptName = nil }
                }
                ForEach(settings.userFonts, id: \.postScriptName) { font in
                    Button(font.displayName) {
                        mutateStyle(layer) { $0.ruleStyle.text.fontPostScriptName = font.postScriptName }
                    }
                }
            } label: {
                LabeledContent(
                    localized("字體"),
                    value: fontDisplayName(style.ruleStyle.text.fontPostScriptName)
                )
            }
            ColorPicker(
                localized("文字顏色"),
                selection: colorBinding(
                    hex: style.ruleStyle.text.colorHex ?? defaultTextHex,
                    update: { value in mutateStyle(layer) { $0.ruleStyle.text.colorHex = value } }
                ),
                supportsOpacity: false
            )
            metricSlider(
                localized("字號"),
                value: doubleBinding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.text.fontSize ?? 24 },
                    set: { value in mutateStyle(layer) { $0.ruleStyle.text.fontSize = value } }
                ),
                range: 8...96,
                step: 1,
                unit: "pt"
            )
            Stepper(
                value: Binding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.text.fontWeight ?? 400 },
                    set: { value in mutateStyle(layer) { $0.ruleStyle.text.fontWeight = value } }
                ),
                in: 100...900,
                step: 100
            ) {
                LabeledContent(localized("字重"), value: "\(appearanceStyle(selectedLayer ?? layer).ruleStyle.text.fontWeight ?? 400)")
            }
            Toggle(
                localized("斜體"),
                isOn: optionalBoolBinding(layer, keyPath: \.italic)
            )
            Toggle(
                localized("底線"),
                isOn: optionalBoolBinding(layer, keyPath: \.underline)
            )
            Toggle(
                localized("刪除線"),
                isOn: optionalBoolBinding(layer, keyPath: \.strikethrough)
            )
            Picker(
                localized("對齊"),
                selection: Binding(
                    get: { appearanceStyle(selectedLayer ?? layer).textAlignment },
                    set: { value in mutateStyle(layer) { $0.textAlignment = value } }
                )
            ) {
                ForEach(ChapterTitleAlignment.allCases, id: \.self) { alignment in
                    Label(localized(alignment.localizedNameKey), systemImage: alignment.systemImageName)
                        .tag(alignment)
                }
            }
        }
    }

    private func backgroundSection(_ layer: ChapterTitleLayer) -> some View {
        let decoration = appearanceStyle(layer).ruleStyle.decoration
        return Section(localized("背景")) {
            ColorPicker(
                localized("背景顏色"),
                selection: colorBinding(
                    hex: decoration.backgroundColorHex ?? defaultBackgroundHex,
                    update: { value in mutateStyle(layer) { $0.ruleStyle.decoration.backgroundColorHex = value } }
                ),
                supportsOpacity: false
            )
            Toggle(
                localized("漸層背景"),
                isOn: Binding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.backgroundGradient != nil },
                    set: { enabled in
                        mutateStyle(layer) { style in
                            style.ruleStyle.decoration.backgroundGradient = enabled
                                ? ReaderStyleGradient(
                                    angleDegrees: 90,
                                    stops: [
                                        ReaderStyleGradientStop(colorHex: defaultBackgroundHex, location: 0),
                                        ReaderStyleGradientStop(colorHex: defaultTextHex, location: 1),
                                    ]
                                )
                                : nil
                        }
                    }
                )
            )
            if let gradient = decoration.backgroundGradient {
                metricSlider(
                    localized("漸層角度"),
                    value: doubleBinding(
                        get: {
                            appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.backgroundGradient?.angleDegrees
                                ?? gradient.angleDegrees
                        },
                        set: { value in
                            mutateStyle(layer) { $0.ruleStyle.decoration.backgroundGradient?.angleDegrees = value }
                        }
                    ),
                    range: 0...360,
                    step: 1,
                    unit: "°"
                )
                ForEach(gradient.stops.indices, id: \.self) { index in
                    ColorPicker(
                        String(format: localized("漸層顏色 %d"), index + 1),
                        selection: colorBinding(hex: gradient.stops[index].colorHex) { hex in
                            mutateStyle(layer) { style in
                                guard style.ruleStyle.decoration.backgroundGradient?.stops.indices.contains(index) == true else { return }
                                style.ruleStyle.decoration.backgroundGradient?.stops[index].colorHex = hex
                            }
                        },
                        supportsOpacity: false
                    )
                }
            }
            metricSlider(
                localized("透明度"),
                value: doubleBinding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.opacity ?? 1 },
                    set: { value in mutateStyle(layer) { $0.ruleStyle.decoration.opacity = value } }
                ),
                range: 0...1,
                step: 0.05,
                unit: "%",
                displayMultiplier: 100
            )
            Button { showingAssetLibrary = true } label: {
                Label(localized("選擇背景圖片"), systemImage: "photo.on.rectangle")
            }
            if decoration.backgroundImage != nil {
                imagePresentationControls(layer, presentation: decoration.backgroundImage!)
                Button(role: .destructive) {
                    mutateStyle(layer) { $0.ruleStyle.decoration.backgroundImage = nil }
                } label: {
                    Label(localized("移除背景圖"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func imagePresentationControls(
        _ layer: ChapterTitleLayer,
        presentation: ReaderStyleImagePresentation
    ) -> some View {
        Picker(
            localized("圖片填充方式"),
            selection: Binding(
                get: {
                    appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.backgroundImage?.contentMode
                        ?? presentation.contentMode
                },
                set: { value in
                    mutateStyle(layer) { $0.ruleStyle.decoration.backgroundImage?.contentMode = value }
                }
            )
        ) {
            ForEach(ReaderStyleImageContentMode.allCases, id: \.self) { mode in
                Text(localized(mode.titleKey)).tag(mode)
            }
        }
        metricSlider(
            localized("圖片焦點 X"),
            value: imagePresentationBinding(layer, keyPath: \.focalX, fallback: presentation.focalX),
            range: 0...1,
            step: 0.05,
            unit: "%",
            displayMultiplier: 100
        )
        metricSlider(
            localized("圖片焦點 Y"),
            value: imagePresentationBinding(layer, keyPath: \.focalY, fallback: presentation.focalY),
            range: 0...1,
            step: 0.05,
            unit: "%",
            displayMultiplier: 100
        )
        metricSlider(
            localized("圖片透明度"),
            value: imagePresentationBinding(layer, keyPath: \.opacity, fallback: presentation.opacity),
            range: 0...1,
            step: 0.05,
            unit: "%",
            displayMultiplier: 100
        )
    }

    private func spacingSection(_ layer: ChapterTitleLayer) -> some View {
        Section(localized("邊距")) {
            ForEach(ReaderStyleEdge.allCases, id: \.rawValue) { edge in
                metricSlider(
                    String(format: localized("%@內距"), localized(edge.titleKey)),
                    value: edgeBinding(layer, edge: edge),
                    range: 0...48,
                    step: 1,
                    unit: "pt"
                )
            }
            metricSlider(
                localized("圓角"),
                value: doubleBinding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.cornerRadius ?? 0 },
                    set: { value in mutateStyle(layer) { $0.ruleStyle.decoration.cornerRadius = value } }
                ),
                range: 0...48,
                step: 1,
                unit: "pt"
            )
        }
    }

    private func borderSection(_ layer: ChapterTitleLayer) -> some View {
        let border = appearanceStyle(layer).ruleStyle.decoration.borders?[.top]
            ?? ReaderStyleBorder(width: 0, colorHex: 0x8E8E93)
        return Section(localized("邊框與陰影")) {
            metricSlider(
                localized("邊框粗細"),
                value: doubleBinding(
                    get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.borders?[.top]?.width ?? 0 },
                    set: { value in
                        mutateStyle(layer) { style in
                            let updated = ReaderStyleBorder(width: value, colorHex: border.colorHex)
                            style.ruleStyle.decoration.borders = Dictionary(
                                uniqueKeysWithValues: ReaderStyleEdge.allCases.map { ($0, updated) }
                            )
                        }
                    }
                ),
                range: 0...12,
                step: 0.5,
                unit: "pt"
            )
            ColorPicker(
                localized("邊框顏色"),
                selection: colorBinding(hex: border.colorHex) { hex in
                    mutateStyle(layer) { style in
                        let width = style.ruleStyle.decoration.borders?[.top]?.width ?? 1
                        let updated = ReaderStyleBorder(width: width, colorHex: hex)
                        style.ruleStyle.decoration.borders = Dictionary(
                            uniqueKeysWithValues: ReaderStyleEdge.allCases.map { ($0, updated) }
                        )
                    }
                },
                supportsOpacity: false
            )
            Button {
                mutateStyle(layer) { style in
                    style.ruleStyle.decoration.shadows.append(
                        ReaderStyleShadow(colorHex: 0, radius: 4, x: 0, y: 2)
                    )
                }
            } label: {
                Label(localized("新增陰影"), systemImage: "plus")
            }
            ForEach(Array(appearanceStyle(layer).ruleStyle.decoration.shadows.enumerated()), id: \.offset) { index, shadow in
                DisclosureGroup(String(format: localized("陰影 %d"), index + 1)) {
                    ColorPicker(
                        localized("陰影顏色"),
                        selection: colorBinding(hex: shadow.colorHex) { hex in
                            mutateShadow(layer, index: index) { $0.colorHex = hex }
                        },
                        supportsOpacity: false
                    )
                    metricSlider(
                        localized("模糊"),
                        value: shadowBinding(layer, index: index, keyPath: \.radius, fallback: shadow.radius),
                        range: 0...48,
                        step: 1,
                        unit: "pt"
                    )
                    metricSlider(
                        localized("水平位移"),
                        value: shadowBinding(layer, index: index, keyPath: \.x, fallback: shadow.x),
                        range: -48...48,
                        step: 1,
                        unit: "pt"
                    )
                    metricSlider(
                        localized("垂直位移"),
                        value: shadowBinding(layer, index: index, keyPath: \.y, fallback: shadow.y),
                        range: -48...48,
                        step: 1,
                        unit: "pt"
                    )
                    Button(role: .destructive) {
                        mutateStyle(layer) { style in
                            guard style.ruleStyle.decoration.shadows.indices.contains(index) else { return }
                            style.ruleStyle.decoration.shadows.remove(at: index)
                        }
                    } label: {
                        Label(String(format: localized("刪除陰影 %d"), index + 1), systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contrastSection(_ layer: ChapterTitleLayer) -> some View {
        let style = appearanceStyle(layer).ruleStyle
        if let foreground = style.text.colorHex,
           let background = style.decoration.backgroundColorHex,
           let warning = ReaderStyleContrastEvaluator.warning(
               foregroundHex: foreground,
               backgroundHex: background
           ), !contrastAcknowledged {
            Section {
                Label(
                    String(format: localized("文字與背景對比度為 %.1f:1。"), warning.ratio),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(DSColor.warning)
                Button(localized("仍要套用")) { contrastAcknowledged = true }
            }
        }
    }

    private func appearanceStyle(_ layer: ChapterTitleLayer) -> ChapterTitleLayerStyle {
        model.activeAppearance == .light ? layer.lightStyle : layer.darkStyle
    }

    private func mutateStyle(_ layer: ChapterTitleLayer, _ mutation: (inout ChapterTitleLayerStyle) -> Void) {
        guard let current = selectedLayer else { return }
        var style = appearanceStyle(current)
        mutation(&style)
        model.updateStyle(id: layer.id, appearance: model.activeAppearance, style: style)
        contrastAcknowledged = false
    }

    private func optionalBoolBinding(
        _ layer: ChapterTitleLayer,
        keyPath: WritableKeyPath<ReaderStyleTextStyle, Bool?>
    ) -> Binding<Bool> {
        Binding(
            get: { appearanceStyle(selectedLayer ?? layer).ruleStyle.text[keyPath: keyPath] ?? false },
            set: { value in mutateStyle(layer) { $0.ruleStyle.text[keyPath: keyPath] = value } }
        )
    }

    private func edgeBinding(_ layer: ChapterTitleLayer, edge: ReaderStyleEdge) -> Binding<Double> {
        doubleBinding(
            get: {
                let edges = appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.padding ?? .init()
                return edges.value(for: edge)
            },
            set: { value in
                mutateStyle(layer) { style in
                    var edges = style.ruleStyle.decoration.padding ?? .init()
                    edges.set(value, for: edge)
                    style.ruleStyle.decoration.padding = edges
                }
            }
        )
    }

    private func imagePresentationBinding(
        _ layer: ChapterTitleLayer,
        keyPath: WritableKeyPath<ReaderStyleImagePresentation, Double>,
        fallback: Double
    ) -> Binding<Double> {
        doubleBinding(
            get: {
                appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.backgroundImage?[keyPath: keyPath]
                    ?? fallback
            },
            set: { value in
                mutateStyle(layer) { style in
                    style.ruleStyle.decoration.backgroundImage?[keyPath: keyPath] = value
                }
            }
        )
    }

    private func contentImageBinding<Value>(
        _ layer: ChapterTitleLayer,
        assetID: UUID,
        keyPath: WritableKeyPath<ReaderStyleImagePresentation, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                appearanceStyle(selectedLayer ?? layer).imagePresentation?[keyPath: keyPath]
                    ?? fallback
            },
            set: { value in
                mutateStyle(layer) { style in
                    var presentation = style.imagePresentation
                        ?? ReaderStyleImagePresentation(assetID: assetID, contentMode: .fit)
                    presentation.assetID = assetID
                    presentation[keyPath: keyPath] = value
                    style.imagePresentation = presentation
                }
            }
        )
    }

    private func shadowBinding(
        _ layer: ChapterTitleLayer,
        index: Int,
        keyPath: WritableKeyPath<ReaderStyleShadow, Double>,
        fallback: Double
    ) -> Binding<Double> {
        doubleBinding(
            get: {
                let shadows = appearanceStyle(selectedLayer ?? layer).ruleStyle.decoration.shadows
                return shadows.indices.contains(index) ? shadows[index][keyPath: keyPath] : fallback
            },
            set: { value in mutateShadow(layer, index: index) { $0[keyPath: keyPath] = value } }
        )
    }

    private func mutateShadow(
        _ layer: ChapterTitleLayer,
        index: Int,
        _ mutation: (inout ReaderStyleShadow) -> Void
    ) {
        mutateStyle(layer) { style in
            guard style.ruleStyle.decoration.shadows.indices.contains(index) else { return }
            mutation(&style.ruleStyle.decoration.shadows[index])
        }
    }

    @ViewBuilder
    private func metricSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        displayMultiplier: Double = 1
    ) -> some View {
        let formatted = String(format: "%.0f %@", value.wrappedValue * displayMultiplier, unit)
        LabeledContent(title, value: formatted)
        Slider(value: value, in: range, step: step)
            .accessibilityLabel(title)
            .accessibilityValue(formatted)
    }

    private func doubleBinding(get: @escaping () -> Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: set)
    }

    private func colorBinding(hex: UInt32, update: @escaping (UInt32) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(readerStyleHex: hex)) },
            set: { color in update(color.rgbHex ?? hex) }
        )
    }

    private func assignBackground(_ asset: ReaderStyleAsset) {
        guard let layer = selectedLayer else { return }
        if layer.kind == .image {
            model.updateContent(id: layer.id, content: .image(asset.id))
            return
        }
        mutateStyle(layer) {
            $0.ruleStyle.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: asset.id)
        }
    }

    private var assetReferences: [UUID: [ReaderStyleAssetReference]] {
        var result: [UUID: [ReaderStyleAssetReference]] = [:]
        for layer in model.draft.layers {
            let reference = ReaderStyleAssetReference.chapterLayer(layer.name)
            var ids: [UUID] = []
            if case let .image(id) = layer.content { ids.append(id) }
            for style in [layer.lightStyle, layer.darkStyle] {
                if let id = style.imagePresentation?.assetID { ids.append(id) }
                if let id = style.ruleStyle.decoration.backgroundImage?.assetID { ids.append(id) }
            }
            for id in Set(ids) { result[id, default: []].append(reference) }
        }
        return result
    }

    private var defaultTextHex: UInt32 { model.activeAppearance == .light ? 0x1C1C1E : 0xF2F2F7 }
    private var defaultBackgroundHex: UInt32 { model.activeAppearance == .light ? 0xFFFFFF : 0x1C1C1E }

    private func fontDisplayName(_ postScriptName: String?) -> String {
        guard let postScriptName else { return localized("跟隨閱讀字體") }
        return settings.userFonts.first(where: { $0.postScriptName == postScriptName })?.displayName
            ?? postScriptName
    }
}

private extension ReaderStyleImageContentMode {
    var titleKey: String {
        switch self {
        case .fill: "填滿"
        case .fit: "適應"
        case .tile: "平鋪"
        case .stretch: "拉伸"
        }
    }
}

private extension ReaderStyleEdge {
    var titleKey: String {
        switch self {
        case .top: "上"
        case .leading: "左"
        case .bottom: "下"
        case .trailing: "右"
        }
    }
}

private extension ReaderStyleEdges {
    func value(for edge: ReaderStyleEdge) -> Double {
        switch edge {
        case .top: top
        case .leading: leading
        case .bottom: bottom
        case .trailing: trailing
        }
    }

    mutating func set(_ value: Double, for edge: ReaderStyleEdge) {
        switch edge {
        case .top: top = value
        case .leading: leading = value
        case .bottom: bottom = value
        case .trailing: trailing = value
        }
    }
}

private extension Color {
    var rgbHex: UInt32? {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return nil }
        return UInt32((red * 255).rounded()) << 16
            | UInt32((green * 255).rounded()) << 8
            | UInt32((blue * 255).rounded())
    }
}

#Preview {
    ChapterTitleInspectorView(
        model: ChapterTitleDesignerModel(initial: .default, onSave: { _ in })
    )
}
