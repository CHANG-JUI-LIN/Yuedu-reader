import SwiftUI

/// 外觀主題 › 界面效果 — the two knobs behind `View.floatingSurface(in:)`, with a
/// live sample of what they do. Every floating element in the app reads the same
/// values, so the preview here is the real modifier rather than a mock-up.
struct AppearanceInterfaceEffectsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Form {
            Section {
                previewCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(localized("效果套用於底部迷你播放器與閱讀器的浮動工具列、控制欄。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Section {
                glowRow
            } footer: {
                Text(localized("光暈從浮動元素的邊緣向外擴散，顏色跟隨主題色。"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                Toggle(isOn: $settings.interfaceFrostedGlass) {
                    Text(localized("毛玻璃"))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                }

                if settings.interfaceFrostedGlass {
                    transparencyRow
                }
            } footer: {
                Text(localized(frostedGlassFooterKey))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            // Hidden with 毛玻璃 off: sections borrow that material, so the switch
            // would be visibly inert. Same rule as 透明度 above.
            if settings.interfaceFrostedGlass {
                Section {
                    Toggle(isOn: $settings.interfaceGlassCards) {
                        Text(localized("分組卡片"))
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                    }
                } footer: {
                    Text(localized("設定、統計、書籍詳情等頁面的卡片也改用玻璃材質，跟隨上方的透明度。系統設計建議玻璃只用於浮動控制項，因此預設關閉。"))
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
        }
        .font(DSFont.body)
        .scrollContentBackground(.hidden)
        .navigationTitle(localized("界面效果"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }

    // MARK: - Rows

    private var glowRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text(localized("光暈強度"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(glowValueText)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            Slider(
                value: $settings.interfaceGlowIntensity,
                in: GlobalSettings.interfaceGlowIntensityRange,
                step: 0.05
            )
            // A bare Slider has no name and announces a fraction of its range;
            // both modifiers reuse the text shown above. docs/design.md §7.1.
            .accessibilityLabel(localized("光暈強度"))
            .accessibilityValue(glowValueText)
        }
    }

    private var transparencyRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text(localized("透明度"))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.md)
                Text(transparencyValueText)
                    .font(DSFont.body.monospacedDigit())
                    .foregroundStyle(DSColor.textSecondary)
            }
            Slider(
                value: $settings.interfaceGlassTransparency,
                in: GlobalSettings.interfaceGlassTransparencyRange,
                step: 0.05
            )
            .accessibilityLabel(localized("透明度"))
            .accessibilityValue(transparencyValueText)
        }
    }

    /// Reduce Transparency overrides the toggle, so say so instead of leaving the
    /// user with a switch that visibly does nothing.
    private var frostedGlassFooterKey: String {
        reduceTransparency
            ? "系統已開啟「降低透明度」，浮動元素目前一律使用不透明底色。"
            : "關閉後，浮動元素改用不透明底色。透明度越低，背後的內容越不透出。"
    }

    private var glowValueText: String {
        Self.percentText(settings.interfaceGlowIntensity)
    }

    private var transparencyValueText: String {
        Self.percentText(settings.interfaceGlassTransparency)
    }

    private static func percentText(_ value: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .percent)
    }

    // MARK: - Preview card

    /// Floating samples over stand-in body text, so 毛玻璃 has something to blur and
    /// 光暈 something to bleed onto. Decorative as a whole — VoiceOver gets one
    /// element naming what it is, not each sample icon.
    private var previewCard: some View {
        ZStack {
            previewBackdrop

            VStack(spacing: DSSpacing.xl) {
                HStack(spacing: DSSpacing.lg) {
                    previewCircle("textformat.size")
                    previewCircle("play.fill")
                    previewCircle("list.bullet")
                }

                Text(localized("浮動工具列"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textPrimary)
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.vertical, DSSpacing.md)
                    .floatingSurface(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DSLayout.interfaceEffectPreviewHeight)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("效果預覽"))
    }

    private func previewCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(DSFont.toolbarIconLarge)
            .foregroundStyle(DSColor.textPrimary)
            .frame(width: 48, height: 48)
            .floatingSurface(in: Circle())
    }

    private var previewBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DSColor.accent.opacity(0.32),
                    DSColor.groupedBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                ForEach(0..<6, id: \.self) { row in
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                        .fill(DSColor.textPrimary.opacity(0.16))
                        .frame(height: 6)
                        .frame(maxWidth: row.isMultiple(of: 3) ? .infinity : 220, alignment: .leading)
                }
            }
            .padding(DSSpacing.lg)
        }
    }
}

#Preview {
    NavigationStack {
        AppearanceInterfaceEffectsView()
    }
}
