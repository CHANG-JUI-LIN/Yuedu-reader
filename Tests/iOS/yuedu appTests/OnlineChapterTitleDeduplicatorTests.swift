import Testing
import UIKit
@testable import yuedu_app

@Suite("Online chapter title deduplication", .serialized)
struct OnlineChapterTitleDeduplicatorTests {

    @MainActor
    @Test("places the review attachment before advanced-title bottom spacing")
    func placesReviewAttachmentBeforeBottomSpacing() {
        let title = NSMutableAttributedString(
            string: "第1章\n擇徒\n\n",
            attributes: [.font: UIFont.systemFont(ofSize: 20)]
        )
        let accessory = NSAttributedString(
            string: "\u{FFFC}",
            attributes: [.link: "ydreview://chapter"]
        )

        OnlineProviderAttributedStringBuilder.mergeTitleAccessories(accessory, into: title)

        #expect(title.string == "第1章\n擇徒\u{2009}\u{FFFC}\n\n")
        #expect(title.attribute(.link, at: 7, effectiveRange: nil) as? String == "ydreview://chapter")
    }

    @Test("removes review-bearing title inside an identified article")
    func removesTitleInsideAnchorTargetArticle() throws {
        let title = "第423章 梅花香自苦寒来"
        let reviewImage = RenderableNode.anchor(
            href: "ydreview://chapter",
            children: [
                .image(src: "data:image/svg+xml;base64,bubble", alt: "")
            ]
        )
        let nodes: [RenderableNode] = [
            .paragraph([
                .anchorTarget(
                    id: "reader-content",
                    child: .block(tag: "article", children: [
                        .heading([.text(title), reviewImage], level: 1),
                        .paragraph([.text("正文")]),
                    ])
                )
            ])
        ]

        let result = OnlineChapterTitleDeduplicator.deduplicatingLeadingTitle(
            from: nodes,
            matching: title
        )

        guard case .paragraph(let bodyChildren, _) = try #require(result.bodyNodes.first),
              case .anchorTarget(let id, let article) = try #require(bodyChildren.first),
              case .block(_, let articleChildren, _) = article,
              case .paragraph(let bodyText, _) = try #require(articleChildren.first),
              case .text("正文") = bodyText.first,
              case .anchor(let reviewURL, let reviewChildren) = try #require(result.titleAccessories.first)
        else {
            Issue.record("Expected the title review image to move out of the article heading")
            return
        }
        #expect(id == "reader-content")
        #expect(articleChildren.count == 1)
        #expect(result.titleAccessories.count == 1)
        #expect(reviewURL == "ydreview://chapter")
        #expect(reviewChildren.count == 1)
    }

    @Test("removes title through section and div wrappers while retaining review badge")
    func removesNestedTitleAndRetainsBadge() throws {
        let title = "第423章 梅花香自苦寒來"
        let badge = RenderableNode.commentBadge(
            count: "23",
            reviewURL: "ydreview://chapter",
            title: "本章說"
        )
        let nodes: [RenderableNode] = [
            .block(tag: "section", children: [
                .paragraph([
                    .paragraph([.text(title), badge]),
                    .paragraph([.text("正文")]),
                ])
            ])
        ]

        let result = OnlineChapterTitleDeduplicator.deduplicatingLeadingTitle(
            from: nodes,
            matching: title
        )

        guard case .block(_, let sectionChildren, _) = try #require(result.bodyNodes.first),
              case .paragraph(let wrapperChildren, _) = try #require(sectionChildren.first),
              case .paragraph(let bodyText, _) = try #require(wrapperChildren.first),
              case .text("正文") = bodyText.first
        else {
            Issue.record("Expected the nested wrapper shape to be preserved")
            return
        }
        #expect(wrapperChildren.count == 1)
        guard case .commentBadge(let count, _, _) = try #require(result.titleAccessories.first) else {
            Issue.record("Expected the chapter review badge to move onto the CSS title")
            return
        }
        #expect(count == "23")
    }

    @Test("retains a badge nested in the same inline wrapper as title text")
    func retainsBadgeInsideInlineWrapper() throws {
        let title = "第一章 初見"
        let badge = RenderableNode.commentBadge(
            count: "8",
            reviewURL: "ydreview://chapter",
            title: "本章說"
        )
        let nodes: [RenderableNode] = [
            .paragraph([
                .inline(tag: "span", children: [.text(title), badge])
            ])
        ]

        let result = OnlineChapterTitleDeduplicator.deduplicatingLeadingTitle(
            from: nodes,
            matching: title
        )

        #expect(result.bodyNodes.isEmpty)
        guard case .inline(_, let inlineChildren, _) = try #require(result.titleAccessories.first),
              case .commentBadge(let count, _, _) = try #require(inlineChildren.first)
        else {
            Issue.record("Expected only the nested review badge to move onto the CSS title")
            return
        }
        #expect(inlineChildren.count == 1)
        #expect(count == "8")
    }

    @Test("does not remove a different leading heading")
    func preservesDifferentHeading() throws {
        let nodes: [RenderableNode] = [
            .heading([.text("序言")], level: 1)
        ]

        let result = OnlineChapterTitleDeduplicator.removingLeadingTitle(
            from: nodes,
            matching: "第一章 初見"
        )

        guard case .heading(let children, let level, _) = try #require(result.first),
              case .text(let text) = try #require(children.first)
        else {
            Issue.record("Expected the unrelated heading to remain")
            return
        }
        #expect(level == 1)
        #expect(text == "序言")
    }
}
