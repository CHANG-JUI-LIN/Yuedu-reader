import SwiftUI

// MARK: - List View

/// Manage user-configurable global replace rules.
/// Presented from Settings / Profile.
struct ReplaceRuleListView: View {

    @ObservedObject private var store = ReplaceRuleStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showingAdd = false
    @State private var editingRule: ReplaceRule?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if store.rules.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(gs.t("尚無替換規則"))
                            .foregroundColor(.secondary)
                        Button(gs.t("新增規則")) { showingAdd = true }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.rules) { rule in
                            ReplaceRuleRow(rule: rule) {
                                editingRule = rule
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { store.rules[$0].id }.forEach { store.delete(id: $0) }
                        }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(gs.t("替換規則"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("關閉")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        EditButton()
                        Button { showingAdd = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                ReplaceRuleEditView(rule: nil) { store.add($0) }
            }
            .sheet(item: $editingRule) { rule in
                ReplaceRuleEditView(rule: rule) { store.update($0) }
            }
        }
    }
}

// MARK: - Row

private struct ReplaceRuleRow: View {

    let rule: ReplaceRule
    let onTap: () -> Void
    @ObservedObject private var store = ReplaceRuleStore.shared
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? gs.t("未命名規則") : rule.name)
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(rule.enabled ? .primary : .secondary)

                    if rule.scope != "global" {
                        Text(gs.t("書源"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(3)
                    }
                    if rule.isRegex {
                        Text("Regex")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
                            .cornerRadius(3)
                    }
                }
                Text(rule.pattern)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !rule.replacement.isEmpty {
                    Text("→ \(rule.replacement)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { var r = rule; r.enabled = $0; store.update(r) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Edit View

struct ReplaceRuleEditView: View {

    @State private var rule: ReplaceRule
    let onSave: (ReplaceRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gs = GlobalSettings.shared

    init(rule: ReplaceRule?, onSave: @escaping (ReplaceRule) -> Void) {
        _rule = State(initialValue: rule ?? ReplaceRule(name: "", pattern: ""))
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(gs.t("基本"))) {
                    TextField(gs.t("規則名稱"), text: $rule.name)
                    Toggle(gs.t("啟用"), isOn: $rule.enabled)
                }

                Section(header: Text(gs.t("匹配"))) {
                    Toggle(gs.t("正則表達式"), isOn: $rule.isRegex)
                    TextField(gs.t("匹配模式"), text: $rule.pattern)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField(gs.t("替換為（空白=刪除）"), text: $rule.replacement)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                }

                Section(header: Text(gs.t("作用範圍"))) {
                    Picker(gs.t("範圍"), selection: $rule.scope) {
                        Text(gs.t("全局")).tag("global")
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle(rule.name.isEmpty ? gs.t("新增規則") : rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("儲存")) {
                        onSave(rule)
                        dismiss()
                    }
                    .disabled(rule.pattern.isEmpty)
                    .font(.body.weight(.semibold))
                }
            }
        }
    }
}
