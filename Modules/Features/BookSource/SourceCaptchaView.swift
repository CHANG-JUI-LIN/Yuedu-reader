import SwiftUI

/// The captcha a source asks for with `java.getVerificationCode(imageUrl)` — Legado's
/// `VerificationCodeDialog`, the same in Legado-E and MD3: the image, a field for the code
/// and ✓, plus 停用／刪除 for a source that keeps asking.
struct SourceCaptchaView: View {
    let request: SourceCaptchaRequest
    let onFinish: (_ code: String?) -> Void

    @State private var image: UIImage?
    @State private var loadState = LoadState.loading
    @State private var code = ""
    @State private var confirmsDelete = false
    @FocusState private var fieldFocused: Bool

    private enum LoadState { case loading, loaded, failed }

    /// Wide enough to rasterize an SVG code crisply; the view scales it to fit.
    private static let renderWidth: CGFloat = 320

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    captchaImage
                    TextField(localized("驗證碼"), text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                } header: {
                    if !request.sourceName.isEmpty {
                        Text(request.sourceName)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                if sourceID != nil {
                    Section {
                        Button(localized("停用來源配置"), action: disableSource)
                        Button(localized("刪除來源配置"), role: .destructive) {
                            confirmsDelete = true
                        }
                    }
                }
            }
            .softScrollEdges()
            .navigationTitle(localized("輸入驗證碼"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onFinish(nil)
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: submit) {
                        Label(localized("完成"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("完成"))
                    .disabled(trimmedCode.isEmpty)
                }
            }
            .confirmationDialog(
                String(format: localized("確定要刪除來源配置「%@」嗎？"), request.sourceName),
                isPresented: $confirmsDelete,
                titleVisibility: .visible
            ) {
                Button(localized("刪除"), role: .destructive, action: deleteSource)
            }
        }
        .task { await loadImage() }
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private var captchaImage: some View {
        switch loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget * 2)
        case .loaded:
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: DSLayout.minimumTapTarget * 3)
                    .accessibilityLabel(localized("驗證碼圖片"))
            }
        case .failed:
            VStack(spacing: DSSpacing.sm) {
                Text(localized("載入失敗"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                Button(localized("重新載入")) {
                    Task { await loadImage() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget * 2)
        }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceID: UUID? {
        guard !request.sourceURL.isEmpty else { return nil }
        return BookSourceStore.shared.sources.first { $0.bookSourceUrl == request.sourceURL }?.id
    }

    private func loadImage() async {
        loadState = .loading
        image = await OnlineImageLoader.load(
            src: request.imageURL,
            renderWidth: Self.renderWidth,
            headers: request.headers,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        loadState = image == nil ? .failed : .loaded
    }

    private func submit() {
        guard !trimmedCode.isEmpty else { return }
        onFinish(trimmedCode)
    }

    /// Legado's 禁用源: the source stops being used, and the waiting script gets no code.
    private func disableSource() {
        if let sourceID {
            BookSourceStore.shared.setEnabledByUser(ids: [sourceID], enabled: false)
        }
        onFinish(nil)
    }

    private func deleteSource() {
        if let sourceID {
            _ = BookSourceStore.shared.delete(ids: [sourceID])
        }
        onFinish(nil)
    }
}

#Preview("輸入驗證碼") {
    let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="40">\
        <rect width="120" height="40" fill="#eeeeee"/>\
        <text x="18" y="28" font-size="24" font-family="Menlo" fill="#333333">7K3Q</text></svg>
        """
    return SourceCaptchaView(
        request: SourceCaptchaRequest(
            imageURL: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString(),
            headers: [:],
            sourceName: "示例來源配置",
            sourceURL: ""
        ),
        onFinish: { _ in }
    )
}
