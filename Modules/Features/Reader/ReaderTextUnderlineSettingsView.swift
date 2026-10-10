import SwiftUI

/// 文字底線, pushed from 閱讀設定 › 閱讀裝飾 like the other three decorations there. It
/// used to unfold inside 閱讀設定 itself, the one decoration edited in place, which put
/// four controls between 正則高亮 and the rest of the page whenever it was on.
struct ReaderTextUnderlineSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var settings = GlobalSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.readerTextUnderlineDecorationEnabled) {
                    SettingsRowLabel(localized("文字底線"), systemImage: "underline")
                }
            } footer: {
                Text(localized("在每行水平正文下方顯示淡底線。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if settings.readerTextUnderlineDecorationEnabled {
                Section {
                    ColorPicker(selection: colorBinding, supportsOpacity: false) {
                        SettingsRowLabel(localized("底線顏色"), systemImage: "paintbrush")
                    }
                    Picker(selection: $settings.readerTextUnderlineStyle) {
                        ForEach(ReaderTextUnderlineStyle.allCases, id: \.self) { style in
                            Label(style.localizedTitle, systemImage: style.systemImageName)
                                .tag(style)
                        }
                    } label: {
                        SettingsRowLabel(localized("底線樣式"), systemImage: "line.3.horizontal")
                    }
                    SettingsSliderRow(
                        title: localized("粗細"),
                        systemImage: "lineweight",
                        valueText: String(format: "%.1f pt", settings.readerTextUnderlineThickness),
                        value: $settings.readerTextUnderlineThickness,
                        range: GlobalSettings.readerUnderlineThicknessRange,
                        step: 0.1
                    )
                    SettingsSliderRow(
                        title: localized("偏移"),
                        systemImage: "arrow.down.to.line.compact",
                        valueText: String(format: "%.1f pt", settings.readerTextUnderlineOffset),
                        value: $settings.readerTextUnderlineOffset,
                        range: GlobalSettings.readerUnderlineOffsetRange,
                        step: 0.5
                    )
                } header: {
                    Text(localized("樣式"))
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("文字底線"))
        .toolbarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : DSAnimation.standard, value: settings.readerTextUnderlineDecorationEnabled)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(uiColor: GlobalSettings.uiColor(rgbHex: settings.readerTextUnderlineDecorationColorHex))
            },
            set: {
                settings.readerTextUnderlineDecorationColorHex =
                    UIColor($0).rgbHex ?? GlobalSettings.defaultReaderUnderlineColorHex
            }
        )
    }
}

#Preview {
    NavigationStack {
        ReaderTextUnderlineSettingsView()
    }
}
