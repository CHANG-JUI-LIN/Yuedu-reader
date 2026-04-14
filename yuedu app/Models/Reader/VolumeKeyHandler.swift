import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - 音量鍵翻頁

/// 攔截硬體音量鍵，轉換為翻頁指令
/// 使用 MPVolumeView 隱藏系統音量 HUD + KVO 監聽 outputVolume 變化
final class VolumeKeyHandler: NSObject, ObservableObject {

    enum PageDirection { case prev, next }

    /// 翻頁回調
    var onPageTurn: ((PageDirection) -> Void)?

    /// 是否啟用音量翻頁
    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled { startListening() } else { stopListening() }
            UserDefaults.standard.set(isEnabled, forKey: "yd_volume_page")
        }
    }

    // 內部狀態
    private var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    private let audioSession = AVAudioSession.sharedInstance()
    private var previousVolume: Float = 0.5
    private var isAdjusting = false  // 防止自己復原音量時觸發循環

    override init() {
        super.init()
        isEnabled = UserDefaults.standard.bool(forKey: "yd_volume_page")
    }

    deinit { stopListening() }

    // MARK: - 開始監聽

    func startListening() {
        guard observation == nil else { return }

        // 啟用音頻會話（監聽才生效）
        try? audioSession.setActive(true)
        previousVolume = audioSession.outputVolume

        // 隱藏系統音量 HUD：放一個 MPVolumeView 到畫面外
        if volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            view.alpha = 0.001  // 不能完全為 0，否則系統忽略
            if let windowScene = UIApplication.shared.connectedScenes.first(where: {
                $0.activationState == .foregroundActive
            }) as? UIWindowScene,
                let window = windowScene.windows.first(where: { $0.isKeyWindow })
            {
                window.addSubview(view)
            }
            volumeView = view
        }

        // KVO 監聽 outputVolume 變化
        observation = audioSession.observe(\.outputVolume, options: [.new]) {
            [weak self] _, change in
            guard let self = self, !self.isAdjusting,
                let newValue = change.newValue
            else { return }

            let diff = newValue - self.previousVolume
            if abs(diff) < 0.01 { return }  // 忽略微量浮點誤差

            DispatchQueue.main.async {
                if diff > 0 {
                    self.onPageTurn?(.prev)  // 音量+ → 上一頁
                } else {
                    self.onPageTurn?(.next)  // 音量- → 下一頁
                }
                // 將音量靜默恢復，讓連續按壓能持續觸發
                self.restoreVolume()
            }
        }
    }

    func stopListening() {
        observation?.invalidate()
        observation = nil
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    // MARK: - 靜默恢復音量

    private func restoreVolume() {
        isAdjusting = true
        // 找到 MPVolumeView 中的 UISlider 來設置音量
        if let slider = volumeView?.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.value = previousVolume
        }
        // 等一小段時間再解鎖，避免 KVO 回調
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isAdjusting = false
        }
    }
}
