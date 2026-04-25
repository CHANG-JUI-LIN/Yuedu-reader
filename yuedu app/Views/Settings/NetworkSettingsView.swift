import SwiftUI

struct NetworkSettingsView: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localized("並發數"))
                            .font(.system(size: 16))
                        Spacer()
                        Stepper(value: $settings.searchConcurrency, in: 1...30, step: 1) {
                            Text("\(settings.searchConcurrency)")
                                .frame(minWidth: 30)
                                .multilineTextAlignment(.center)
                        }
                        .labelsHidden()
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                    }
                    Text(localized("搜索/缓存/下载等网络请求并发数，建议8个"))
                        .font(.system(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                }
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localized("自動暫停"))
                            .font(.system(size: 16))
                        Spacer()
                        Stepper(value: $settings.searchAutoPauseCount, in: 0...50, step: 1) {
                            Text("\(settings.searchAutoPauseCount)")
                                .frame(minWidth: 30)
                                .multilineTextAlignment(.center)
                        }
                        .labelsHidden()
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                    }
                    Text(localized("每搜索到N个精確結果(或5N個模糊結果)後自動暫停(0不暫停)，防止設備發燙和流量消耗過多"))
                        .font(.system(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                }
                .padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localized("搜索結果快取天數"))
                            .font(.system(size: 16))
                        Spacer()
                        Stepper(value: $settings.searchCacheDays, in: 0...30, step: 1) {
                            Text("\(settings.searchCacheDays)")
                                .frame(minWidth: 30)
                                .multilineTextAlignment(.center)
                        }
                        .labelsHidden()
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(8)
                    }
                    Text(localized("搜索時啟用快取，避免重複搜索，預設快取 5 日"))
                        .font(.system(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(localized("網路設定"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
