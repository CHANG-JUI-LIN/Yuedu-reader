import SwiftUI
import Combine

// MARK: - Clock + Battery ViewModel

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

    private func refreshTime() { displayTime = formatter.string(from: Date()) }

    private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        switch UIDevice.current.batteryState {
        case .charging, .full: batteryIcon = "battery.100.bolt"
        default:
            if level > 0.75 { batteryIcon = "battery.100" }
            else if level > 0.5 { batteryIcon = "battery.75" }
            else if level > 0.25 { batteryIcon = "battery.50" }
            else { batteryIcon = "battery.25" }
        }
    }
}

// MARK: - Bottom Overlay Footer

struct ReaderOverlayFooter: View {
    let pageInfo: String
    let progress: String
    let textColor: Color
    let footerPadding: CGFloat
    let horizontalPadding: CGFloat
    @StateObject private var clock = ClockBatteryModel()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("\(pageInfo)  ·  \(progress)")
                    .font(DSFont.fixed(size: 10).monospacedDigit())
                    .foregroundColor(textColor.opacity(0.4))
                Spacer()
                HStack(spacing: 4) {
                    Text(clock.displayTime).font(DSFont.fixed(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(DSFont.fixed(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, footerPadding)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Inline Footer

struct ReaderInlineFooter: View {
    let pageInfo: String
    let progress: String
    let textColor: Color
    let footerPadding: CGFloat
    let horizontalPadding: CGFloat
    @StateObject private var clock = ClockBatteryModel()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text("\(pageInfo)  ·  \(progress)")
                    .font(DSFont.fixed(size: 10).monospacedDigit())
                    .foregroundColor(textColor.opacity(0.4))
                Spacer()
                HStack(spacing: 4) {
                    Text(clock.displayTime).font(DSFont.fixed(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(DSFont.fixed(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, footerPadding)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: localized("第 %@ 頁，進度 %@，%@"), "\(pageInfo)", "\(progress)", clock.displayTime))
    }
}
