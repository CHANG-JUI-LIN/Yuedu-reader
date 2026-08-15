import Combine
import CoreText
import SwiftUI
import UIKit

/// "章節標題樣式" — the sub-page reached from reader settings. Two modes:
///
/// - 高級 CSS 樣式 ON: preset picker (all built-ins are HTML/CSS templates),
///   "my presets", a live preview rendered through the real CoreText pipeline
///   (so borders/dividers/ornaments look exactly like the reader), and the
///   shared layout sliders (title size anchors the template's 1em).
/// - OFF: the manual typographic controls (visibility/size/spacing/alignment/
///   weight/split/fonts), same live preview.
///
/// Spacing (上方間距/與正文間距) is one shared set — light/dark differ only in
/// template colors, per user decision 2026-07-22.
struct ChapterTitleStyleSettingsView: View {
    /// Opens the style importer. Non-nil only where a first-level presenter can
    /// own the document picker — see `Technotes/iOS17MenuModalPresentation.md`.
    var onOpenImporter: (() -> Void)?

    @ObservedObject private var settings = GlobalSettings.shared
    @StateObject private var readerConfig = ReaderConfig.shared

    @State private var previewIsDark = false
    @State private var showingDesigner = false
    @State private var designerDraft = ChapterTitleDesign.default
    @State private var savePresetName = ""
    @State private var showingSavePresetDialog = false
    @State private var presetPendingDeletion: ChapterTitleStylePreset?
    @State private var importAlert: TitleStyleAlert?

    private var style: ChapterTitleStyle { readerConfig.chapterTitleStyle }

    var body: some View {
        Form {
            advancedCSSSection
            if style.advancedCSSEnabled {
                presetSection
                myPresetSection
                previewSection
                cssLayoutSection
            } else {
                previewSection
                layoutSection
                fontSection
            }
            actionSection
        }
        .navigationTitle(localized("章節標題樣式"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onDisappear {
            // ReaderView observes the immutable render-settings snapshot and
            // submits the refresh after any title-style mutation.
        }
        .fullScreenCover(isPresented: $showingDesigner) {
            ChapterTitleDesignerView(initial: designerDraft) { design in
                updateStyle { $0.design = design }
            }
        }
        .alert(localized("樣式名稱"), isPresented: $showingSavePresetDialog) {
            TextField(localized("樣式名稱"), text: $savePresetName)
            Button(localized("取消"), role: .cancel) { savePresetName = "" }
            Button(localized("儲存")) { saveCurrentAsPreset() }
        } message: {
            Text(localized("為目前的章節標題樣式取一個名字。"))
        }
        .alert(
            localized("刪除這個預設？"),
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button(localized("刪除"), role: .destructive) { deletePreset(preset) }
            Button(localized("取消"), role: .cancel) {}
        } message: { preset in
            Text(String(format: localized("「%@」會被永久刪除，此操作無法復原。"), preset.name))
        }
        .alert(item: $importAlert) { alert in
            Alert(
                title: Text(localized(alert.titleKey)),
                message: Text(alert.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
    }

    // MARK: - Advanced CSS

    private var advancedCSSSection: some View {
        Section {
            Toggle(localized("高級 CSS 樣式"), isOn: binding(\ChapterTitleStyle.advancedCSSEnabled))
                .font(DSFont.body)
            if style.advancedCSSEnabled {
                Button(action: openDesigner) {
                    Label(localized("編輯設計"), systemImage: "slider.horizontal.3")
                }
            }
        } footer: {
            Text(localized("開啟後使用 HTML/CSS 模板渲染章節標題，支持自定義排版和樣式。"))
        }
        .interfaceSectionSurface()
    }

    // MARK: - Presets (advanced CSS only)

    private var presetSection: some View {
        Section {
            ForEach(ChapterTitleStylePreset.builtins) { preset in
                presetRow(preset)
            }
        } header: {
            Text(localized("選擇預設"))
        } footer: {
            Text(localized("自動適配淺色和深色。選好後可繼續微調。"))
        }
        .interfaceSectionSurface()
    }

    private var myPresetSection: some View {
        Section {
            if settings.chapterTitleCustomPresets.isEmpty {
                Text(localized("調好後點「存為我的預設」保存"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                ForEach(settings.chapterTitleCustomPresets) { preset in
                    presetRow(preset)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                presetPendingDeletion = preset
                            } label: {
                                Label(localized("刪除"), systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text(localized("我的預設"))
        }
        .interfaceSectionSurface()
    }

    private func presetRow(_ preset: ChapterTitleStylePreset) -> some View {
        let isSelected = style == preset.style
        let displayName = preset.isBuiltin ? localized(preset.name) : preset.name
        return Button {
            applyStyle(preset.style)
        } label: {
            Label(
                displayName,
                systemImage: isSelected ? "checkmark.circle.fill" : Self.presetIconName(for: preset)
            )
        }
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func presetIconName(for preset: ChapterTitleStylePreset) -> String {
        switch preset.id {
        case "builtin.css.centered": return "text.aligncenter"
        case "builtin.css.ink": return "paintbrush"
        case "builtin.css.quote": return "text.quote"
        case "builtin.css.divider": return "rectangle.split.1x2"
        case "builtin.css.right": return "text.alignright"
        case "builtin.css.diamond": return "diamond"
        default: return "bookmark"
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            Picker(localized("預覽"), selection: $previewIsDark) {
                Text(localized("淺色")).tag(false)
                Text(localized("深色")).tag(true)
            }
            .pickerStyle(.segmented)

            ChapterTitlePreviewCard(style: style, isDark: previewIsDark)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } header: {
            Text(localized("預覽"))
        } footer: {
            if style.advancedCSSEnabled {
                Text(localized("切換淺色／深色查看對應外觀的模板。"))
            }
        }
    }

    // MARK: - Layout (advanced CSS: shared spacing + em anchor)

    private var cssLayoutSection: some View {
        Section(header: Text(localized("佈局"))) {
            Toggle(localized("顯示標題"), isOn: binding(\ChapterTitleStyle.visible))
                .font(DSFont.body)
            sliderRow(localized("標題大小"), value: binding(\ChapterTitleStyle.size), range: ChapterTitleStyle.sizeRange, step: 1, unit: "pt")
            sliderRow(localized("上方間距"), value: binding(\ChapterTitleStyle.topSpacing), range: ChapterTitleStyle.topSpacingRange, step: 1, unit: "pt")
            sliderRow(localized("與正文間距"), value: binding(\ChapterTitleStyle.bottomSpacing), range: ChapterTitleStyle.bottomSpacingRange, step: 1, unit: "pt")
        }
        .interfaceSectionSurface()
    }

    // MARK: - Layout (manual mode)

    private var layoutSection: some View {
        Section(header: Text(localized("佈局"))) {
            Toggle(localized("顯示標題"), isOn: binding(\ChapterTitleStyle.visible))
                .font(DSFont.body)

            sliderRow(localized("標題大小"), value: binding(\ChapterTitleStyle.size), range: ChapterTitleStyle.sizeRange, step: 1, unit: "pt")
            sliderRow(localized("上方間距"), value: binding(\ChapterTitleStyle.topSpacing), range: ChapterTitleStyle.topSpacingRange, step: 1, unit: "pt")
            sliderRow(localized("與正文間距"), value: binding(\ChapterTitleStyle.bottomSpacing), range: ChapterTitleStyle.bottomSpacingRange, step: 1, unit: "pt")

            Picker(localized("對齊"), selection: binding(\ChapterTitleStyle.alignment)) {
                ForEach(ChapterTitleAlignment.allCases, id: \.self) { align in
                    Image(systemName: align.systemImageName)
                        .accessibilityLabel(localized(align.localizedNameKey))
                        .tag(align)
                }
            }
            .pickerStyle(.segmented)

            Picker(localized("字重"), selection: binding(\ChapterTitleStyle.weight)) {
                ForEach(ChapterTitleWeight.allCases, id: \.self) { weight in
                    Text(localized(weight.localizedNameKey)).tag(weight)
                }
            }

            Toggle(localized("拆分章節數與章節名"), isOn: binding(\ChapterTitleStyle.splitEnabled))
                .font(DSFont.body)

            if style.splitEnabled {
                sliderRow(
                    localized("章節數字號比例"),
                    value: binding(\ChapterTitleStyle.numberRelativeSize),
                    range: ChapterTitleStyle.numberRelativeSizeRange,
                    step: 0.05,
                    unit: "×",
                    format: "%.2f"
                )
            }
        }
        .interfaceSectionSurface()
    }

    // MARK: - Fonts (manual mode)

    private var fontSection: some View {
        Section(header: Text(localized("字體"))) {
            Toggle(localized("跟隨閱讀字體"), isOn: binding(\ChapterTitleStyle.followsBodyFont))
                .font(DSFont.body)

            if !style.followsBodyFont {
                fontMenu(localized("章節數字體"), current: style.numberFontPostScript) { name in
                    updateStyle { $0.numberFontPostScript = name }
                }
                fontMenu(localized("章節名字體"), current: style.nameFontPostScript) { name in
                    updateStyle { $0.nameFontPostScript = name }
                }
            }
        }
        .interfaceSectionSurface()
    }

    private func fontMenu(_ title: String, current: String?, onSelect: @escaping (String?) -> Void) -> some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                Label(localized("跟隨閱讀字體"), systemImage: current == nil ? "checkmark" : "textformat")
            }
            ForEach(settings.userFonts, id: \.postScriptName) { font in
                Button {
                    onSelect(font.postScriptName)
                } label: {
                    Label(font.displayName, systemImage: current == font.postScriptName ? "checkmark" : "textformat")
                }
            }
        } label: {
            LabeledContent(title, value: fontDisplayName(current))
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section(header: Text(localized("操作"))) {
            Button {
                savePresetName = ""
                showingSavePresetDialog = true
            } label: {
                Label(localized("存為我的預設"), systemImage: "square.and.arrow.down")
            }
            ShareLink(
                item: exportPayload,
                preview: SharePreview(localized("章節標題樣式"))
            ) {
                Label(localized("匯出樣式檔案"), systemImage: "square.and.arrow.up")
            }
            if let onOpenImporter {
                Button {
                    onOpenImporter()
                } label: {
                    Label(localized("從檔案匯入樣式"), systemImage: "tray.and.arrow.down")
                }
            }
            Button(role: .destructive) {
                applyStyle(.default)
            } label: {
                Label(localized("恢復官方預設"), systemImage: "arrow.counterclockwise")
            }
        }
        .interfaceSectionSurface()
    }

    // MARK: - Bindings & mutation

    private func binding<Value>(_ keyPath: WritableKeyPath<ChapterTitleStyle, Value>) -> Binding<Value> {
        Binding(
            get: { readerConfig.chapterTitleStyle[keyPath: keyPath] },
            set: { newValue in updateStyle { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func updateStyle(_ mutate: (inout ChapterTitleStyle) -> Void) {
        var copy = readerConfig.chapterTitleStyle
        mutate(&copy)
        readerConfig.chapterTitleStyle = copy.sanitized()
    }

    private func applyStyle(_ newStyle: ChapterTitleStyle) {
        readerConfig.chapterTitleStyle = newStyle.sanitized()
    }

    private func saveCurrentAsPreset() {
        let trimmed = savePresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? localized("我的樣式") : trimmed
        settings.upsertChapterTitleCustomPreset(
            ChapterTitleStylePreset(name: name, style: style)
        )
        savePresetName = ""
    }

    private func deletePreset(_ preset: ChapterTitleStylePreset) {
        settings.deleteChapterTitleCustomPreset(id: preset.id)
        presetPendingDeletion = nil
    }

    // MARK: - Export

    /// The archive itself is built inside the share transfer, so this stays a
    /// cheap value read even though menu/list content is rebuilt on every layout.
    private var exportPayload: ChapterTitleStyleExportPayload {
        ChapterTitleStyleExportPayload(style: style)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sliderRow(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        unit: String,
        format: String = "%.0f"
    ) -> some View {
        let formatted = "\(String(format: format, value.wrappedValue)) \(unit)"
        LabeledContent(title, value: formatted)
        Slider(value: value, in: range, step: step)
            .disabled(!style.visible)
            .accessibilityLabel(title)
            .accessibilityValue(formatted)
    }

    private func fontDisplayName(_ postScript: String?) -> String {
        guard let postScript,
              let font = settings.userFonts.first(where: { $0.postScriptName == postScript })
        else { return localized("跟隨閱讀字體") }
        return font.displayName
    }

    private func openDesigner() {
        do {
            designerDraft = try ChapterTitleDesignerEntryDesign.resolve(style)
            showingDesigner = true
        } catch {
            importAlert = TitleStyleAlert(
                titleKey: "操作失敗",
                message: String(describing: error)
            )
        }
    }

}

enum ChapterTitleDesignerEntryDesign {
    static func resolve(_ style: ChapterTitleStyle) throws -> ChapterTitleDesign {
        if let design = style.design {
            guard design.layers.isEmpty, let legacySource = design.legacySource else {
                return design
            }
            return try ChapterTitleHTMLCodec.migrateLegacySource(legacySource)
        }

        return try ChapterTitleHTMLCodec.migrateLegacySource(
            ChapterTitleLegacySource(
                light: style.lightTemplate,
                dark: style.darkTemplate
            )
        )
    }
}

// MARK: - Live preview (real CoreText pipeline)

/// Renders the sample title through `ChapterTitleAttributedBuilder` (the exact
/// path the reader uses — plain or CSS-template depending on the style), then
/// draws it with the same two-phase CoreText drawing as the scroll reader:
/// block decorations (borders/backgrounds) in UIKit coordinates, text via
/// `CoreTextHorizontalLineDrawer`. This is why 豎線/分隔線/裝飾 show up exactly
/// as they will on the page — SwiftUI Text or UILabel cannot draw them.
private struct ChapterTitlePreviewCard: View {
    let style: ChapterTitleStyle
    let isDark: Bool

    @State private var rendered: NSAttributedString?

    /// Sample stays CJK regardless of UI language: the number/name splitter
    /// only recognises 第X章-style prefixes, so a translated sample would
    /// demo a degraded single-line layout.
    private static let sampleTitle = "第一章 初入江湖"

    private struct RenderKey: Equatable {
        let style: ChapterTitleStyle
        let isDark: Bool
    }

    var body: some View {
        Group {
            if let rendered, rendered.length > 0 {
                ChapterTitleCoreTextPreview(attributed: rendered)
            } else if rendered != nil {
                // Built but empty: the title is hidden by the style.
                Text(localized("標題已隱藏"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .padding(.vertical, DSSpacing.xl)
            } else {
                ProgressView()
                    .padding(.vertical, DSSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.xl)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .padding(.vertical, DSSpacing.sm)
        .task(id: RenderKey(style: style, isDark: isDark)) {
            await render()
        }
    }

    private var cardBackground: Color {
        isDark ? Color(uiColor: UIColor(white: 0.11, alpha: 1)) : Color(uiColor: .white)
    }

    private func render() async {
        let textColor: UIColor = isDark ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.11, alpha: 1)
        let backgroundColor: UIColor = isDark ? UIColor(white: 0.11, alpha: 1) : .white
        // The card previews the title block itself, vertically centered with
        // symmetric padding. 上方間距/與正文間距 are page-flow whitespace (and
        // asymmetric), so they are zeroed here — their effect belongs to the
        // reading page, not this card.
        var previewStyle = style
        previewStyle.topSpacing = 0
        previewStyle.bottomSpacing = 0
        // Only theme colors and the title style matter to the builder; the rest
        // is a neutral stand-in. renderWidth is nominal — none of the built-in
        // templates use %-widths, and alignment re-centers at the actual width.
        let renderSettings = ReaderRenderSettings(
            theme: "title-preview",
            textColor: textColor,
            backgroundColor: backgroundColor,
            fontSize: 17,
            lineHeightMultiple: 1.2,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            chapterTitleStyle: previewStyle
        )
        let attr = NSMutableAttributedString()
        await ChapterTitleAttributedBuilder.append(
            title: Self.sampleTitle,
            style: previewStyle,
            settings: renderSettings,
            renderWidth: 320,
            themeTextColor: textColor,
            themeBackgroundColor: backgroundColor,
            letterSpacing: 0,
            to: attr
        )
        rendered = attr
    }
}

private struct ChapterTitleCoreTextPreview: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeUIView(context: Context) -> ChapterTitlePreviewDrawView {
        ChapterTitlePreviewDrawView()
    }

    func updateUIView(_ view: ChapterTitlePreviewDrawView, context: Context) {
        view.attributed = attributed
    }
}

/// Lays out the attributed title in a single CTFrame sized to fit, extracts the
/// block decorations with `CoreTextChunkSlicer.extractBlockRenderables`, and
/// draws both phases exactly like `CoreTextChunkDrawView`.
private final class ChapterTitlePreviewDrawView: UIView {
    var attributed: NSAttributedString = NSAttributedString() {
        didSet { rebuild() }
    }

    private var frameRef: CTFrame?
    private var renderables: [CoreTextPaginator.RenderedBlockRenderable] = []
    private var suppressedRanges: [NSRange] = []
    private var layoutWidth: CGFloat = 0
    private var layoutHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layoutHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - layoutWidth) > 0.5 {
            rebuild()
        }
    }

    private func rebuild() {
        let width = bounds.width
        layoutWidth = width
        guard width > 1, attributed.length > 0 else {
            frameRef = nil
            renderables = []
            suppressedRanges = []
            layoutHeight = 0
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
            return
        }
        let fullRange = CFRange(location: 0, length: attributed.length)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            fullRange,
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        size.height = ceil(size.height) + 2
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: size.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil)
        frameRef = frame
        renderables = CoreTextChunkSlicer.extractBlockRenderables(
            frame: frame,
            chunkSize: CGSize(width: width, height: size.height),
            attributedString: attributed,
            charRange: fullRange
        )
        suppressedRanges = renderables.flatMap { $0.attributedText != nil ? $0.sourceRanges : [] }
        layoutHeight = size.height
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let frameRef, let ctx = UIGraphicsGetCurrentContext() else { return }

        // Phase 1: block decorations (backgrounds, borders) in UIKit coordinates.
        CoreTextPageView.drawBlockRenderables(
            renderables,
            in: ctx,
            boundsHeight: bounds.height
        )

        // Phase 2: text, flipped to CoreText coordinates.
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        CoreTextHorizontalLineDrawer.drawLines(
            of: frameRef,
            contentWidth: bounds.width,
            contentMinX: 0,
            contentMinY: 0,
            isLastPage: true,
            attrStr: attributed,
            suppressedRanges: suppressedRanges,
            hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
            in: ctx
        )
        ctx.restoreGState()
    }
}

private struct TitleStyleAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

#Preview {
    NavigationStack {
        ChapterTitleStyleSettingsView()
    }
}
