import SwiftUI
import UIKit

struct RegexHighlightSettingsView: View {
    @StateObject private var model: RegexHighlightSettingsModel

    init(
        configuration: RegexHighlightConfiguration,
        onChange: @escaping (RegexHighlightConfiguration) -> Void
    ) {
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
        }
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("正則高亮"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

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
            Text(
                model.configuration.isEnabled
                    ? localized("已啟用的規則會依列表順序套用；後面的規則可覆蓋相同屬性。")
                    : localized("目前已關閉，下面的規則只做配置，不會參與閱讀頁匹配。")
            )
        }
        .interfaceSectionSurface()
    }

    private var summarySection: some View {
        Section(localized("規則統計")) {
            LabeledContent(localized("已啟用"), value: model.summary.enabledCount.formatted())
            LabeledContent(localized("內置"), value: model.summary.builtInCount.formatted())
            LabeledContent(localized("自定義"), value: model.summary.customCount.formatted())
        }
        .interfaceSectionSurface()
    }

    private var builtInSection: some View {
        Section {
            ForEach(model.configuration.rules) { rule in
                ruleLink(rule, isBuiltIn: true)
            }
        } header: {
            Text(localized("內置規則"))
        } footer: {
            Text(localized("內置規則不能刪除或改動匹配模板；需要不同匹配方式時，可先複製為自定義規則。"))
        }
        .interfaceSectionSurface()
    }

    private var customSection: some View {
        Section {
            if model.configuration.customRules.isEmpty {
                ContentUnavailableView(
                    localized("尚無自定義規則"),
                    systemImage: "text.magnifyingglass",
                    description: Text(localized("新增規則來匹配你指定的文字。"))
                )
            } else {
                ForEach(model.configuration.customRules) { rule in
                    ruleLink(rule, isBuiltIn: false)
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
            }

            NavigationLink {
                RegexHighlightRuleEditorView(rule: model.makeCustomDraft()) { updated in
                    model.update(updated)
                }
            } label: {
                Label(localized("新增規則"), systemImage: "plus")
            }
        } header: {
            Text(localized("自定義規則"))
        }
        .interfaceSectionSurface()
    }

    private func ruleLink(_ rule: RegexHighlightRule, isBuiltIn: Bool) -> some View {
        NavigationLink {
            RegexHighlightRuleEditorView(rule: rule) { updated in
                model.update(updated)
            }
        } label: {
            LabeledContent {
                Text(rule.pattern)
                    .font(DSFont.caption.monospaced())
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            } label: {
                Label {
                    Text(rule.name)
                } icon: {
                    Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Color(uiColor: ruleColor(rule)))
                }
            }
        }
        .accessibilityValue(rule.isEnabled ? localized("已啟用") : localized("已停用"))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.setRuleEnabled(!rule.isEnabled, id: rule.id)
            } label: {
                Label(
                    rule.isEnabled ? localized("停用") : localized("啟用"),
                    systemImage: rule.isEnabled ? "pause.circle" : "checkmark.circle"
                )
            }
            .tint(rule.isEnabled ? DSColor.textSecondary : DSColor.success)
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
        .contextMenu {
            Button {
                model.setRuleEnabled(!rule.isEnabled, id: rule.id)
            } label: {
                Label(
                    rule.isEnabled ? localized("停用") : localized("啟用"),
                    systemImage: rule.isEnabled ? "pause.circle" : "checkmark.circle"
                )
            }
            Button {
                model.copyAsCustom(ruleID: rule.id)
            } label: {
                Label(localized("複製為自定義規則"), systemImage: "doc.on.doc")
            }
            if !isBuiltIn {
                Button(role: .destructive) {
                    model.delete(ruleID: rule.id)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            }
        }
    }

    private func ruleColor(_ rule: RegexHighlightRule) -> UIColor {
        let hex = rule.lightStyle.text.colorHex ?? 0x808080
        return GlobalSettings.uiColor(rgbHex: hex)
    }
}
