import Combine
import SwiftUI
import UniformTypeIdentifiers

struct FontSettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var theme: ReaderTheme
    var capabilities: ReaderCapabilities = .reflowableText
    var allowsUserSelectedReaderFont = false
    var allowsVerticalWritingMode = false
    @StateObject private var readerConfig = ReaderConfig.shared
    @ObservedObject private var settings = GlobalSettings.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showingFontImporter = false
    @State private var fontImportError: FontImportError?
    @Environment(\.presentationMode) var presentationMode

    private func syncBrightnessFromSystem() {
        settings.readerBrightness = Double(UIScreen.main.brightness)
    }

    private var supportsFontSize: Bool { capabilities.contains(.fontSize) }
    private var supportsUserFont: Bool {
        supportsFontSize && allowsUserSelectedReaderFont
    }
    private var supportsLineHeight: Bool { capabilities.contains(.lineHeight) }
    private var supportsSpacing: Bool { capabilities.contains(.spacing) }
    private var supportsBackground: Bool {
        capabilities.contains(.background) || capabilities.contains(.darkMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsUserFont {
                    Section(header: Text(localized("字體"))) {
                        Picker(
                            localized("字體"),
                            selection: Binding(
                                get: { settings.selectedReaderFontPostScript ?? "" },
                                set: { value in
                                    settings.selectedReaderFontPostScript = value.isEmpty ? nil : value
                                    readerConfig.refresh.send(.layout)
                                }
                            )
                        ) {
                            Text(localized("系統字體")).tag("")
                            ForEach(settings.userFonts) { font in
                                Text(font.displayName).tag(font.postScriptName)
                            }
                        }
                        .pickerStyle(.menu)

                        Button {
                            showingFontImporter = true
                        } label: {
                            Label(localized("匯入字體..."), systemImage: "plus")
                        }

                        ForEach(settings.userFonts) { font in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(font.displayName)
                                Text(font.postScriptName)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    settings.deleteReaderFont(font)
                                    readerConfig.refresh.send(.layout)
                                } label: {
                                    Label(localized("刪除"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                // MARK: - Font Size

                if supportsFontSize {
                    Section(header: Text(localized("字體大小"))) {
                        HStack {
                            Text("A").font(DSFont.caption)
                            Slider(value: $fontSize, in: 12...30, step: 1)
                            Text("A").font(.title2)
                        }
                        Text("\(localized("目前"))：\(Int(fontSize)) pt")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // MARK: - Line Spacing

                if supportsSpacing {
                    Section(header: Text(localized("行距"))) {
                        HStack {
                            Image(systemName: "text.alignleft").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.lineHeightMultiple, in: 1.0...2.4, step: 0.05)
                            Image(systemName: "text.alignleft").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.4)
                        }
                        Text(
                            "\(localized("目前"))：\(String(format: "%.2f", readerConfig.lineHeightMultiple))x · \(Int(readerConfig.lineSpacing)) pt"
                        )
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // MARK: - Letter Spacing

                if supportsSpacing {
                    Section(header: Text(localized("字距"))) {
                        HStack {
                            Image(systemName: "character").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.letterSpacing, in: 0...12, step: 0.5)
                            Image(systemName: "character").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.4)
                        }
                        Text("\(localized("目前"))：\(String(format: "%.1f", readerConfig.letterSpacing)) pt")
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // MARK: - Paragraph Spacing

                if supportsSpacing {
                    Section(header: Text(localized("段落間距"))) {
                        HStack {
                            Image(systemName: "text.justify").foregroundColor(DSColor.textSecondary)
                            Slider(value: $readerConfig.paragraphSpacingMultiplier, in: 0.3...1.2, step: 0.05)
                            Image(systemName: "text.justify").foregroundColor(DSColor.textSecondary)
                                .scaleEffect(1.2)
                        }
                        Text(
                            "\(localized("目前"))：\(String(format: "%.2f", readerConfig.paragraphSpacingMultiplier))x · \(Int(readerConfig.paragraphSpacing)) pt"
                        )
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                }

                // MARK: - Page Margins

                if supportsLineHeight {
                    Section(header: Text(localized("頁面留白"))) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(localized("左右")).font(DSFont.caption).foregroundColor(DSColor.textSecondary).frame(width: 30)
                                Slider(value: $readerConfig.pageMarginH, in: 8...48, step: 2)
                                Text("\(Int(readerConfig.pageMarginH))").font(DSFont.caption).foregroundColor(DSColor.textSecondary).frame(width: 24)
                            }
                        }
                    }
                }

                // MARK: - Reading Brightness

                Section(
                    header: Text(localized("閱讀亮度")),
                    footer: Text(localized("退出閱讀器後自動恢復原始亮度"))
                ) {
                    HStack {
                        Image(systemName: "sun.min").foregroundColor(DSColor.textSecondary)
                        Slider(value: $settings.readerBrightness, in: 0.05...1.0, step: 0.05)
                            .disabled(settings.followSystemBrightness)
                            .onChange(of: settings.readerBrightness) { _, val in
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
                            Text(localized("跟隨系統亮度"))
                            Spacer()
                            if settings.followSystemBrightness {
                                Text(localized("已開啟"))
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Text("\(localized("目前"))：\(Int(settings.readerBrightness * 100))%")
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }

                // MARK: - Scroll Mode

                if supportsLineHeight {
                    let verticalScroll = settings.readerWritingMode.isVertical
                    Section(
                        header: Text(localized("閱讀模式")),
                        footer: Text(localized(settings.scrollMode
                            ? (verticalScroll ? "右往左連續閱讀" : "上下滾動，連續閱讀")
                            : "左右翻頁，按頁左右切換"))
                    ) {
                        Picker(
                            localized("閱讀模式"),
                            selection: Binding(
                                get: { settings.scrollMode },
                                set: { scrollMode in
                                    settings.scrollMode = scrollMode
                                    readerConfig.refresh.send(.layout)
                                }
                            )
                        ) {
                            Text(localized("左右翻頁")).tag(false)
                            Text(localized(verticalScroll ? "右往左連續" : "上下滾動")).tag(true)
                        }
                        .pickerStyle(.menu)
                    }
                }

                if supportsLineHeight && allowsVerticalWritingMode {
                    Section(
                        header: Text(localized("排版方向")),
                        footer: Text(localized(settings.readerWritingMode.isVertical ? "直排支援左右翻頁與右往左連續閱讀" : "橫排支援翻頁與滾動"))
                    ) {
                        Picker(
                            localized("排版方向"),
                            selection: Binding(
                                get: { settings.readerWritingMode },
                                set: { mode in
                                    settings.readerWritingMode = mode
                                    readerConfig.refresh.send(.layout)
                                }
                            )
                        ) {
                            Text(localized("橫排")).tag(ReaderWritingMode.horizontal)
                            Text(localized("直排")).tag(ReaderWritingMode.verticalRTL)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // Page-turn animation (only for horizontal paged mode)
                if !settings.scrollMode && supportsLineHeight {
                    Section(header: Text(localized("翻頁動畫"))) {
                        Picker(localized("動畫樣式"), selection: $settings.pageTurnStyle) {
                            ForEach(PageTurnStyle.allCases, id: \.self) { style in
                                Text(localized(style.rawValue)).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                // MARK: - Text Conversion

                Section(header: Text(localized("文字轉換"))) {
                    Picker(localized("轉換模式"), selection: $settings.textConversion) {
                        ForEach(TextConversion.allCases, id: \.self) { mode in
                            Text(localized(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(localized("簡↔繁轉換離線完成，永久生效"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }

                // MARK: - Background Theme

                if supportsBackground {
                    Section(header: Text(localized("背景主題"))) {
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
                                    Text(localized(t.rawValue))
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
            .navigationTitle(localized("閱讀設定"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                }
            }
        }
        .onAppear {
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
        .fileImporter(
            isPresented: $showingFontImporter,
            allowedContentTypes: Self.fontContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFontImport(result)
        }
        .alert(item: $fontImportError) { error in
            Alert(
                title: Text(localized("字體匯入失敗")),
                message: Text(error.message),
                dismissButton: .default(Text(localized("確定")))
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification))
        { _ in
            if settings.followSystemBrightness {
                syncBrightnessFromSystem()
            }
        }
    }

    private static let fontContentTypes: [UTType] = [
        .font,
        UTType(filenameExtension: "ttf") ?? .data,
        UTType(filenameExtension: "otf") ?? .data,
    ]

    private func handleFontImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try settings.importReaderFont(from: url)
            readerConfig.refresh.send(.layout)
        } catch {
            fontImportError = FontImportError(message: error.localizedDescription)
        }
    }
}

private struct FontImportError: Identifiable {
    let id = UUID()
    let message: String
}
