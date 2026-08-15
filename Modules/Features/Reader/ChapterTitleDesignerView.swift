import SwiftUI

enum ChapterTitleDesignerLayout: Equatable, Sendable {
    case tabbed
    case split
}

enum ChapterTitleDesignerLayoutPolicy {
    static func resolve(
        width: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> ChapterTitleDesignerLayout {
        horizontalSizeClass == .regular ? .split : .tabbed
    }
}

enum ChapterTitleLayerAccessibleAction: CaseIterable, Hashable, Sendable {
    case nudgeUp, nudgeDown, nudgeLeading, nudgeTrailing
    case grow, shrink, rotateClockwise, rotateCounterclockwise
    case moveForward, moveBackward, edit, duplicate, delete
}

private enum ChapterTitleDesignerTab: Hashable {
    case preview
    case elements
    case style
    case resources
    case source
}

struct ChapterTitleDesignerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model: ChapterTitleDesignerModel
    @State private var activeTab: ChapterTitleDesignerTab = .preview
    @State private var detailTab: ChapterTitleDesignerTab = .style
    @State private var lightSource: String
    @State private var darkSource: String

    init(
        initial: ChapterTitleDesign,
        onSave: @escaping (ChapterTitleDesign) throws -> Void
    ) {
        _model = StateObject(wrappedValue: ChapterTitleDesignerModel(initial: initial, onSave: onSave))
        _lightSource = State(initialValue: ChapterTitleHTMLCodec.encode(initial, appearance: .light))
        _darkSource = State(initialValue: ChapterTitleHTMLCodec.encode(initial, appearance: .dark))
    }

    var body: some View {
        Group {
            switch ChapterTitleDesignerLayoutPolicy.resolve(
                width: .zero,
                horizontalSizeClass: horizontalSizeClass
            ) {
            case .tabbed:
                NavigationStack {
                    designerChrome(compactTabs)
                }
            case .split:
                regularSplit
            }
        }
        .onChange(of: model.draft) { _, design in
            guard !isSourceEditorVisible else { return }
            lightSource = ChapterTitleHTMLCodec.encode(design, appearance: .light)
            darkSource = ChapterTitleHTMLCodec.encode(design, appearance: .dark)
        }
    }

    private var compactTabs: some View {
        TabView(selection: $activeTab) {
            ChapterTitleDesignerCanvas(model: model)
                .tabItem { Label(localized("預覽"), systemImage: "rectangle.on.rectangle") }
                .tag(ChapterTitleDesignerTab.preview)

            ChapterTitleLayerListView(model: model)
                .tabItem { Label(localized("元素"), systemImage: "square.grid.2x2") }
                .tag(ChapterTitleDesignerTab.elements)

            ChapterTitleInspectorView(model: model)
                .tabItem { Label(localized("樣式"), systemImage: "paintpalette") }
                .tag(ChapterTitleDesignerTab.style)

            assetLibrary
                .tabItem { Label(localized("資源"), systemImage: "photo.on.rectangle") }
                .tag(ChapterTitleDesignerTab.resources)

            sourceEditor
                .tabItem { Label(localized("源碼"), systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(ChapterTitleDesignerTab.source)
        }
    }

    private var regularSplit: some View {
        NavigationSplitView {
            ChapterTitleLayerListView(model: model)
                .navigationTitle(localized("元素"))
                .toolbarTitleDisplayMode(.inline)
        } content: {
            ChapterTitleDesignerCanvas(model: model)
                .navigationTitle(localized("預覽"))
                .toolbarTitleDisplayMode(.inline)
        } detail: {
            // The chrome must live *inside* the detail column, not on the
            // NavigationSplitView: `.toolbar` applied to the split view itself
            // never reaches a navigation bar, which silently dropped the
            // cancel/undo/redo/apply buttons on iPad and left the full-screen
            // designer with no way out.
            designerChrome(detailTabs)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var detailTabs: some View {
        TabView(selection: $detailTab) {
            ChapterTitleInspectorView(model: model)
                .tabItem { Label(localized("樣式"), systemImage: "paintpalette") }
                .tag(ChapterTitleDesignerTab.style)

            assetLibrary
                .tabItem { Label(localized("資源"), systemImage: "photo.on.rectangle") }
                .tag(ChapterTitleDesignerTab.resources)

            sourceEditor
                .tabItem { Label(localized("源碼"), systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(ChapterTitleDesignerTab.source)
        }
    }

    private var assetLibrary: some View {
        ReaderStyleAssetLibraryView(
            referenceScope: "chapter-title-designer",
            references: assetReferences,
            onSelect: { asset in assign(asset: asset) },
            onDeleteReferencedAsset: { id in
                guard await model.deleteAsset(id: id, store: .shared) else {
                    throw model.validationError ?? ReaderStyleAssetStoreError.writeFailed
                }
            }
        )
    }

    /// Title bar + cancel/undo/redo/apply. Apply this to the root content of a
    /// navigation container (the `NavigationStack` body, or the split view's
    /// detail column) — never to the container itself.
    private func designerChrome<Content: View>(_ content: Content) -> some View {
        content
            .background(DSColor.background)
            .navigationTitle(localized("章節標題設計器"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(localized("取消"))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .accessibilityHidden(true)
                    }
                    .disabled(!model.canUndo)
                    .accessibilityLabel(localized("復原"))

                    Button { model.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .accessibilityHidden(true)
                    }
                    .disabled(!model.canRedo)
                    .accessibilityLabel(localized("重做"))

                    Button {
                        if model.done() { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                    .disabled(!model.hasChanges || model.isFinished)
                    .accessibilityLabel(localized("套用"))
                }
            }
    }

    private var sourceEditor: some View {
        Form {
            Picker(localized("預覽"), selection: $model.activeAppearance) {
                Text(localized("亮色模式")).tag(ReaderStyleAppearance.light)
                Text(localized("深色模式")).tag(ReaderStyleAppearance.dark)
            }
            .pickerStyle(.segmented)
            Section(localized("源碼")) {
                TextEditor(text: model.activeAppearance == .light ? $lightSource : $darkSource)
                    .font(DSFont.monospaced())
                    .frame(minHeight: DSLayout.readableNarrowWidth / 2)
                    .accessibilityLabel(localized("章節標題源碼"))
                Menu {
                    insertionButton("{number}", label: localized("插入章節數"))
                    insertionButton("{name}", label: localized("插入章節名"))
                    insertionButton("{title}", label: localized("插入原始標題"))
                    insertionButton("font-family: chapter-number;", label: localized("插入章節數字體"))
                    insertionButton("font-family: chapter-name;", label: localized("插入章節名字體"))
                } label: {
                    Label(localized("插入"), systemImage: "plus.circle")
                }
                Button {
                    _ = model.applySource(light: lightSource, dark: darkSource)
                } label: {
                    Label(localized("套用源碼"), systemImage: "checkmark.circle")
                }
            }
            .interfaceSectionSurface()
            if let error = model.validationError {
                Section {
                    Label(sourceErrorText(error), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DSColor.warning)
                        .accessibilityElement(children: .combine)
                }
                .interfaceSectionSurface()
            }
        }
    }

    private func insertionButton(_ token: String, label: String) -> some View {
        Button(label) {
            if model.activeAppearance == .light {
                lightSource.append(token)
            } else {
                darkSource.append(token)
            }
        }
    }

    private var assetReferences: [UUID: [ReaderStyleAssetReference]] {
        var result: [UUID: [ReaderStyleAssetReference]] = [:]
        for layer in model.draft.layers {
            let reference = ReaderStyleAssetReference.chapterLayer(layer.name)
            for id in ReaderStyleAssetReferences.assetIDs(in: layer) {
                result[id, default: []].append(reference)
            }
        }
        return result
    }

    private func assign(asset: ReaderStyleAsset) {
        guard let id = model.selectedLayerID,
              let layer = model.draft.layers.first(where: { $0.id == id }) else { return }
        if layer.kind == .image {
            model.updateContent(id: id, content: .image(asset.id))
        } else {
            var style = model.activeAppearance == .light ? layer.lightStyle : layer.darkStyle
            style.ruleStyle.decoration.backgroundImage = ReaderStyleImagePresentation(assetID: asset.id)
            model.updateStyle(id: id, appearance: model.activeAppearance, style: style)
        }
        activeTab = .style
        detailTab = .style
    }

    private var isSourceEditorVisible: Bool {
        ChapterTitleDesignerLayoutPolicy.resolve(
            width: .zero,
            horizontalSizeClass: horizontalSizeClass
        ) == .tabbed ? activeTab == .source : detailTab == .source
    }

    private func sourceErrorText(_ error: Error) -> String {
        switch error {
        case let error as ChapterTitleHTMLCodecError:
            return String(format: localized("源碼錯誤：%@"), String(describing: error))
        default:
            return error.localizedDescription
        }
    }
}

#Preview {
    ChapterTitleDesignerView(initial: .default, onSave: { _ in })
}
