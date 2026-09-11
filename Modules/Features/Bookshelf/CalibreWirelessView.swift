import SwiftUI

/// Pushed inside the existing Calibre library navigation stack. Starting
/// discovery is explicit so local-network permission is requested in context.
struct CalibreWirelessView: View {
    @ObservedObject var store: BookStore
    @ObservedObject var service: CalibreWirelessService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("calibreWirelessHost") private var host = ""
    @AppStorage("calibreWirelessPort") private var port = "9090"
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                statusRow
                if service.state.isActive {
                    Button(localized("中斷連線"), role: .destructive) { service.disconnect() }
                }
            } header: {
                Text(localized("連線狀態"))
            } footer: {
                Text(localized("在電腦 Calibre 的「連線／分享」選單啟動無線裝置連線，再於此頁連接電腦。連線成功後，可在電腦選取書籍並按「傳送至裝置」。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if !service.state.isActive {
                Section {
                    SecureField(localized("無線裝置密碼（選填）"), text: $password)
                        .textContentType(.password)
                } footer: {
                    Text(localized("輸入 Calibre 無線裝置設定的密碼，僅供本次連線使用。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()

                Section {
                    ForEach(service.servers) { server in
                        Button {
                            service.connect(server: server, password: password, store: store)
                        } label: {
                            Label(server.name, systemImage: "desktopcomputer")
                        }
                    }
                    if service.isDiscovering && service.servers.isEmpty {
                        ProgressView(localized("正在搜尋附近的 Calibre…"))
                    }
                    if let error = service.discoveryError {
                        Text(error).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
                        Button(localized("開啟系統設定")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    Button(service.isDiscovering ? localized("停止搜尋") : localized("搜尋附近電腦")) {
                        if service.isDiscovering { service.stopDiscovery() }
                        else { service.startDiscovery() }
                    }
                } header: {
                    Text(localized("附近的 Calibre"))
                } footer: {
                    Text(localized("電腦與此裝置須連接同一區域網路，並允許悅讀存取本機網路。找不到電腦時，可在下方手動輸入位址。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()

                Section(localized("手動連線")) {
                    TextField(localized("電腦 IP 或主機名稱"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField(localized("連接埠"), text: $port)
                        .keyboardType(.numberPad)
                    Button(localized("連線")) {
                        service.connect(host: host, port: UInt16(port) ?? 0, password: password, store: store)
                    }
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (UInt16(port) ?? 0) == 0)
                }
                .interfaceSectionSurface()
            }

            Section {
                if service.transfers.isEmpty {
                    Text(localized("尚未接收書籍"))
                        .foregroundStyle(DSColor.textSecondary)
                } else {
                    ForEach(service.transfers.reversed()) { transfer in
                        transferRow(transfer)
                    }
                }
            } header: {
                Text(localized("接收紀錄"))
            } footer: {
                Text(localized("支援 EPUB、PDF、TXT 與 Markdown。傳送期間請保持此頁開啟；接收並匯入成功後，書籍會加入書架供離線閱讀。離開此頁或切至背景會中斷連線。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("電腦傳書"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .onDisappear {
            service.stopDiscovery()
            service.disconnect()
            password = ""
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background {
                service.stopDiscovery()
                service.disconnect()
                password = ""
            }
        }
        .onChange(of: service.transfers) { previous, current in
            if let completed = current.last(where: { entry in
                entry.phase == .completed && previous.first(where: { $0.id == entry.id })?.phase != .completed
            }) {
                UIAccessibility.post(notification: .announcement, argument: completed.title + "，" + localized("已加入書架"))
            }
        }
        .onChange(of: service.state) { _, current in
            switch current {
            case .connected(let name):
                UIAccessibility.post(notification: .announcement, argument: localized("已連線") + "，" + name)
            case .failed(let message):
                UIAccessibility.post(notification: .announcement, argument: message)
            default: break
            }
        }
        .onChange(of: service.discoveryError) { _, message in
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch service.state {
        case .disconnected:
            Label(localized("尚未連線"), systemImage: "network")
        case .connecting:
            ProgressView(localized("正在連接 Calibre…"))
        case .connected(let name):
            LabeledContent(localized("已連線"), value: name)
        case .failed(let message):
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Label(localized("連線失敗"), systemImage: "exclamationmark.triangle")
                Text(message).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            }
        }
    }

    private func transferRow(_ transfer: CalibreTransferStatus) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(transfer.title).font(DSFont.body)
            switch transfer.phase {
            case .receiving:
                ProgressView(value: Double(transfer.receivedBytes), total: Double(transfer.totalBytes)) {
                    Text(localized("正在接收"))
                } currentValueLabel: {
                    Text(byteProgress(transfer))
                }
                .accessibilityValue(byteProgress(transfer))
            case .importing:
                ProgressView(localized("正在匯入書架…"))
            case .completed:
                Label(localized("已加入書架"), systemImage: "checkmark.circle")
                    .font(DSFont.footnote)
            case .failed(let message):
                Text(message).font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            case .cancelled:
                Text(localized("已取消接收"))
                    .font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            }
        }
    }

    private func byteProgress(_ transfer: CalibreTransferStatus) -> String {
        let received = ByteCountFormatter.string(fromByteCount: transfer.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
        return "\(received) / \(total)"
    }
}

#Preview {
    NavigationStack {
        CalibreWirelessView(store: BookStore(), service: CalibreWirelessService())
    }
}
