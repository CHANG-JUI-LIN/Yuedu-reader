import SwiftUI

struct FontSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var capabilities: ReaderCapabilities = .reflowableText
    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.presentationMode) var presentationMode

    private func syncBrightnessFromSystem() {
        settings.readerBrightness = Double(UIScreen.main.brightness)
    }

    private var supportsFontSize: Bool { capabilities.contains(.fontSize) }
    private var supportsLineHeight: Bool { capabilities.contains(.lineHeight) }
    private var supportsSpacing: Bool { capabilities.contains(.spacing) }
    private var supportsBackground: Bool {
        capabilities.contains(.background) || capabilities.contains(.darkMode)
    }

    var body: some View {
        NavigationView {
            Form {
                // 字體大小
                if supportsFontSize {
                    Section(header: Text(gs.t("字體大小"))) {
                        HStack {
                            Text("A").font(DSFont.caption)
                            Slider(value: $fontSize, in: 12...30, step: 1)
                            Text("A").font(.title2)
                        }
                        Text("\(gs.t("目前"))：\(Int(fontSize)) pt")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // 行距
                if supportsSpacing {
                    Section(header: Text(gs.t("行距"))) {
                        HStack {
                            Image(systemName: "text.alignleft").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.lineHeightMultiple, in: 1.0...2.4, step: 0.05)
                            Image(systemName: "text.alignleft").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.4)
                        }
                        Text(
                            "\(gs.t("目前"))：\(String(format: "%.2f", readerConfig.lineHeightMultiple))x · \(Int(readerConfig.lineSpacing)) pt"
                        )
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // 字距
                if supportsSpacing {
                    Section(header: Text(gs.t("字距"))) {
                        HStack {
                            Image(systemName: "character").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.letterSpacing, in: 0...12, step: 0.5)
                            Image(systemName: "character").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.4)
                        }
                        Text("\(gs.t("目前"))：\(String(format: "%.1f", readerConfig.letterSpacing)) pt")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // 段距
                if supportsSpacing {
                    Section(header: Text(gs.t("段落間距"))) {
                        HStack {
                            Image(systemName: "text.justify").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.paragraphSpacingMultiplier, in: 0.3...1.2, step: 0.05)
                            Image(systemName: "text.justify").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.2)
                        }
                        Text(
                            "\(gs.t("目前"))：\(String(format: "%.2f", readerConfig.paragraphSpacingMultiplier))x · \(Int(readerConfig.paragraphSpacing)) pt"
                        )
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // 頁面留白
                if supportsLineHeight {
                    Section(header: Text(gs.t("頁面留白"))) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(gs.t("左右")).font(DSFont.caption).foregroundColor(DSColor.textSecondary).frame(width: 30)
                                Slider(value: $readerConfig.pageMarginH, in: 8...48, step: 2)
                                Text("\(Int(readerConfig.pageMarginH))").font(DSFont.caption).foregroundColor(DSColor.textSecondary).frame(width: 24)
                            }
                        }
                        Text(gs.t("上下留白與 footer 距離由系統自動控制"))
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // 閱讀亮度
                Section(
                    header: Text(gs.t("閱讀亮度")),
                    footer: Text(gs.t("退出閱讀器後自動恢復原始亮度"))
                ) {
                    HStack {
                        Image(systemName: "sun.min").foregroundColor(DSColor.textSecondary)
                        Slider(value: $settings.readerBrightness, in: 0.05...1.0, step: 0.05)
                            .disabled(settings.followSystemBrightness)
                            .onChange(of: settings.readerBrightness) { val in
                                if !settings.followSystemBrightness {
                                    UIScreen.main.brightness = CGFloat(val)
                                }
                            }
                        Image(systemName: "sun.max").foregroundColor(DSColor.textSecondary)
                    }
                    Button {
                        settings.followSystemBrightness.toggle()
                        if settings.followSystemBrightness {
                            syncBrightnessFromSystem()
                        } else {
                            UIScreen.main.brightness = CGFloat(settings.readerBrightness)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(
                                systemName: settings.followSystemBrightness
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            Text(gs.t("跟隨系統亮度"))
                            Spacer()
                            if settings.followSystemBrightness {
                                Text(gs.t("已開啟"))
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Text("\(gs.t("目前"))：\(Int(settings.readerBrightness * 100))%")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }

                // 滾動模式
                if supportsLineHeight {
                    Section(
                        header: Text(gs.t("閱讀模式")),
                        footer: Text(gs.t(settings.scrollMode ? "上下滾動，連續閱讀" : "左右翻頁，按頁左右切換"))
                    ) {
                        Picker(gs.t("閱讀模式"), selection: $settings.scrollMode) {
                            Text(gs.t("左右翻頁")).tag(false)
                            Text(gs.t("上下滾動")).tag(true)
                        }
                        .pickerStyle(.menu)
                    }
                }

                // 翻頁動畫（僅左右翻頁時有效）
                if !settings.scrollMode && supportsLineHeight {
                    Section(
                        header: Text(gs.t("翻頁動畫")),
                        footer: Text(gs.t("滑動：左右平移；覆蓋翻頁：新頁滑入蓋住舊頁（Legado）；仿真翻書：捲曲效果；無動畫：立即切換"))
                    ) {
                        Picker(gs.t("動畫樣式"), selection: $settings.pageTurnStyle) {
                            ForEach(PageTurnStyle.allCases, id: \.self) { style in
                                Text(gs.t(style.rawValue)).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                // 文字轉換
                Section(header: Text(gs.t("文字轉換"))) {
                    Picker(gs.t("轉換模式"), selection: $settings.textConversion) {
                        ForEach(TextConversion.allCases, id: \.self) { mode in
                            Text(gs.t(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(gs.t("簡↔繁轉換離線完成，永久生效"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }

                // 背景主題
                if supportsBackground {
                    Section(header: Text(gs.t("背景主題"))) {
                        ForEach(ReaderTheme.allCases, id: \.self) { t in
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) { theme = t }
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(t.backgroundColor)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                                        )
                                    Text(gs.t(t.rawValue))
                                        .foregroundColor(DSColor.textPrimary)
                                    Spacer()
                                    if theme == t {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(DSColor.accent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: theme)
            .navigationTitle(gs.t("閱讀設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("完成")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification))
        { _ in
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
    }
}
