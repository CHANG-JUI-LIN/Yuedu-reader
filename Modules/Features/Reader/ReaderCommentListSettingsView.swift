import SwiftUI
import UIKit

/// 評論列表: how the App's own comment list draws a comment — sliders, switches and a
/// stylesheet (`CommentListStyle`). A reading setting: themes carry it and it syncs.
struct ReaderCommentListSettingsView: View {
    @Bindable private var settings = GlobalSettings.shared
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section(header: Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)) {
                WorkReviewCard(review: .commentListSample)
                    .environment(\.commentListLook, settings.commentListLook)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WorkReview.commentListSample.spokenText(
                        locale: .current, inlineReplies: settings.commentListStyle.inlineReplies ?? DSLayout.commentInlineReplies,
                        hidden: settings.commentListStyle.hiddenParts ?? []))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section(header: Text(localized("卡片")).foregroundStyle(DSColor.textSecondary)) {
                slider(localized("卡片濃度"), "square.fill", \.cardOpacity, CommentListStyle.cardOpacityRange,
                       step: 0.01, shownAt: 0.06) { $0.formatted(.percent.precision(.fractionLength(0))) }
                slider(localized("圓角"), "square.dashed", \.cornerRadius, CommentListStyle.cornerRadiusRange,
                       step: 1, shownAt: Double(DSRadius.xl), format: Self.points)
                slider(localized("頭像大小"), "person.crop.circle", \.avatarSize, CommentListStyle.avatarSizeRange,
                       step: 1, shownAt: Double(DSLayout.commentAvatarSize), format: Self.points)
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("文字")).foregroundStyle(DSColor.textSecondary)) {
                slider(localized("名字字級"), "person.text.rectangle", \.nameFontSize, CommentListStyle.nameFontSizeRange,
                       step: 0.5, shownAt: 13, format: Self.points)
                slider(localized("內文字級"), "textformat.size", \.contentFontSize, CommentListStyle.contentFontSizeRange,
                       step: 0.5, shownAt: 15, format: Self.points)
                slider(localized("時間字級"), "clock", \.metaFontSize, CommentListStyle.metaFontSizeRange,
                       step: 0.5, shownAt: 13, format: Self.points)
                slider(localized("行距"), ReadingSettingsScopeItem.lineSpacing.systemImage, \.lineSpacing, CommentListStyle.lineSpacingRange,
                       step: 1, shownAt: 0, format: Self.points)
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("顯示")).foregroundStyle(DSColor.textSecondary)) {
                ForEach(CommentListPart.allCases) { part in
                    Toggle(isOn: shows(part)) {
                        SettingsRowLabel(localized(part.titleKey), systemImage: part.systemImage)
                    }
                    .accessibilityIdentifier("commentList.shows.\(part.rawValue)")
                }
                Stepper(value: inlineReplies, in: CommentListStyle.inlineRepliesRange) {
                    SettingsValueLabel(
                        title: localized("樓中樓顯示則數"),
                        systemImage: "arrowshape.turn.up.left.2",
                        value: String(inlineReplies.wrappedValue)
                    )
                }
            }
            .interfaceSectionSurface()

            Section {
                NavigationLink {
                    CommentListStylesheetView()
                } label: {
                    SettingsValueLabel(title: localized("樣式表"), systemImage: "curlybraces", value: stylesheetValue)
                }
                .accessibilityIdentifier("commentList.stylesheet")
            } footer: {
                Text(localized("滑桿與開關優先於樣式表。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                Button {
                    settings.commentListStyle = CommentListStyle(css: settings.commentListStyle.css)
                } label: {
                    SettingsRowLabel(localized("清除滑桿與開關"), systemImage: "slider.horizontal.below.rectangle", role: .action)
                }
                .disabled(settings.commentListStyle == CommentListStyle(css: settings.commentListStyle.css))
                .accessibilityIdentifier("commentList.clearTweaks")
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    SettingsRowLabel(localized("重設評論列表"), systemImage: "arrow.counterclockwise", role: .destructive)
                }
                .disabled(settings.commentListStyle == CommentListStyle())
            } footer: {
                Text(localized("清除滑桿與開關會保留樣式表；重設連樣式表一起清掉。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .navigationTitle(localized("評論列表"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .confirmationDialog(localized("重設評論列表"), isPresented: $confirmsReset, titleVisibility: .visible) {
            Button(localized("重設"), role: .destructive) { settings.commentListStyle = CommentListStyle() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("滑桿、開關與樣式表都回到 App 的預設。"))
        }
    }

    private var stylesheetValue: String {
        guard let css = settings.commentListStyle.css, !css.isEmpty else { return localized("無") }
        return CommentListTemplates.all.first { $0.css == css }.map { localized($0.titleKey) } ?? localized("自訂")
    }

    static func points(_ value: Double) -> String {
        String(format: localized("%@ pt"), value.formatted(.number.precision(.fractionLength(0...1))))
    }

    /// A slider over an optional value: nil (the stylesheet's, else the App's) reads 預設 and
    /// sits at `shownAt` until it is moved.
    private func slider(_ title: String, _ systemImage: String, _ path: WritableKeyPath<CommentListStyle, Double?>,
                        _ range: ClosedRange<Double>, step: Double, shownAt fallback: Double,
                        format: @escaping (Double) -> String) -> some View {
        let value = settings.commentListStyle[keyPath: path]
        return SettingsSliderRow(
            title: title,
            systemImage: systemImage,
            valueText: value.map(format) ?? localized("預設"),
            value: Binding(
                get: { value ?? min(max(fallback, range.lowerBound), range.upperBound) },
                set: { settings.commentListStyle[keyPath: path] = $0 }
            ),
            range: range,
            step: step
        )
    }

    private func shows(_ part: CommentListPart) -> Binding<Bool> {
        Binding(
            get: { settings.commentListStyle.shows(part) },
            set: { shown in
                var hidden = settings.commentListStyle.hiddenParts ?? []
                if shown { hidden.remove(part) } else { hidden.insert(part) }
                settings.commentListStyle.hiddenParts = hidden.isEmpty ? nil : hidden
            }
        )
    }

    private var inlineReplies: Binding<Int> {
        Binding(
            get: { settings.commentListStyle.inlineReplies ?? DSLayout.commentInlineReplies },
            set: { settings.commentListStyle.inlineReplies = $0 }
        )
    }
}

/// 樣式表: the stylesheet, a template to start from, and what of it the list does not read.
/// Written to the setting when the page closes; the preview follows every keystroke.
struct CommentListStylesheetView: View {
    @Bindable private var settings = GlobalSettings.shared
    @State private var draft = ""
    @State private var sheet = CommentListCSS.Sheet()
    @State private var pendingTemplate: CommentListTemplates.Template?
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section(header: Text(localized("預覽")).foregroundStyle(DSColor.textSecondary)) {
                WorkReviewCard(review: .commentListSample)
                    .environment(\.commentListLook, CommentListLook(style: previewStyle, sheet: sheet))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WorkReview.commentListSample.spokenText(locale: .current))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                TextEditor(text: $draft)
                    .font(DSFont.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: DSLayout.readerSVGEditorHeight)
                    .accessibilityLabel(localized("樣式表"))
                    .accessibilityIdentifier("commentList.css")
                Button {
                    if let pasted = UIPasteboard.general.string { draft = pasted }
                } label: {
                    SettingsRowLabel(localized("從剪貼簿貼上樣式表"), systemImage: "doc.on.clipboard", role: .action)
                }
            } header: {
                Text(localized("樣式表")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("只套用在 App 的評論列表，不改來源配置的網頁。可用 .user、.text、.time、.quote、.label、.avatar、.floor、.reply，以及 @dark／@light。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section(header: Text(localized("範本")).foregroundStyle(DSColor.textSecondary)) {
                ForEach(CommentListTemplates.all) { template in
                    Button {
                        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == template.css {
                            use(template)
                        } else {
                            pendingTemplate = template
                        }
                    } label: {
                        SettingsRowLabel(localized(template.titleKey), systemImage: "paintbrush", role: .action)
                    }
                    .accessibilityIdentifier("commentList.template.\(template.id)")
                }
            }
            .interfaceSectionSurface()

            if !sheet.ignored.isEmpty {
                Section {
                    ForEach(sheet.ignored.indices, id: \.self) { index in
                        Text(verbatim: sheet.ignored[index])
                            .font(DSFont.monospaced())
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } header: {
                    Text(localized("未套用")).foregroundStyle(DSColor.textSecondary)
                } footer: {
                    Text(localized("列表沒有對應的寫法，會原樣留在主題包裡。"))
                        .dsSectionFooter()
                }
                .interfaceSectionSurface()
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("樣式表"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            draft = settings.commentListStyle.css ?? ""
            sheet = settings.commentListSheet
        }
        .onChange(of: draft) { _, text in sheet = CommentListCSS.parse(text) }
        .onDisappear {
            let text = String(draft.prefix(CommentListStyle.cssLimit))
            settings.commentListStyle.css = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        .confirmationDialog(
            localized("取代目前的樣式表？"),
            isPresented: Binding(get: { pendingTemplate != nil }, set: { if !$0 { pendingTemplate = nil } }),
            titleVisibility: .visible,
            presenting: pendingTemplate
        ) { template in
            Button(localized("取代")) { use(template) }
            Button(localized("取消"), role: .cancel) {}
        }
    }

    /// The setting's sliders and switches over the draft, as the list will draw them.
    private var previewStyle: CommentListStyle {
        var style = settings.commentListStyle
        style.css = draft
        return style
    }

    private func use(_ template: CommentListTemplates.Template) {
        draft = template.css
        pendingTemplate = nil
    }
}

extension WorkReview {
    /// The comment 評論列表 is previewed on: every part a style can dress.
    static let commentListSample = WorkReview(
        text: localized("這一段的伏筆到第三部才收回來，重讀才看懂。"),
        author: localized("讀者甲"),
        likes: 128,
        badge: localized("盟主"),
        floor: "3",
        replies: [
            WorkReview(text: localized("同意，重讀才發現。"), author: localized("讀者乙")),
            WorkReview(text: localized("作者真的會埋。"), author: localized("讀者丙"), isAuthor: true),
        ],
        replyCount: 2,
        quote: localized("風，起了。"),
        meta: "11-11 22:10 · " + localized("江蘇")
    )
}

#Preview("評論列表") {
    NavigationStack {
        ReaderCommentListSettingsView()
    }
}

#Preview("樣式表") {
    NavigationStack {
        CommentListStylesheetView()
    }
}
