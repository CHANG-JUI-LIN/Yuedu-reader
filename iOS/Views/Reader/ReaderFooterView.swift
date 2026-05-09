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
            .padding(.bottom, footerPadding)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(pageInfo)頁，進度\(progress)，\(clock.displayTime)")
    }
}

// MARK: - Previews

#if DEBUG
private struct FooterPreview: View {
    @State private var contentBottomInset: CGFloat = 20
    @State private var footerPadding: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color(.systemGray6)
                VStack {
                    Text("第 42 頁").font(.system(size: 14)).foregroundColor(.secondary)
                    Text("正文最後一行").foregroundColor(.primary)
                }
                .padding(.bottom, contentBottomInset)
            }

            ZStack(alignment: .bottom) {
                Color(.systemGray5)
                Rectangle().frame(height: 1).foregroundColor(.red.opacity(0.5))

                ReaderOverlayFooter(
                    pageInfo: "42 / 156",
                    progress: "26.9%",
                    textColor: .white,
                    footerPadding: footerPadding
                )
            }
            .frame(height: max(30, contentBottomInset + 4))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("參數").font(.headline).padding(.top, 8)

                HStack {
                    Text("文字底部留白: \(Int(contentBottomInset))pt")
                    Slider(value: $contentBottomInset, in: 0...80, step: 2)
                }
                HStack {
                    Text("footer 離底: \(Int(footerPadding))pt")
                    Slider(value: $footerPadding, in: 0...40, step: 1)
                }

                Text("紅線 = 排版區域底部").font(.caption).foregroundColor(.red.opacity(0.5))
                Text("contentInsets.bottom = safeBottom + 16(footerHeight) + footerPadding").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Footer Position Tester") {
    FooterPreview()
}
#endif
