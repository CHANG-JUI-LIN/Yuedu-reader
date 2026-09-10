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

// `ReaderOverlayFooter` and `ReaderInlineFooter` lived here — two structs with
// byte-identical bodies, neither of them called any more. `ReaderBarRenderer`
// draws both bars now. `ClockBatteryModel` above stays: it is what makes the
// bars tick, and the 頁首頁尾 editor's preview uses it too.
