import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stepperRow(
                        title: localized("並發數"),
                        description: localized("搜索/缓存/下载等网络请求并发数，建议8个"),
                        value: $settings.searchConcurrency,
                        range: 1...30
                    )
                    stepperRow(
                        title: localized("自動暫停"),
                        description: localized("每搜索到N个精確結果(或5N個模糊結果)後自動暫停(0不暫停)，防止設備發燙和流量消耗過多"),
                        value: $settings.searchAutoPauseCount,
                        range: 0...50
                    )
                    stepperRow(
                        title: localized("搜索結果快取天數"),
                        description: localized("搜索時啟用快取，避免重複搜索，預設快取 5 日"),
                        value: $settings.searchCacheDays,
                        range: 0...30
                    )
                }
            }
            .navigationTitle(localized("網路設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    /// A settings row with a title, the current value, a native stepper, and a
    /// description. The value is shown next to the stepper (the stepper's own
    /// label stays hidden), and the stepper keeps its native appearance so the
    /// −/+ control blends into the grouped background.
    @ViewBuilder
    private func stepperRow(
        title: String,
        description: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(DSFont.body)
                    .foregroundColor(DSColor.textPrimary)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(DSFont.bodyBold)
                    .monospacedDigit()
                    .foregroundColor(DSColor.textSecondary)
                Stepper("", value: value, in: range)
                    .labelsHidden()
                    .fixedSize()
            }
            Text(description)
                .font(DSFont.caption)
                .foregroundColor(DSColor.textSecondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NetworkSettingsView()
}
