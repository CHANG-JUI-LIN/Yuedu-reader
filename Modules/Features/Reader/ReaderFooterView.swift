import SwiftUI
import Combine

// MARK: - Clock + Battery ViewModel

@MainActor
final class ClockBatteryModel: ObservableObject {
    @Published private(set) var displayTime: String = ""
    @Published private(set) var batteryIcon: String = "battery.100"
    @Published private(set) var now: Date = Date()
    @Published private(set) var batteryLevel: Double?
    @Published private(set) var isCharging = false

    private var clockTimer: Timer?
    private var batteryLevelCancellable: AnyCancellable?
    private var batteryStateCancellable: AnyCancellable?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.calendar = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshTime()
        refreshBattery()
        scheduleClockTimer()
        batteryLevelCancellable = NotificationCenter.default
            .publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in self?.refreshBattery() }
        batteryStateCancellable = NotificationCenter.default
            .publisher(for: UIDevice.batteryStateDidChangeNotification)
            .sink { [weak self] _ in self?.refreshBattery() }
    }

    deinit {
        clockTimer?.invalidate()
    }

    private func scheduleClockTimer() {
        let current = Date()
        let delay = ReaderClockSchedule.delayUntilNextMinute(from: current)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTime()
            }
        }
        timer.fireDate = current.addingTimeInterval(delay)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func refreshTime() {
        let current = Date()
        now = current
        displayTime = formatter.string(from: current)
    }

    private func refreshBattery() {
        let state = UIDevice.current.batteryState
        let value = ReaderBatteryValueResolver.resolve(
            rawLevel: Double(UIDevice.current.batteryLevel),
            isCharging: state == .charging || state == .full
        )
        batteryLevel = value.level
        isCharging = value.isCharging
        batteryIcon = value.iconName
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
                HStack(spacing: DSSpacing.xs) {
                    Text(clock.displayTime).font(DSFont.fixed(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(DSFont.fixed(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .frame(height: ReaderLayoutMetrics.footerHeight)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, footerPadding)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: localized("第 %@ 頁，進度 %@，%@"), "\(pageInfo)", "\(progress)", clock.displayTime))
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
                HStack(spacing: DSSpacing.xs) {
                    Text(clock.displayTime).font(DSFont.fixed(size: 10).monospacedDigit())
                    Image(systemName: clock.batteryIcon).font(DSFont.fixed(size: 10))
                }
                .foregroundColor(textColor.opacity(0.4))
            }
            .frame(height: ReaderLayoutMetrics.footerHeight)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, footerPadding)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: localized("第 %@ 頁，進度 %@，%@"), "\(pageInfo)", "\(progress)", clock.displayTime))
    }
}
