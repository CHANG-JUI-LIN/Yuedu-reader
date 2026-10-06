import SwiftUI

/// 排版生效範圍 — per reading setting, whether it follows the theme being worn or is
/// shared by every theme. Pushed from the top of 閱讀設定.
///
/// Laid out in 閱讀設定's own sections and order, with the same names and symbols, so a
/// row here is always the control the reader just saw there.
struct ReadingSettingsScopeView: View {
    @ObservedObject private var settings = GlobalSettings.shared

    private struct Group: Identifiable {
        let titleKey: String
        let items: [ReadingSettingsScopeItem]
        var id: String { titleKey }
    }

    /// 閱讀設定's sections, then the two settings the reader's own menu edits.
    private static let groups: [Group] = [
        Group(titleKey: "文字", items: [.font, .fontSize, .bold, .textColor]),
        Group(titleKey: "排版", items: [.writingMode, .lineSpacing, .letterSpacing, .paragraphSpacing, .pageMargins]),
        Group(titleKey: "頁首頁尾與標題", items: [.headerFooter, .chapterTitle]),
        Group(titleKey: "閱讀裝飾", items: [.commentBubble, .dialogueBubble, .regexHighlight, .textUnderline]),
        Group(titleKey: "閱讀背景與翻頁", items: [.background, .pageTurn]),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(settings.readingSettingsThemeName)
                        .foregroundStyle(DSColor.textSecondary)
                } label: {
                    SettingsRowLabel(localized("目前的主題"), systemImage: "paintpalette")
                }
                ReadingSettingsScopeRow(
                    title: localized("預設"),
                    systemImage: "slider.horizontal.3",
                    scope: defaultScopeBinding
                )
            } footer: {
                Text(localized("跟隨主題：每個主題各記一套，主題沒有的項目用全域那套；跟隨全域：所有主題共用一套。沒有單獨設定的項目照「預設」。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            ForEach(Self.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ReadingSettingsScopeRow(
                            title: localized(item.titleKey),
                            systemImage: item.systemImage,
                            scope: scopeBinding(for: item)
                        )
                    }
                } header: {
                    Text(localized(group.titleKey))
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if group.items.contains(.background) {
                        Text(localized("閱讀背景與翻頁方式在閱讀器的選單裡調整。"))
                            .dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()
            }

            Section {
                // No confirmation: nothing is deleted, and every row is one tap from back.
                Button {
                    settings.readingSettingsScope = .default
                } label: {
                    SettingsRowLabel(
                        localized("重設生效範圍"),
                        systemImage: "arrow.counterclockwise",
                        role: .action
                    )
                }
                .disabled(settings.readingSettingsScope == .default)
            } footer: {
                Text(localized("全部改回跟隨主題，各主題自己的設定會重新套用。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("排版生效範圍"))
        .toolbarTitleDisplayMode(.inline)
    }

    private var defaultScopeBinding: Binding<ReadingSettingsScope> {
        Binding(
            get: { settings.readingSettingsScope.defaultScope },
            set: { newValue in
                var configuration = settings.readingSettingsScope
                configuration.defaultScope = newValue
                settings.readingSettingsScope = configuration
            }
        )
    }

    private func scopeBinding(for item: ReadingSettingsScopeItem) -> Binding<ReadingSettingsScope> {
        Binding(
            get: { settings.readingSettingsScope.scope(of: item) },
            set: { settings.setReadingSettingsScope($0, for: item) }
        )
    }
}

/// One row: the setting's name, and 跟隨主題 | 跟隨全域 beside it — or under it at the
/// accessibility text sizes, where the two would not fit on one line.
private struct ReadingSettingsScopeRow: View {
    let title: String
    let systemImage: String
    @Binding var scope: ReadingSettingsScope
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                SettingsRowLabel(title, systemImage: systemImage)
                picker
            }
        } else {
            LabeledContent {
                picker.fixedSize()
            } label: {
                SettingsRowLabel(title, systemImage: systemImage)
            }
        }
    }

    private var picker: some View {
        Picker(title, selection: $scope) {
            ForEach(ReadingSettingsScope.allCases, id: \.self) { scope in
                Text(localized(scope.titleKey)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(title)
    }
}

#Preview {
    NavigationStack {
        ReadingSettingsScopeView()
    }
}
