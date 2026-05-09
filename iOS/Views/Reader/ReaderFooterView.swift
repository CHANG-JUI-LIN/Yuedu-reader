import SwiftUI
import Combine

// MARK: - Clock + Battery ViewModel (independent invalidation boundary)
//
// Extracts displayTime / displayBatteryIcon out of ReaderView's @State
// to prevent the entire 1500+ line body from recomputing on every minute / battery event.

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

// MARK: - Bottom Overlay Footer (slide / cover / tab modes)

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

// MARK: - Inline Footer (curl mode: baked into page texture)

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

// MARK: - Previews

#if DEBUG
private struct FooterPreview: View {
    @State private var bottomInset: CGFloat = 20
    @State private var footerVisualPadding: CGFloat = -14
    @State private var footerHeight: CGFloat = 16
    @State private var footerBottomGap: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            // Simulated page content
            ZStack {
                Color(.systemGray6)
                VStack(spacing: 0) {
                    Text("第 42 頁")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.top, 20)
                    Text("這是一段模擬的正文內容。")
                        .foregroundColor(.primary)
                        .padding(.top, 8)
                    Spacer()
                }
            }

            // Footer overlay
            ZStack(alignment: .bottom) {
                Color(.systemGray6)
                ReaderOverlayFooter(
                    pageInfo: "42 / 156",
                    progress: "26.9%",
                    textColor: .primary,
                    bottomInset: bottomInset
                )
            }
            .frame(height: max(40, bottomInset + footerHeight + 4))

            Divider()

            // Controls
            VStack(alignment: .leading, spacing: 8) {
                Text("Footer 參數").font(.headline).padding(.top, 8)

                HStack {
                    Text("bottomInset: \(Int(bottomInset))")
                    Slider(value: $bottomInset, in: 0...60, step: 2)
                }
                HStack {
                    Text("footerVisualPadding: \(Int(footerVisualPadding))")
                    Slider(value: $footerVisualPadding, in: -30...10, step: 1)
                }
                HStack {
                    Text("footerHeight: \(Int(footerHeight))")
                    Slider(value: $footerHeight, in: 8...32, step: 2)
                }
                HStack {
                    Text("footerBottomGap: \(Int(footerBottomGap))")
                    Slider(value: $footerBottomGap, in: 0...20, step: 1)
                }

                Text("即時預覽上面 footer 位置").font(.caption).foregroundColor(.secondary)
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
