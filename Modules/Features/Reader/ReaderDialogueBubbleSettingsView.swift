import SwiftUI
import UIKit

/// 對話氣泡 — the block-level dialogue treatment, and the screen that configures
/// it.
///
/// Sits beside 正則高亮 rather than inside it: the inline 對話 rules tint speech
/// where it stands, while this re-lays the paragraph as a chat bubble. Only one
/// of the two shows up on a given paragraph, which the footer says out loud.
struct ReaderDialogueBubbleSettingsView: View {
    @State private var style: ReaderDialogueBubbleStyle
    /// Which side is picking an avatar, if any.
    @State private var avatarPickerSide: ReaderDialogueBubbleSide?
    private let onChange: (ReaderDialogueBubbleStyle) -> Void
    /// Opens the bubble-script importer. Non-nil only where a first-level
    /// presenter can own the document picker — see
    /// `Technotes/iOS17MenuModalPresentation.md`.
    private let onOpenImporter: (() -> Void)?

    init(
        style: ReaderDialogueBubbleStyle,
        onOpenImporter: (() -> Void)? = nil,
        onChange: @escaping (ReaderDialogueBubbleStyle) -> Void
    ) {
        _style = State(initialValue: style)
        self.onOpenImporter = onOpenImporter
        self.onChange = onChange
    }

    var body: some View {
        List {
            enableSection
            if style.isEnabled {
                previewSection
                layoutSection
                sideSection(.right)
                sideSection(.left)
                actionsSection
            }
        }
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("對話氣泡"))
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: $avatarPickerSide) { side in
            NavigationStack {
                ReaderStyleAssetLibraryView(
                    referenceScope: "dialogue-bubble",
                    references: [:],
                    onSelect: { asset in
                        assignAvatar(asset.id, to: side)
                        avatarPickerSide = nil
                    },
                    onDeleteReferencedAsset: { _ in }
                )
            }
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(localized("啟用對話氣泡"), isOn: binding(\.isEnabled))
        } footer: {
            Text(localized("整段都是對話的段落會排成氣泡；夾在敘述裡的引號仍然沿用正則高亮。直排閱讀不套用。"))
        }
        .interfaceSectionSurface()
    }

    /// Drawn by the reader's own pipeline — the marker and the bubble painter —
    /// rather than by a SwiftUI lookalike. A preview that approximates the
    /// renderer drifts from it exactly where it matters (tails, skins, how the
    /// box hugs a short line), which is worse than no preview at all.
    private var previewSection: some View {
        Section(header: Text(localized("預覽"))) {
            DialogueBubblePreview(style: style)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.sm)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localized("對話氣泡預覽"))
        }
        .interfaceSectionSurface()
    }

    private var layoutSection: some View {
        Section(header: Text(localized("版面"))) {
            Picker(localized("第一句在"), selection: binding(\.startSide)) {
                Text(localized("靠右")).tag(ReaderDialogueBubbleSide.right)
                Text(localized("靠左")).tag(ReaderDialogueBubbleSide.left)
            }
            .pickerStyle(.segmented)

            Toggle(localized("左右交替"), isOn: binding(\.alternatesSides))

            slider(
                title: localized("最大寬度"),
                value: binding(\.maxWidthRatio),
                range: 0.3...1,
                step: 0.01,
                text: percent(style.maxWidthRatio)
            )
            slider(
                title: localized("邊距"),
                value: binding(\.sideInsetRatio),
                range: 0...0.3,
                step: 0.005,
                text: percent(style.sideInsetRatio)
            )
            slider(
                title: localized("左右內距"),
                value: binding(\.horizontalPaddingEm),
                range: 0...2,
                step: 0.02,
                text: em(style.horizontalPaddingEm)
            )
            slider(
                title: localized("上下內距"),
                value: binding(\.verticalPaddingEm),
                range: 0...2,
                step: 0.02,
                text: em(style.verticalPaddingEm)
            )
            slider(
                title: localized("氣泡間距"),
                value: binding(\.spacingEm),
                range: 0...2,
                step: 0.02,
                text: em(style.spacingEm)
            )

            Toggle(localized("隱藏引號"), isOn: binding(\.removesQuotes))
            Toggle(localized("顯示說話者"), isOn: binding(\.showsSpeakerName))
            Toggle(localized("同一人固定同一側"), isOn: binding(\.sidesFollowSpeaker))
            Toggle(localized("合併同段相鄰對話"), isOn: binding(\.mergesAdjacent))
        }
        .interfaceSectionSurface()
    }

    private func sideSection(_ side: ReaderDialogueBubbleSide) -> some View {
        let path: WritableKeyPath<ReaderDialogueBubbleStyle, ReaderDialogueBubbleSideStyle> =
            side == .left ? \.left : \.right
        let sideStyle = style.side(side)
        return Section(
            header: Text(side == .left ? localized("左側氣泡") : localized("右側氣泡"))
        ) {
            ColorPicker(
                localized("底色"),
                selection: colorBinding(hex: sideStyle.fillHex) {
                    $0[keyPath: path].fillHex = $1
                },
                supportsOpacity: false
            )
            ColorPicker(
                localized("文字顏色"),
                selection: colorBinding(hex: sideStyle.textHex ?? 0x1C1C1E) {
                    $0[keyPath: path].textHex = $1
                },
                supportsOpacity: false
            )
            ColorPicker(
                localized("邊框顏色"),
                selection: colorBinding(hex: sideStyle.borderHex ?? sideStyle.fillHex) {
                    $0[keyPath: path].borderHex = $1
                },
                supportsOpacity: false
            )
            slider(
                title: localized("圓角"),
                value: Binding(
                    get: { style[keyPath: path].cornerRadiusEm },
                    set: { value in update { $0[keyPath: path].cornerRadiusEm = value } }
                ),
                range: 0...2,
                step: 0.02,
                text: em(sideStyle.cornerRadiusEm)
            )
            slider(
                title: localized("邊框粗細"),
                value: Binding(
                    get: { style[keyPath: path].borderWidthEm },
                    set: { value in update { $0[keyPath: path].borderWidthEm = value } }
                ),
                range: 0...0.3,
                step: 0.005,
                text: em(sideStyle.borderWidthEm)
            )
            Toggle(
                localized("氣泡尾巴"),
                isOn: Binding(
                    get: { style[keyPath: path].tail != nil },
                    set: { isOn in
                        update { $0[keyPath: path].tail = isOn ? .default : nil }
                    }
                )
            )

            TextField(
                localized("找不到說話者時顯示"),
                text: Binding(
                    get: { sideStyle.name ?? "" },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        update { $0[keyPath: path].name = trimmed.isEmpty ? nil : trimmed }
                    }
                )
            )

            Picker(
                localized("氣泡裝飾"),
                selection: Binding<ReaderDialogueBubbleDecorationKind?>(
                    get: { sideStyle.decoration?.kind },
                    set: { kind in
                        update { style in
                            guard let kind else {
                                style[keyPath: path].decoration = nil
                                return
                            }
                            var decoration = style[keyPath: path].decoration
                                ?? ReaderDialogueBubbleDecoration()
                            decoration.kind = kind
                            style[keyPath: path].decoration = decoration
                        }
                    }
                )
            ) {
                Text(localized("無")).tag(ReaderDialogueBubbleDecorationKind?.none)
                ForEach(ReaderDialogueBubbleDecorationKind.allCases, id: \.self) { kind in
                    Text(localized(kind.localizedNameKey))
                        .tag(ReaderDialogueBubbleDecorationKind?.some(kind))
                }
            }
            if let decoration = sideStyle.decoration {
                ColorPicker(
                    localized("裝飾顏色"),
                    selection: colorBinding(hex: decoration.colorHex) {
                        $0[keyPath: path].decoration?.colorHex = $1
                    },
                    supportsOpacity: false
                )
                slider(
                    title: localized("裝飾大小"),
                    value: Binding(
                        get: { decoration.sizeEm },
                        set: { value in
                            update { $0[keyPath: path].decoration?.sizeEm = value }
                        }
                    ),
                    range: 0.2...3,
                    step: 0.05,
                    text: em(decoration.sizeEm)
                )
                Picker(
                    localized("裝飾位置"),
                    selection: Binding(
                        get: { decoration.anchor },
                        set: { value in
                            update { $0[keyPath: path].decoration?.anchor = value }
                        }
                    )
                ) {
                    ForEach(ReaderDialogueBubbleAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.rawValue).tag(anchor)
                    }
                }
            }
            Picker(
                localized("文字對齊"),
                selection: Binding(
                    get: { sideStyle.textAlignment ?? (side == .left ? .left : .right) },
                    set: { value in update { $0[keyPath: path].textAlignment = value } }
                )
            ) {
                Text(localized("對齊・靠左")).tag(ChapterTitleAlignment.left)
                Text(localized("對齊・置中")).tag(ChapterTitleAlignment.center)
                Text(localized("對齊・靠右")).tag(ChapterTitleAlignment.right)
            }
            .pickerStyle(.segmented)

            Menu {
                Button(localized("跟隨閱讀字體")) {
                    update { $0[keyPath: path].fontPostScriptName = nil }
                }
                ForEach(GlobalSettings.shared.userFonts, id: \.postScriptName) { font in
                    Button(font.displayName) {
                        update { $0[keyPath: path].fontPostScriptName = font.postScriptName }
                    }
                }
            } label: {
                LabeledContent(
                    localized("氣泡字體"),
                    value: sideStyle.fontPostScriptName ?? localized("跟隨閱讀字體")
                )
            }
            slider(
                title: localized("氣泡字級"),
                value: Binding(
                    get: { style[keyPath: path].fontSizeMultiplier },
                    set: { value in update { $0[keyPath: path].fontSizeMultiplier = value } }
                ),
                range: 0.6...1.6,
                step: 0.05,
                text: percent(sideStyle.fontSizeMultiplier)
            )
            Stepper(
                value: Binding(
                    get: { sideStyle.fontWeight ?? 400 },
                    set: { value in update { $0[keyPath: path].fontWeight = value } }
                ),
                in: 100...900,
                step: 100
            ) {
                LabeledContent(localized("氣泡字重"), value: "\(sideStyle.fontWeight ?? 400)")
            }
            slider(
                title: localized("氣泡字距"),
                value: Binding(
                    get: { style[keyPath: path].letterSpacingEm },
                    set: { value in update { $0[keyPath: path].letterSpacingEm = value } }
                ),
                range: -0.1...0.5,
                step: 0.01,
                text: em(sideStyle.letterSpacingEm)
            )

            Button {
                avatarPickerSide = side
            } label: {
                Label(
                    sideStyle.avatar == nil ? localized("選擇頭像") : localized("更換頭像"),
                    systemImage: "person.crop.circle"
                )
            }
            if let avatar = sideStyle.avatar {
                slider(
                    title: localized("頭像大小"),
                    value: Binding(
                        get: { avatar.sizeEm },
                        set: { value in update { $0[keyPath: path].avatar?.sizeEm = value } }
                    ),
                    range: 0.8...4,
                    step: 0.1,
                    text: em(avatar.sizeEm)
                )
                slider(
                    title: localized("頭像間距"),
                    value: Binding(
                        get: { avatar.gapEm },
                        set: { value in update { $0[keyPath: path].avatar?.gapEm = value } }
                    ),
                    range: 0...1.5,
                    step: 0.05,
                    text: em(avatar.gapEm)
                )
                Button(role: .destructive) {
                    update { $0[keyPath: path].avatar = nil }
                } label: {
                    Label(localized("移除頭像"), systemImage: "trash")
                }
            }
            if sideStyle.skin != nil {
                Button(role: .destructive) {
                    update { $0[keyPath: path].skin = nil }
                } label: {
                    Label(localized("移除氣泡皮膚圖"), systemImage: "trash")
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var actionsSection: some View {
        Section {
            if let onOpenImporter {
                Button(action: onOpenImporter) {
                    Label(localized("匯入氣泡樣式"), systemImage: "square.and.arrow.down")
                }
            }
            Button(role: .destructive) {
                update { $0 = ReaderDialogueBubbleStyle(isEnabled: true) }
            } label: {
                Label(localized("恢復預設氣泡"), systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text(localized("可以匯入對話氣泡腳本檔，只會取用它的顏色、邊距與皮膚圖，文字仍然照閱讀字級排版。"))
        }
        .interfaceSectionSurface()
    }

    // MARK: - Rows

    private func slider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text(title).font(DSFont.body)
                Spacer()
                Text(text)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(text)
        }
    }

    // MARK: - Bindings

    private func binding<Value>(
        _ path: WritableKeyPath<ReaderDialogueBubbleStyle, Value>
    ) -> Binding<Value> {
        Binding(
            get: { style[keyPath: path] },
            set: { newValue in update { $0[keyPath: path] = newValue } }
        )
    }

    /// Same colour plumbing as the 正則高亮 editor: read through
    /// `UIColor(readerStyleHex:)`, write back the picker's RGB.
    private func colorBinding(
        hex: UInt32,
        assign: @escaping (inout ReaderDialogueBubbleStyle, UInt32) -> Void
    ) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(readerStyleHex: hex)) },
            set: { newValue in
                let resolved = newValue.editorRGBHex ?? hex
                update { assign(&$0, resolved) }
            }
        )
    }

    private func assignAvatar(_ assetID: UUID, to side: ReaderDialogueBubbleSide) {
        update { style in
            let existing = style.side(side).avatar
            let avatar = ReaderDialogueBubbleAvatar(
                assetID: assetID,
                sizeEm: existing?.sizeEm ?? 2,
                gapEm: existing?.gapEm ?? 0.3,
                offsetYEm: existing?.offsetYEm ?? 0
            )
            if side == .left {
                style.left.avatar = avatar
            } else {
                style.right.avatar = avatar
            }
        }
    }

    private func update(_ mutate: (inout ReaderDialogueBubbleStyle) -> Void) {
        var next = style
        mutate(&next)
        style = next.sanitized()
        onChange(style)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func em(_ value: Double) -> String {
        String(format: "%.2f em", value)
    }
}


/// Bridges the reader's CoreText bubble painter into the settings list.
private struct DialogueBubblePreview: UIViewRepresentable {
    let style: ReaderDialogueBubbleStyle

    func makeUIView(context: Context) -> ReaderDialogueBubblePreviewView {
        ReaderDialogueBubblePreviewView()
    }

    func updateUIView(_ view: ReaderDialogueBubblePreviewView, context: Context) {
        view.style = style
    }
}

final class ReaderDialogueBubblePreviewView: UIView {
    var style: ReaderDialogueBubbleStyle = .default {
        didSet {
            guard style != oldValue else { return }
            rebuild(force: true)
        }
    }

    private var frameRef: CTFrame?
    private var attributed = NSAttributedString()
    private var layoutHeight: CGFloat = 0
    private var builtWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // Without this a custom-drawn view scrolled out of a List and back gets
        // its layer contents stretched or dropped instead of redrawn — the
        // preview comes back blank.
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Seeded before the first build: a zero intrinsic height makes SwiftUI lay
    /// the row out at zero, `layoutSubviews` then sees a zero width, and the
    /// view never builds anything — a blank preview that never recovers.
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: layoutHeight > 0 ? layoutHeight : ReaderConfig.shared.fontSize * 6
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuild(force: false)
    }

    /// Rebuilt only on a real change: `invalidateIntrinsicContentSize` triggers
    /// another layout pass, and rebuilding unconditionally from `layoutSubviews`
    /// turns that into a loop.
    private func rebuild(force: Bool) {
        let width = bounds.width
        guard width > 1 else { return }
        guard force || frameRef == nil || abs(width - builtWidth) > 0.5 else { return }
        builtWidth = width

        let fontSize = ReaderConfig.shared.fontSize
        let font = UserReaderFontResolver.bodyFont(size: fontSize, isBold: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.2

        let lines = [
            "「" + localized("你今天怎麼這麼早？") + "」",
            "「" + localized("睡不著，就先過來了。") + "」",
        ]
        let text = NSMutableAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
        )
        ReaderDialogueBubbleMarker.apply(
            style: style,
            columnWidth: width,
            bodyFontSize: fontSize,
            to: text
        )
        attributed = text

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let fullRange = CFRange(location: 0, length: text.length)
        var size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            fullRange,
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        // The bubble is drawn *around* the glyphs, so the view needs padding on
        // both sides of the text — and the text has to start that far down, or
        // the top of the first bubble is cut off by the view's own edge.
        let inset = fontSize * CGFloat(style.verticalPaddingEm) + 4
        let height = ceil(size.height) + inset * 2
        frameRef = CTFramesetterCreateFrame(
            framesetter,
            fullRange,
            CGPath(
                rect: CGRect(x: 0, y: 0, width: width, height: height - inset),
                transform: nil
            ),
            nil
        )
        layoutHeight = height
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let frameRef, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        CoreTextHorizontalLineDrawer.drawLines(
            of: frameRef,
            contentWidth: bounds.width,
            contentMinX: 0,
            contentMinY: 0,
            isLastPage: true,
            attrStr: attributed,
            hrDividerKey: HTMLAttributedStringBuilder.hrDividerAttribute,
            in: ctx
        )
        ctx.restoreGState()
    }
}

#Preview {
    NavigationStack {
        ReaderDialogueBubbleSettingsView(
            style: ReaderDialogueBubbleStyle(isEnabled: true)
        ) { _ in }
    }
}
