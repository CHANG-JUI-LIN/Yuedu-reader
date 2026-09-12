import SwiftUI

// MARK: - LoginFormGrid
//
// The flexible login form shared by the book-source sign-in sheet and the TTS account
// sheet. Legado's `loginUi` rows are laid out as cells of a 12-column grid: each row's
// `style` decides its width (`cols` / legacy flex attributes, see `LoginField.gridSpec`),
// text/password render as rounded fields, and button/toggle/select render as pills with
// tactile press feedback adapted to iOS.
//
// Each control owns its themed surface; hosts must leave the grid background clear
// so page artwork remains visible between controls.

/// Renders `fields` as a wrapping grid of pills and rounded fields.
///
/// - Parameters:
///   - fields: Parsed `loginUi` rows, in source order.
///   - values: The form's working values, keyed by field name.
///   - labels: Resolved `viewName` labels keyed by field name; missing fields fall back
///     to `name`.
///   - onValueChange: Called after every user edit (before the row's action).
///   - onAction: Called for button taps, toggle cycles and select changes.
struct LoginFormGrid: View {
    let fields: [LoginField]
    @Binding var values: [String: String]
    let labels: [String: String]
    var onValueChange: ((LoginField, String) -> Void)?
    var onAction: ((LoginField) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LoginGridLayout(
            specs: fields.map { $0.gridSpec(accessibilityLayout: dynamicTypeSize.isAccessibilitySize) },
            horizontalSpacing: DSSpacing.md
        ) {
            ForEach(fields) { field in
                LoginFieldCell(
                    field: field,
                    label: labels[field.name] ?? field.name,
                    value: valueBinding(for: field),
                    onAction: onAction
                )
            }
        }
    }

    /// The shared value binding: a stored value wins, then the source-declared default.
    /// The setter routes through `onValueChange` so hosts keep their own persistence
    /// rules (book sources persist select changes immediately, TTS saves on 儲存).
    private func valueBinding(for field: LoginField) -> Binding<String> {
        Binding(
            get: { values[field.name] ?? field.defaultValue ?? "" },
            set: { newValue in
                values[field.name] = newValue
                onValueChange?(field, newValue)
            }
        )
    }
}

// MARK: - Cell

private struct LoginFieldCell: View {
    let field: LoginField
    let label: String
    @Binding var value: String
    let onAction: ((LoginField) -> Void)?

    var body: some View {
        content
            // Vertical breathing room lives inside the cell so the grid can keep its
            // row boundaries free of spacing math (horizontal gaps are the Layout's).
            .padding(.vertical, DSSpacing.sm)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch field.type {
        case .text, .password:
            LoginTextFieldCell(field: field, label: label, value: $value, alignment: alignment)

        case .button:
            LoginActionPill(label: label, alignment: alignment) {
                onAction?(field)
            }

        case .toggle:
            if LoginToggleChars(options: field.options) != nil {
                LoginTogglePill(
                    field: field, label: label, value: $value,
                    alignment: alignment
                ) {
                    onAction?(field)
                }
            } else {
                // `chars` that isn't a two-state pair can't flip — show the choices
                // instead of guessing which one means on.
                selectCell
            }

        case .select:
            selectCell
        }
    }

    @ViewBuilder
    private var selectCell: some View {
        if field.options.isEmpty {
            // A select without options is a plain input, as in the original sheet.
            LoginTextFieldCell(field: field, label: label, value: $value, alignment: alignment)
        } else {
            LoginSelectPill(
                field: field, label: label, value: $value,
                alignment: alignment
            ) {
                onAction?(field)
            }
        }
    }

    private var alignment: LoginPillAlignment {
        LoginPillAlignment(
            justifySelf: field.style?.justifySelf,
            defaultAlignment: field.type == .text || field.type == .password ? .leading : .center
        )
    }
}

// MARK: - Text / password

private struct LoginTextFieldCell: View {
    let field: LoginField
    let label: String
    @Binding var value: String
    let alignment: LoginPillAlignment

    private var prompt: Text? {
        guard let hint = field.options.first(where: { !$0.isEmpty }) else { return nil }
        return Text(hint).foregroundColor(DSColor.textTertiary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if !label.isEmpty {
                Text(label)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The field itself carries the label; a separate caption element
                    // would make VoiceOver focus it twice.
                    .accessibilityHidden(true)
            }
            Group {
                if field.type == .password {
                    SecureField("", text: $value, prompt: prompt)
                } else {
                    TextField("", text: $value, prompt: prompt)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .font(DSFont.body)
            .foregroundStyle(DSColor.textPrimary)
            .multilineTextAlignment(alignment.textAlignment)
            .tint(DSColor.accent)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label.isEmpty ? field.name : label)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .leading)
        .interfaceCardSurface(
            in: RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous),
            fill: DSColor.surfaceTertiary
        )
    }
}

// MARK: - Pills

private struct LoginActionPill: View {
    let label: String
    let alignment: LoginPillAlignment
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DSFont.headline)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(alignment.textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                .padding(.horizontal, DSSpacing.md)
        }
        .buttonStyle(LoginPressButtonStyle())
    }
}

private struct LoginTogglePill: View {
    let field: LoginField
    let label: String
    @Binding var value: String
    let alignment: LoginPillAlignment
    let action: () -> Void

    private var chars: [String] {
        field.options.filter { !$0.isEmpty }
    }

    /// What Legado's `rowUiBuilder` shows: the stored char, else the declared default,
    /// else the first char. The declared default is display-only — flipping writes the
    /// next char, exactly like the previous switch row.
    private var currentChar: String {
        if !value.isEmpty { return value }
        if let declared = field.defaultValue, !declared.isEmpty { return declared }
        return chars.first ?? ""
    }

    private var displayText: String {
        alignment == .trailing ? "\(label)\(currentChar)" : "\(currentChar)\(label)"
    }

    var body: some View {
        Button {
            guard !chars.isEmpty else { return }
            let index = chars.firstIndex(of: currentChar) ?? -1
            value = chars[(index + 1) % chars.count]
            action()
        } label: {
            Text(displayText)
                .font(DSFont.headline)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(alignment.textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                .padding(.horizontal, DSSpacing.md)
        }
        .buttonStyle(LoginPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(currentChar)
    }
}

private struct LoginSelectPill: View {
    let field: LoginField
    let label: String
    @Binding var value: String
    let alignment: LoginPillAlignment
    let action: () -> Void

    /// Options plus a stored value the source no longer declares, so a saved selection
    /// is not silently dropped from the menu (mirrors the old row's `options(for:)`).
    private var options: [String] {
        let declared = field.options.filter { !$0.isEmpty }
        guard !selected.isEmpty, !declared.contains(selected) else { return declared }
        return [selected] + declared
    }

    private var selected: String {
        if !value.isEmpty { return value }
        if let declared = field.defaultValue, !declared.isEmpty { return declared }
        return field.options.first(where: { !$0.isEmpty }) ?? ""
    }

    var body: some View {
        Menu {
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: DSSpacing.xs)
                Text(selected)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .font(DSFont.subheadline)
            .padding(.horizontal, DSSpacing.md)
        }
        .buttonStyle(LoginPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(selected)
    }

    private var selection: Binding<String> {
        Binding(
            get: { selected },
            set: { newValue in
                value = newValue
                action()
            }
        )
    }
}

// MARK: - Press feedback

/// Shared source-login action surface. Press feedback stays visible over both
/// artwork and glass; Reduce Motion retains the tint feedback without scaling.
struct LoginPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DSRadius.xxl, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, DSSpacing.md)
            .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget)
            .foregroundStyle(DSColor.textPrimary)
            .interfaceCardSurface(in: shape)
            .overlay {
                shape.fill(DSColor.highlight)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                shape.strokeBorder(
                    DSColor.border,
                    lineWidth: contrast == .increased ? DSLayout.loginControlContrastBorder : DSLayout.loginControlBorder
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .interfaceGlow(in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : DSLayout.loginControlDisabledOpacity)
            .scaleEffect(configuration.isPressed && !reduceMotion ? DSLayout.loginControlPressedScale : 1)
            .animation(reduceMotion ? nil : DSAnimation.press, value: configuration.isPressed)
    }
}

// MARK: - Alignment

private enum LoginPillAlignment: Equatable {
    case leading
    case center
    case trailing

    init(justifySelf: String?, defaultAlignment: Self) {
        switch justifySelf {
        case "center": self = .center
        case "flex_end", "right": self = .trailing
        case "flex_start", "left": self = .leading
        default: self = defaultAlignment
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Grid layout

/// Places the login cells on the 12-column packing produced by `LoginGridPacker`.
/// A port of Legado-upstream's `GridPackLayout` (row-span support included).
struct LoginGridLayout: Layout {
    let specs: [LoginGridSpec]
    let horizontalSpacing: CGFloat

    struct Cache {
        var width: CGFloat = -1
        var placements = Placements()
    }

    struct Placements {
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.width = -1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? proposal.replacingUnspecifiedDimensions().width
        cache.placements = placements(width: width, subviews: subviews)
        cache.width = width
        return CGSize(width: width, height: cache.placements.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.width != bounds.width {
            cache.placements = placements(width: bounds.width, subviews: subviews)
            cache.width = bounds.width
        }
        for (index, subview) in subviews.enumerated() {
            guard index < cache.placements.frames.count else { break }
            let frame = cache.placements.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func placements(width: CGFloat, subviews: Subviews) -> Placements {
        let count = min(specs.count, subviews.count)
        guard count > 0, width > 0 else { return Placements() }

        let cells = LoginGridPacker.pack(specs: Array(specs.prefix(count)))

        func columnX(_ column: Int) -> CGFloat {
            (width + horizontalSpacing) * CGFloat(column) / CGFloat(LoginGridSpec.columnCount)
        }

        var cellWidths = [CGFloat](repeating: 0, count: count)
        var naturalHeights = [CGFloat](repeating: DSLayout.minimumTapTarget, count: count)
        for index in 0..<count {
            let cell = cells[index]
            let end = min(cell.column + cell.colSpan, LoginGridSpec.columnCount)
            let cellWidth = max(columnX(end) - columnX(cell.column) - horizontalSpacing, 1)
            cellWidths[index] = cellWidth
            let measured = subviews[index]
                .sizeThatFits(ProposedViewSize(width: cellWidth, height: nil))
                .height
            naturalHeights[index] = max(measured, DSLayout.minimumTapTarget)
        }

        let rowCount = cells.map { $0.row + $0.rowSpan }.max() ?? 0
        guard rowCount > 0 else { return Placements() }
        var rowY = [CGFloat](repeating: 0, count: rowCount + 1)
        for row in 1...rowCount {
            var boundary = rowY[row - 1]
            for index in 0..<count where cells[index].row + cells[index].rowSpan == row {
                boundary = max(boundary, rowY[cells[index].row] + naturalHeights[index])
            }
            rowY[row] = boundary
        }

        let frames = (0..<count).map { index -> CGRect in
            let cell = cells[index]
            return CGRect(
                x: columnX(cell.column),
                y: rowY[cell.row],
                width: cellWidths[index],
                height: rowY[cell.row + cell.rowSpan] - rowY[cell.row]
            )
        }
        return Placements(frames: frames, height: rowY[rowCount])
    }
}

#Preview("Source login controls") {
    ScrollView {
        LoginFormGrid(
            fields: LoginManager.shared.parseLoginUi("""
            [{"name":"Account","type":"button","style":{"cols":1}},
             {"name":"Token","type":"text"},
             {"name":"Sign in","type":"button","style":{"cols":2}},
             {"name":"Register","type":"button","style":{"cols":2}}]
            """),
            values: .constant([:]), labels: [:]
        )
        .padding(DSSpacing.lg)
    }
    .themedAppSurface(for: .settings)
}
