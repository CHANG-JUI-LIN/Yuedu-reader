import SwiftUI
import UniformTypeIdentifiers

// MARK: - List View

/// Manage user-configurable global replace rules.
/// Presented from Settings / Profile.
struct ReplaceRuleListView: View {

    @ObservedObject private var store = ReplaceRuleStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showingAdd = false
    @State private var showingImportFile = false
    @State private var editingRule: ReplaceRule?
    @State private var importAlert: ReplaceRuleImportAlert?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.rules.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(DSFont.fixed(size: 48))
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
                    Menu {
                        Button {
                            showingAdd = true
                        } label: {
                            Label(localized("新增規則"), systemImage: "plus")
                        }

                        Button {
                            showingImportFile = true
                        } label: {
                            Label(localized("匯入替換規則 JSON"), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(localized("新增或匯入"))
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
            .fileImporter(
                isPresented: $showingImportFile,
                allowedContentTypes: [UTType.json, UTType.plainText]
            ) { result in
                handleImport(result)
            }
            .alert(item: $importAlert) { alert in
                Alert(
                    title: Text(localized(alert.title)),
                    message: Text(alert.message),
                    dismissButton: .default(Text(localized("完成")))
                )
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let count = try store.importFromLegadoData(data)
                importAlert = ReplaceRuleImportAlert(
                    title: "成功匯入",
                    message: String(format: localized("已匯入 %d 條替換規則"), count)
                )
            } catch {
                importAlert = ReplaceRuleImportAlert(
                    title: "匯入失敗",
                    message: String(format: localized("替換規則匯入失敗：%@"), error.localizedDescription)
                )
            }
        case .failure(let error):
            importAlert = ReplaceRuleImportAlert(
                title: "匯入失敗",
                message: error.localizedDescription
            )
        }
    }
}

private struct ReplaceRuleImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
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
                        .font(DSFont.subheadline)
                        .bold()
                        .foregroundColor(rule.enabled ? .primary : .secondary)

                    if rule.scope != "global" {
                        Text(localized("書源"))
                            .font(DSFont.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(DSColor.highlight)
                            .foregroundColor(DSColor.accent)
                            .cornerRadius(3)
                    }
                    if rule.isRegex {
                        Text("Regex")
                            .font(DSFont.caption2)
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
                        .font(DSFont.fixed(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField(localized("替換為（空白=刪除）"), text: $rule.replacement)
                        .font(DSFont.fixed(size: 14, design: .monospaced))
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
