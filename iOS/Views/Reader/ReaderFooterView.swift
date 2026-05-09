import SwiftUI
import Combine

// MARK: - 時鐘 + 電池 ViewModel（獨立 invalidation 邊界）
//
// 把 displayTime / displayBatteryIcon 從 ReaderView 的 @State 移出，
// 避免每分鐘 / 每次電量事件觸發整個 1500 行 body 的重新計算。

@MainActor
final class ClockBatteryModel: ObservableObject {
    @Published private(set) var displayTime: String = ""
    @Published private(set) var batteryIcon: String = "battery.100"

    private var timerCancellable: AnyCancellable?
    private var batteryLevelCancellable: AnyCancellable?
    private var batteryStateCancellable: AnyCancellable?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshTime()
        refreshBattery()

        timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshTime() }

        batteryLevelCancellable = NotificationCenter.default
            .publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in self?.refreshBattery() }

        batteryStateCancellable = NotificationCenter.default
            .publisher(for: UIDevice.batteryStateDidChangeNotification)
            .sink { [weak self] _ in self?.refreshBattery() }
    }

    private func refreshTime() {
        displayTime = formatter.string(from: Date())
    }

    private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        switch UIDevice.current.batteryState {
        case .charging, .full:
            batteryIcon = "battery.100.bolt"
        default:
            if level > 0.75 {
                batteryIcon = "battery.100"
            } else if level > 0.5 {
                batteryIcon = "battery.75"
            } else if level > 0.25 {
                batteryIcon = "battery.50"
            } else {
                batteryIcon = "battery.25"
            }
        }
    }
}

// MARK: - 底部 Overlay Footer（slide / cover / tab 模式）

struct ReaderOverlayFooter: View {
    let pageInfo: String
    let progress: String
    let textColor: Color
    let bottomInset: CGFloat
    @StateObject private var clock = ClockBatteryModel()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("\(pageInfo)  ·  \(progress)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(textColor.opacity(0.4))
                Spacer()
                HStack(spacing: 4) {
                    Text(clock.displayTime).font(.system(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(.system(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, bottomInset + ReaderLayoutMetrics.footerVisualBottomPadding)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 頁內 Footer（curl 模式：烘進頁面紋理）

struct ReaderInlineFooter: View {
    let pageInfo: String
    let progress: String
    let textColor: Color
    let bottomInset: CGFloat
    @StateObject private var clock = ClockBatteryModel()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("\(pageInfo)  ·  \(progress)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(textColor.opacity(0.4))
                Spacer()
                HStack(spacing: 4) {
                    Text(clock.displayTime).font(.system(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(.system(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, bottomInset + ReaderLayoutMetrics.footerVisualBottomPadding)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(pageInfo)頁，進度\(progress)，\(clock.displayTime)")
    }
}
