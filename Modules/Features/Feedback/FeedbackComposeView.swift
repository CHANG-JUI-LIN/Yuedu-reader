import PhotosUI
import SwiftUI
import UIKit

/// 回饋中心 › 回饋與改進: write a bug report or a suggestion, attach up to five images or
/// videos, and send it with the device facts and this launch's diagnostic log.
///
/// The log is also reachable without a report (僅上傳日誌) and as a file for another app
/// (在其他應用程式中開啟), the way round when Google's servers are unreachable from the
/// person's network. Pushed from 回饋中心, or presented as a sheet by the screenshot
/// prompt (`isSheet`), so `.inline` either way.
struct FeedbackComposeView: View {
    var isSheet = false
    @State private var model: FeedbackComposeModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var textFocused: Bool
    @State private var pickerItems: [PhotosPickerItem] = []

    init(isSheet: Bool = false, initialAttachments: [FeedbackDraftAttachment] = []) {
        self.isSheet = isSheet
        _model = State(initialValue: FeedbackComposeModel(attachments: initialAttachments))
    }

    var body: some View {
        Form {
            readinessSection
            descriptionSection
            attachmentSection
            deviceSection
            submitSection
            diagnosticsSection
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("回饋與改進"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("取消"))
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            model.addPicked(items)
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { alert in
            if case .logSent(let reportID) = alert {
                Button(localized("複製編號")) { UIPasteboard.general.string = reportID }
            }
            Button(localized("好"), role: .cancel) {
                if case .submitted = alert { dismiss() }
            }
        } message: { alert in
            Text(alert.message)
        }
        .task { model.prepare() }
        .onDisappear { model.discardUnsent() }
    }

    // MARK: - Sections

    private var readinessSection: some View {
        Section {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "list.clipboard")
                    .foregroundStyle(DSColor.textSecondary)
                    .accessibilityHidden(true)
                Text(model.diagnostics == nil ? localized("正在準備反饋數據…") : localized("反饋數據已準備就緒"))
                    .foregroundStyle(DSColor.textPrimary)
                Spacer(minLength: DSSpacing.sm)
                if model.diagnostics == nil {
                    ProgressView()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DSColor.success)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .interfaceSectionSurface()
    }

    private var descriptionSection: some View {
        Section {
            Picker(localized("類型"), selection: $model.kind) {
                ForEach(FeedbackKind.allCases) { kind in
                    Text(kind.localizedName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            TextField(model.kind.placeholder, text: $model.text, axis: .vertical)
                .lineLimit(6...14)
                .focused($textFocused)
                .accessibilityLabel(localized("問題描述"))
                .accessibilityIdentifier("feedback_compose_text")
        } header: {
            Text(localized("問題描述"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    private var attachmentSection: some View {
        Section {
            if !model.attachments.isEmpty || model.preparingCount > 0 {
                FeedbackDraftAttachmentStrip(
                    attachments: model.attachments,
                    preparingCount: model.preparingCount,
                    onRemove: model.remove
                )
            }
            if model.remainingSlots > 0 {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: model.remainingSlots,
                    matching: .any(of: [.images, .videos]),
                    preferredItemEncoding: .compatible
                ) {
                    Label(localized("新增圖片或影片"), systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("feedback_compose_add_media")
            }
        } header: {
            Text(String(format: localized("圖片或影片（可選，最多 %d 個）"), FeedbackFirestoreSchema.attachmentLimit))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }

    private var deviceSection: some View {
        Section {
            ForEach(model.deviceInfo.rows) { row in
                ThemedLabeledContent(row.title, value: row.value)
            }
        } header: {
            Text(localized("設備資訊"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("提交時會一併上傳以上資訊與這次啟動的診斷紀錄（含書名與來源配置網址，帳號、密碼與網址參數已移除）。"))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var submitSection: some View {
        Section {
            Button {
                textFocused = false
                model.submit()
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    if model.isWorking { ProgressView() }
                    Text(model.submitTitle)
                        .font(DSFont.bodyBold)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("feedback_compose_submit")

            if let diagnostics = model.diagnostics {
                ShareLink(
                    item: model.shareBundle(from: diagnostics),
                    preview: SharePreview(diagnostics.filename)
                ) {
                    Label(localized("在其他應用程式中開啟"), systemImage: "square.and.arrow.up")
                        .font(DSFont.bodyBold)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                model.uploadLogOnly()
            } label: {
                Text(localized("僅上傳日誌"))
                    .font(DSFont.bodyBold)
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.diagnostics == nil || model.isWorking)
        } header: {
            Text(localized("診斷"))
                .foregroundStyle(DSColor.textSecondary)
        }
        .interfaceSectionSurface()
    }
}

/// Picked attachments in a horizontal strip, each with a remove button.
struct FeedbackDraftAttachmentStrip: View {
    let attachments: [FeedbackDraftAttachment]
    var preparingCount = 0
    let onRemove: (FeedbackDraftAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(attachments) { attachment in
                    thumbnail(attachment)
                }
                ForEach(0..<preparingCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .fill(DSColor.surfaceTertiary)
                        .frame(width: DSLayout.feedbackThumbnailSide, height: DSLayout.feedbackThumbnailSide)
                        .overlay { ProgressView() }
                        .accessibilityLabel(localized("正在處理附件"))
                }
            }
            .padding(.vertical, DSSpacing.xs)
        }
    }

    private func thumbnail(_ attachment: FeedbackDraftAttachment) -> some View {
        Image(uiImage: attachment.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: DSLayout.feedbackThumbnailSide, height: DSLayout.feedbackThumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .accessibilityLabel(attachment.kind == .video ? localized("影片") : localized("圖片"))
            .overlay(alignment: .bottomLeading) {
                if attachment.kind == .video {
                    Image(systemName: "video.fill")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textOnAccent)
                        .padding(DSSpacing.xs)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    onRemove(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(DSColor.textOnAccent, DSColor.cardCarouselDim.opacity(DSLayout.feedbackRemoveButtonBackdropOpacity))
                        .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(attachment.kind == .video ? localized("移除影片") : localized("移除圖片"))
            }
            .accessibilityElement(children: .contain)
    }
}

// MARK: - Model

/// Owns the form's state. Sending goes through `FeedbackService`; the log snapshot is
/// decoded off the main thread, as `DiagnosticsViewModel` does.
@MainActor
@Observable
final class FeedbackComposeModel {
    enum Alert: Equatable {
        case submitted
        case logSent(String)
        case failed(String)

        var title: String {
            switch self {
            case .submitted: localized("已提交")
            case .logSent: localized("已傳送")
            case .failed: localized("傳送失敗")
            }
        }

        var message: String {
            switch self {
            case .submitted:
                localized("可以在「我的回饋」查看處理進度與回覆。")
            case .logSent(let reportID):
                String(format: localized("回報編號：%@。把這個編號告訴開發者，就能找到你的紀錄。"), reportID)
            case .failed(let reason):
                // Sending needs Google's servers, which some networks cannot reach; the
                // file does not, so it is offered as the way round.
                String(format: localized("%@\n可以改用「在其他應用程式中開啟」把紀錄分享給開發者。"), reason)
            }
        }
    }

    var kind: FeedbackKind = .bug
    var text = ""
    private(set) var attachments: [FeedbackDraftAttachment]
    private(set) var preparingCount = 0
    private(set) var diagnostics: DiagnosticReportBundle?
    private(set) var deviceInfo = FeedbackDeviceInfo(rows: [])
    private(set) var stage: FeedbackService.SubmitStage?
    private(set) var isUploadingLog = false
    var alert: Alert?
    private var didSubmit = false

    init(attachments: [FeedbackDraftAttachment]) {
        self.attachments = attachments
    }

    var remainingSlots: Int {
        max(0, FeedbackFirestoreSchema.attachmentLimit - attachments.count - preparingCount)
    }

    var isWorking: Bool { stage != nil || isUploadingLog }

    var canSubmit: Bool {
        !isWorking && diagnostics != nil && preparingCount == 0
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var submitTitle: String {
        switch stage {
        case .uploadingAttachment(let index, let total):
            String(format: localized("正在上傳附件 %1$d／%2$d…"), index, total)
        case .uploadingLog:
            localized("正在上傳日誌…")
        case .sending:
            localized("傳送中…")
        case nil:
            localized("提交反饋")
        }
    }

    func prepare() {
        deviceInfo = FeedbackDeviceInfo.current()
        guard diagnostics == nil else { return }
        Task.detached(priority: .userInitiated) {
            let log = DiagnosticLog.shared
            let bundle = DiagnosticReportBundle(
                filename: DiagnosticReportBundle.filename(),
                entries: log.snapshot(),
                session: log.currentSession,
                uncleanSessions: log.uncleanPreviousSessions()
            )
            await MainActor.run { [weak self] in self?.diagnostics = bundle }
        }
    }

    func addPicked(_ items: [PhotosPickerItem]) {
        let accepted = Array(items.prefix(remainingSlots))
        preparingCount += accepted.count
        for item in accepted {
            Task {
                do {
                    let attachment = try await FeedbackDraftAttachment.prepare(item)
                    attachments.append(attachment)
                } catch {
                    AppLogger.error("Feedback attachment could not be prepared", error: error)
                    alert = .failed(FeedbackService.userMessage(for: error))
                }
                preparingCount -= 1
            }
        }
    }

    func remove(_ attachment: FeedbackDraftAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachment.discard()
    }

    /// The log file, headed by what was written and the device facts.
    func shareBundle(from bundle: DiagnosticReportBundle) -> DiagnosticReportBundle {
        var copy = bundle
        let facts = deviceInfo.rows.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
        copy.preface = "[\(kind.localizedName)]\n\(text)\n\n\(facts)"
        return copy
    }

    func submit() {
        guard canSubmit, let diagnostics else { return }
        stage = .sending
        Task {
            do {
                _ = try await FeedbackService.shared.submit(
                    kind: kind,
                    text: text,
                    attachments: attachments,
                    diagnostics: diagnostics,
                    deviceInfo: deviceInfo,
                    progress: { [weak self] in self?.stage = $0 }
                )
                didSubmit = true
                attachments.forEach { $0.discard() }
                alert = .submitted
            } catch {
                AppLogger.network("Feedback submit failed", error: error)
                alert = .failed(FeedbackService.userMessage(for: error))
            }
            stage = nil
        }
    }

    func uploadLogOnly() {
        guard let diagnostics, !isWorking else { return }
        isUploadingLog = true
        Task {
            do {
                let receipt = try await DiagnosticReportUploader.upload(diagnostics, note: text)
                alert = .logSent(receipt.reportID)
            } catch {
                AppLogger.network("Diagnostic report upload failed", error: error)
                alert = .failed(FeedbackService.userMessage(for: error))
            }
            isUploadingLog = false
        }
    }

    func discardUnsent() {
        guard !didSubmit, !isWorking else { return }
        // Leaving the form keeps nothing: the picks were temporary copies.
        attachments.forEach { $0.discard() }
        attachments = []
    }
}

#Preview {
    NavigationStack {
        FeedbackComposeView()
    }
}
