import SwiftUI

// MARK: - BookSourceImportOptionsSection

/// The 匯入選項 row inside the book-source import confirmation list, with a one-line summary
/// of what is currently set. Pushes the full options page.
struct BookSourceImportOptionsSection: View {
    @Binding var options: BookSourceImportOptions
    let groupCandidates: [BookSourceGroupCandidate]

    var body: some View {
        Section {
            NavigationLink {
                BookSourceImportOptionsView(
                    options: $options,
                    groupCandidates: groupCandidates
                )
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    Label(localized("匯入選項"), systemImage: "slider.horizontal.3")
                        .foregroundColor(DSColor.textPrimary)
                    Spacer(minLength: DSSpacing.sm)
                    Text(summary)
                        .font(DSFont.subheadline)
                        .foregroundColor(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("匯入選項"))
            .accessibilityValue(summary)
        }
        .interfaceSectionSurface()
    }

    /// What is switched on, so the user doesn't have to open the page to check.
    private var summary: String {
        var parts: [String] = []
        if options.keepName { parts.append(localized("保留原名")) }
        if options.keepGroup { parts.append(localized("保留分組")) }
        if options.keepEnable { parts.append(localized("保留啟用狀態")) }
        if let group = options.trimmedGroupName {
            parts.append(
                String(
                    format: localized(options.addsToExistingGroups ? "附加分組「%@」" : "分組「%@」"),
                    group
                )
            )
        }
        return parts.isEmpty ? localized("預設") : parts.joined(separator: " · ")
    }
}

// MARK: - BookSourceImportOptionsView

/// 匯入選項: what an import keeps from the local copy when it overwrites a source the library
/// already has, and which group the imported sources land in — Legado's import-dialog menu,
/// as a page.
struct BookSourceImportOptionsView: View {
    @Binding var options: BookSourceImportOptions
    let groupCandidates: [BookSourceGroupCandidate]

    @State private var showsGroupPicker = false

    var body: some View {
        List {
            Section {
                Toggle(localized("保留原名"), isOn: $options.keepName)
                Toggle(localized("保留分組"), isOn: $options.keepGroup)
                Toggle(localized("保留啟用狀態"), isOn: $options.keepEnable)
            } header: {
                Text(localized("覆蓋已有來源配置時"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("來源配置包會帶著作者自己的名稱、分組與啟用狀態。開啟後，這幾項沿用本機的設定，只更新規則。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Button {
                    showsGroupPicker = true
                } label: {
                    HStack(spacing: DSSpacing.sm) {
                        Text(localized("匯入到分組"))
                            .foregroundColor(DSColor.textPrimary)
                        Spacer(minLength: DSSpacing.sm)
                        Text(options.trimmedGroupName ?? localized("不指定"))
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("匯入到分組"))
                .accessibilityValue(options.trimmedGroupName ?? localized("不指定"))

                if options.trimmedGroupName != nil {
                    Picker(localized("分組方式"), selection: $options.addsToExistingGroups) {
                        Text(localized("取代原分組")).tag(false)
                        Text(localized("附加到原分組")).tag(true)
                    }
                    Button(role: .destructive) {
                        options.groupName = nil
                        options.addsToExistingGroups = false
                    } label: {
                        Text(localized("清除分組指定"))
                    }
                    .frame(minHeight: DSLayout.minimumTapTarget)
                }
            } header: {
                Text(localized("分組"))
                    .foregroundStyle(DSColor.textSecondary)
            } footer: {
                if options.trimmedGroupName != nil, options.keepGroup {
                    Text(localized("已開啟「保留分組」：本機已有的來源配置會先還原成原本的分組，再套用這裡的指定。"))
                        .dsSectionFooter()
                }
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("匯入選項"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .sheet(isPresented: $showsGroupPicker) {
            BookSourceGroupPickerSheet(
                title: localized("匯入到分組"),
                subtitle: localized("選中的來源配置會歸到這個分組"),
                candidates: groupCandidates,
                excluded: "",
                defaultGroupTitle: nil,
                defaultGroupName: "",
                allowsNewGroup: true,
                onSelect: { name in
                    options.groupName = name
                }
            )
        }
    }
}

#Preview {
    NavigationStack {
        BookSourceImportOptionsView(
            options: .constant(.manualDefaults),
            groupCandidates: [
                BookSourceGroupCandidate(name: "玄幻", count: 42),
                BookSourceGroupCandidate(name: "都市", count: 17),
            ]
        )
    }
}
