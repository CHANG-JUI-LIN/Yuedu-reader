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
        NavigationStack {
            Group {
                if store.rules.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(localized("尚無替換規則"))
                            .foregroundColor(.secondary)
                        Button(localized("新增規則")) { showingAdd = true }
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
            .navigationTitle(localized("替換規則"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
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
                    Text(rule.name.isEmpty ? localized("未命名規則") : rule.name)
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(rule.enabled ? .primary : .secondary)

                    if rule.scope != "global" {
                        Text(localized("書源"))
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
        NavigationStack {
            Form {
                Section(header: Text(localized("基本"))) {
                    TextField(localized("規則名稱"), text: $rule.name)
                    Toggle(localized("啟用"), isOn: $rule.enabled)
                }

                Section(header: Text(localized("匹配"))) {
                    Toggle(localized("正則表達式"), isOn: $rule.isRegex)
                    TextField(localized("匹配模式"), text: $rule.pattern)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField(localized("替換為（空白=刪除）"), text: $rule.replacement)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                }

                Section(header: Text(localized("作用範圍"))) {
                    Picker(localized("範圍"), selection: $rule.scope) {
                        Text(localized("全局")).tag("global")
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle(rule.name.isEmpty ? localized("新增規則") : rule.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(rule)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(rule.pattern.isEmpty)
                }
            }
        }
    }
}
