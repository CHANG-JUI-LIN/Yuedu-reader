import SwiftUI

/// A module's comments, opened from the text: a chapter's (its 本章說 card) or one paragraph's
/// (its 段評 bubble, its 熱評 card), as 作品詳情's 讀者評論 lists a work's reviews. A module has
/// no page of its own to show, as a 來源配置 does. The comments are the site's own words; the
/// last row says whose.
struct ChapterCommentsSheet: View {
    @StateObject private var model: ChapterCommentsModel
    @Environment(\.dismiss) private var dismiss

    init(target: ModuleCommentTarget) {
        _model = StateObject(wrappedValue: ChapterCommentsModel(target: target))
    }

    /// A preview's, or a test's, own model.
    init(model: ChapterCommentsModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            ChapterCommentsList(model: model)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark").accessibilityHidden(true) }
                            .accessibilityLabel(localized("關閉"))
                            .accessibilityIdentifier("chapterComments.close")
                    }
                }
        }
        // 評論列表's style: the theme's, as the reader wears it.
        .environment(\.commentListLook, GlobalSettings.shared.commentListLook)
        // A clip goes quiet with the list it was started from.
        .onDisappear { CommentVoicePlayer.shared.stop() }
    }
}

/// One list of comments, or of one comment's replies: the sheet's first page, and each
/// 查看全部回覆 pushed onto it.
private struct ChapterCommentsList: View {
    @ObservedObject var model: ChapterCommentsModel
    @Environment(\.locale) private var locale
    @Environment(\.commentListLook) private var look
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
            .navigationTitle(localized(model.parent != nil ? "回覆" : model.paragraphID == nil ? "本章說" : "段評"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if model.sorts.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { sortMenu }
                }
            }
            // Once: coming back from a pushed list of replies does not read this one again.
            .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .accessibilityLabel(localized("讀取中"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                UnavailableLabel(localized("找不到這一章的評論"), systemImage: "text.bubble")
            }
            .accessibilityIdentifier("chapterComments.unavailable")
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("評論讀取失敗"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(localized("重試")) { Task { await model.load() } }
            }
        case .loaded:
            if model.comments.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("還沒有評論"), systemImage: "text.bubble")
                }
                .accessibilityIdentifier("chapterComments.empty")
            } else {
                list
            }
        }
    }

    private var list: some View {
        let hidden = look.resolved(isDark: colorScheme == .dark, fontScale: 1).hidden
        return List {
            Section {
                if let parent = model.parent {
                    // The comment these reply to, as its own card without the replies.
                    WorkReviewCard(review: parent, showsReplies: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(parent.spokenText(locale: locale, inlineReplies: 0, hidden: hidden))
                        .commentVoiceAction(parent, shown: !hidden.contains(.voice))
                        .accessibilityAddTraits(.isHeader)
                        .reviewRow()
                } else if !model.heading.isEmpty {
                    Text(model.heading)
                        .font(DSFont.title3.weight(.bold))
                        .foregroundStyle(DSColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .reviewRow()
                }
                // By position: two readers can write the same words.
                ForEach(model.comments.indices, id: \.self) { index in
                    let comment = model.comments[index]
                    WorkReviewCard(review: comment)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(comment.spokenText(
                            locale: locale, inlineReplies: look.style.inlineReplies ?? DSLayout.commentInlineReplies,
                            hidden: hidden))
                        .commentVoiceAction(comment, shown: !hidden.contains(.voice))
                        .accessibilityIdentifier("chapterComments.card")
                        .reviewRow()
                        .task {
                            // The last row on screen: the next page.
                            if index == model.comments.count - 1 { await model.loadMore() }
                        }
                    // A row of its own: inside the card, which VoiceOver reads as one, it
                    // could not be reached.
                    if model.parent == nil, let thread = model.thread,
                       ChapterCommentsModel.listsReplies(
                           of: comment, in: thread, shown: look.style.inlineReplies ?? DSLayout.commentInlineReplies) {
                        NavigationLink {
                            CommentRepliesPage(comment: comment, thread: thread, paragraphID: model.paragraphID)
                        } label: {
                            Text(String(format: localized("查看全部 %d 則回覆"), comment.knownReplyCount))
                                .font(DSFont.footnote.weight(.semibold))
                                .foregroundStyle(DSColor.accent)
                        }
                        .accessibilityIdentifier("chapterComments.replies")
                        .reviewRow()
                    }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .accessibilityLabel(localized("讀取中"))
                        .frame(maxWidth: .infinity)
                        .reviewRow()
                }
                if let thread = model.thread {
                    // A row in the footer's style, as 讀者評論 has it (design.md §4.1).
                    Text(String(format: localized("評論來自 %@"), thread.module.title))
                        .dsSectionFooter()
                        .accessibilityIdentifier("chapterComments.source")
                        .reviewRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The site's own orders (最熱, 最新): choosing one asks the site again.
    private var sortMenu: some View {
        let sorts = model.sorts
        return Menu {
            Picker(localized("排序"), selection: Binding(
                get: { model.sort ?? "" },
                set: { value in Task { await model.choose(sort: value) } }
            )) {
                ForEach(sorts, id: \.value) { sort in
                    Text(sort.title).tag(sort.value)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
        }
        .accessibilityLabel(localized("排序"))
        .accessibilityValue(sorts.first { $0.value == model.sort }?.title ?? "")
        .accessibilityIdentifier("chapterComments.sort")
    }
}

/// All of one comment's replies, pushed from its 查看全部回覆: its own model, kept while the
/// list it came from reads more pages.
private struct CommentRepliesPage: View {
    @StateObject private var model: ChapterCommentsModel

    init(comment: WorkReview, thread: ChapterCommentThread, paragraphID: String?) {
        _model = StateObject(wrappedValue: ChapterCommentsModel(repliesTo: comment, in: thread, paragraphID: paragraphID))
    }

    var body: some View {
        ChapterCommentsList(model: model)
    }
}

#Preview("本章說") {
    let module = RuleModule(id: "preview.comments", title: "範例模組", version: "1.0.0", hosts: ["example.com"], modules: [])
    let thread = ChapterCommentThread(
        module: module,
        record: RuleListItem(name: "三體", author: "劉慈欣", bookUrl: "https://example.com/b/1", coverUrl: "", intro: "",
                             wordCount: "", lastChapter: "", kind: ""),
        chapter: ModuleCommentChapter(id: "12", title: "第十二章 紅岸之二"))
    ChapterCommentsSheet(model: ChapterCommentsModel(
        heading: "第十二章 紅岸之二", findThread: { thread },
        readPage: { _, _, _, page in
            page > 1 ? [] : [
                WorkReview(title: nil, text: "這一章的伏筆到第三部才收回來。", author: "讀者甲", date: nil, rating: nil, likes: 128),
                WorkReview(title: nil, text: "重讀才看懂葉文潔那句話。", author: "讀者乙", date: nil, rating: nil, likes: 12),
            ]
        }))
}

#Preview("段評：稱號、樓層、樓中樓") {
    let module = RuleModule(id: "preview.comments", title: "範例模組", version: "1.0.0", hosts: ["example.com"], modules: [])
    let thread = ChapterCommentThread(
        module: module,
        record: RuleListItem(name: "長夜", author: "", bookUrl: "", coverUrl: "", intro: "", wordCount: "", lastChapter: "", kind: ""),
        chapter: ModuleCommentChapter(id: "12", title: "第十二章"))
    ChapterCommentsSheet(model: ChapterCommentsModel(
        heading: "風，起了。", paragraphID: "7", findThread: { thread },
        readPage: { _, _, _, page in
            page > 1 ? [] : [
                WorkReview(text: "這一段的伏筆到第三部才收。", author: "讀者甲", likes: 128, id: "c1", badge: "盟主", floor: "1",
                           replies: [WorkReview(text: "同意，重讀才發現。", author: "讀者乙"),
                                     WorkReview(text: "作者真的會埋。", author: "讀者丙"),
                                     WorkReview(text: "+1", author: "讀者丁"),
                                     WorkReview(text: "第四則", author: "讀者戊")],
                           replyCount: 4),
                WorkReview(text: "沙發！", author: "讀者己", badge: "學徒", floor: "沙發"),
            ]
        }))
}

#Preview("段評：找不到") {
    ChapterCommentsSheet(model: ChapterCommentsModel(heading: "「你們是蟲子。」", paragraphID: "7", findThread: { nil },
                                                     readPage: { _, _, _, _ in [] }))
}
