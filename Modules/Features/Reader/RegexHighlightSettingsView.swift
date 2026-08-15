import SwiftUI
import UIKit

/// 正則高亮 — the rule list.
///
/// Every rule's on/off switch sits **in its row**, because turning 「對話」 orange
/// off is the one thing a reader comes here to do and it used to require opening
/// the editor (or discovering a swipe action). Opening the editor is the rarer
/// action, so it keeps the row's disclosure chevron.
///
/// The rows are hand-built rather than `NavigationLink` rows: a `NavigationLink`
/// claims the whole row's hit area, which would swallow both the switch and the
/// 複製 button. `navigationDestination(item:)` gives the same push with three
/// independent targets.
struct RegexHighlightSettingsView: View {
    /// `navigationDestination(item:)` needs a `Hashable` route, and a rule's
    /// *identity* is its id — hashing the whole value would tear the pushed
    /// editor down and rebuild it the moment the editor changed a colour.
    private struct RuleRoute: Hashable {
        let rule: RegexHighlightRule

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.rule.id == rhs.rule.id }
        func hash(into hasher: inout Hasher) { hasher.combine(rule.id) }
    }

    private static let colorDotDiameter: CGFloat = 10

    @StateObject private var model: RegexHighlightSettingsModel
    @State private var editedRule: RuleRoute?
    @State private var showingResetConfirmation = false

    /// Opens the rule importer. Non-nil only where a first-level presenter can
    /// own the document picker — see `Technotes/iOS17MenuModalPresentation.md`.
    private let onOpenImporter: (() -> Void)?

    init(
        configuration: RegexHighlightConfiguration,
        onOpenImporter: (() -> Void)? = nil,
        onChange: @escaping (RegexHighlightConfiguration) -> Void
    ) {
        self.onOpenImporter = onOpenImporter
        _model = StateObject(
            wrappedValue: RegexHighlightSettingsModel(
                configuration: configuration,
                onChange: onChange
            )
        )
    }

    var body: some View {
        List {
            globalSection
            summarySection
            builtInSection
            customSection
            actionSection
        }
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("正則高亮"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .navigationDestination(item: $editedRule) { route in
            RegexHighlightRuleEditorView(rule: route.rule) { updated in
                model.update(updated)
            }
        }
        .alert(localized("重設所有規則？"), isPresented: $showingResetConfirmation) {
            Button(localized("重設"), role: .destructive) { model.resetToDefaults() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("內置規則會恢復預設顏色與開關，自定義規則會全部刪除。"))
        }
    }

    // MARK: - Global switch

    private var globalSection: some View {
        Section {
            Toggle(
                localized("啟用正則高亮"),
                isOn: Binding(
                    get: { model.configuration.isEnabled },
                    set: model.setGlobalEnabled
                )
            )
        } footer: {
            Text(localized("關閉後下面的規則只做配置，不會參與閱讀頁匹配。"))
        }
        .interfaceSectionSurface()
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                statRow
                Divider()
                Text(localized("常用引號已經內置。平時只需要開關或改顏色；要做特殊高亮時，再新增自定義規則。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                globalSwitchLine
            }
            .padding(.vertical, DSSpacing.sm)
        }
        .interfaceSectionSurface()
    }

    private var statRow: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(value: model.summary.enabledCount, title: localized("已啟用"))
            statDivider
            stat(value: model.summary.builtInCount, title: localized("內置"))
            statDivider
            stat(value: model.summary.customCount, title: localized("自定義"))
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(value.formatted())
                .font(DSFont.title2)
                .foregroundStyle(DSColor.textPrimary)
            Text(title)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statDivider: some View {
        Divider()
            .frame(height: DSLayout.minimumTapTarget)
            .accessibilityHidden(true)
    }

    /// Status, not a control — the switch itself is the first row on the page.
    /// This line exists because 「全局開關關閉中」 is the answer to "why is none of
    /// this doing anything", and a reader scanning the rule list needs it where
    /// the counts are, not only in a toggle they already scrolled past.
    @ViewBuilder
    private var globalSwitchLine: some View {
        let isEnabled = model.configuration.isEnabled
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(
                isEnabled
                    ? localized("全局開關已開啟")
                    : localized("全局開關關閉中")
            )
            .font(DSFont.subheadline)
        }
        .foregroundStyle(isEnabled ? DSColor.success : DSColor.warning)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Rules

    private var builtInSection: some View {
        Section {
            ForEach(model.configuration.rules) { rule in
                ruleRow(rule, isBuiltIn: true)
            }
        } header: {
            Text(localized("內置規則"))
        } footer: {
            Text(localized("內置規則不能刪除。需要改匹配方式時，直接複製一條為自定義規則再改。"))
        }
        .interfaceSectionSurface()
    }

    private var customSection: some View {
        Section {
            ForEach(model.configuration.customRules) { rule in
                ruleRow(rule, isBuiltIn: false)
            }
            .onDelete { offsets in
                let ids = offsets.compactMap { index in
                    model.configuration.customRules.indices.contains(index)
                        ? model.configuration.customRules[index].id
                        : nil
                }
                for id in ids {
                    model.delete(ruleID: id)
                }
            }
            .onMove(perform: model.moveCustom)

            Button {
                editedRule = RuleRoute(rule: model.makeCustomDraft())
            } label: {
                Label(localized("添加自定義規則"), systemImage: "plus.circle.fill")
            }
        } header: {
            Text(localized("自定義規則"))
        } footer: {
            Text(localized("自定義規則排在內置規則之後，適合做更具體的覆蓋高亮。左滑可刪除，點右上角「編輯」可排序。"))
        }
        .interfaceSectionSurface()
    }

    /// Same shape and same place as 章節標題樣式's 操作 section, so the two style
    /// pages' file actions sit where the other one taught the user to look.
    private var actionSection: some View {
        Section(header: Text(localized("操作"))) {
            ShareLink(
                item: RegexHighlightExportPayload(configuration: model.configuration),
                preview: SharePreview(localized("正則高亮"))
            ) {
                Label(localized("匯出規則"), systemImage: "square.and.arrow.up")
            }
            if let onOpenImporter {
                Button {
                    onOpenImporter()
                } label: {
                    Label(localized("匯入規則"), systemImage: "tray.and.arrow.down")
                }
            }
            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                Label(localized("重設所有規則"), systemImage: "arrow.counterclockwise")
            }
        }
        .interfaceSectionSurface()
    }

    private func ruleRow(_ rule: RegexHighlightRule, isBuiltIn: Bool) -> some View {
        HStack(spacing: DSSpacing.md) {
            Toggle(
                rule.name,
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { model.setRuleEnabled($0, id: rule.id) }
                )
            )
            .labelsHidden()
            .accessibilityLabel(rule.name)

            Button {
                editedRule = RuleRoute(rule: rule)
            } label: {
                ruleLabel(rule, isBuiltIn: isBuiltIn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rule.name)
            .accessibilityValue(rule.pattern)
            .accessibilityHint(localized("編輯規則"))
            .accessibilityAddTraits(.isButton)

            Button {
                model.copyAsCustom(ruleID: rule.id)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(localized("複製為自定義規則"))

            Image(systemName: "chevron.right")
                .font(DSFont.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !isBuiltIn) {
            if !isBuiltIn {
                Button(role: .destructive) {
                    model.delete(ruleID: rule.id)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            }
            Button {
                model.copyAsCustom(ruleID: rule.id)
            } label: {
                Label(localized("複製為自定義規則"), systemImage: "doc.on.doc")
            }
        }
    }

    private func ruleLabel(_ rule: RegexHighlightRule, isBuiltIn: Bool) -> some View {
        HStack(spacing: DSSpacing.md) {
            Circle()
                .fill(Color(uiColor: ruleColor(rule)))
                .frame(width: Self.colorDotDiameter, height: Self.colorDotDiameter)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                HStack(spacing: DSSpacing.sm) {
                    Text(rule.name)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                    if isBuiltIn {
                        Text(localized("內置"))
                            .font(DSFont.caption2)
                            .foregroundStyle(DSColor.textSecondary)
                            .padding(.horizontal, DSSpacing.sm)
                            .padding(.vertical, DSSpacing.xs / 2)
                            .background(
                                Capsule().fill(DSColor.neutralControlFill)
                            )
                    }
                }
                Text(rule.pattern)
                    .font(DSFont.caption.monospaced())
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - ⋯

    private func ruleColor(_ rule: RegexHighlightRule) -> UIColor {
        let hex = rule.lightStyle.text.colorHex ?? 0x808080
        return GlobalSettings.uiColor(rgbHex: hex)
    }
}

#Preview {
    NavigationStack {
        RegexHighlightSettingsView(configuration: .disabled) { _ in }
    }
}
