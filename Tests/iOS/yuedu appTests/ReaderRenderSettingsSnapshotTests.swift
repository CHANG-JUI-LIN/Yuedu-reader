import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader render settings snapshot", .serialized)
@MainActor
struct ReaderRenderSettingsSnapshotTests {

    @Test("surface geometry changes without changing shared settings")
    func surfaceGeometryChangesWithoutChangingSharedSettings() {
        let input = makeInput()
        let pagedInsets = UIEdgeInsets(top: 42, left: 24, bottom: 58, right: 24)
        let scrollInsets = UIEdgeInsets(top: 51, left: 24, bottom: 46, right: 24)

        let paged = ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .paged(
                contentInsets: pagedInsets,
                marginV: 16,
                footerHeight: 22
            )
        )
        let scroll = ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .scroll(
                contentInsets: scrollInsets,
                marginV: 18,
                footerHeight: 24
            )
        )

        #expect(paged.theme == "sepia")
        #expect(paged.textColor == .black)
        #expect(paged.backgroundColor == .white)
        #expect(paged.fontSize == 18)
        #expect(paged.lineHeightMultiple == 1.6)
        #expect(paged.lineSpacing == 10.8)
        #expect(paged.paragraphSpacing == 8)
        #expect(paged.letterSpacing == 0)
        #expect(paged.marginH == 24)
        #expect(paged.writingMode == .horizontal)
        #expect(paged.fontPostScriptName == "Courier")
        #expect(paged.isBold == false)
        #expect(paged.chapterTitleStyle == .default)
        #expect(paged.readerBackgroundImageURL == nil)
        #expect(paged.regexHighlightConfiguration == .disabled)
        #expect(paged.readerStyleAppearance == .dark)
        #expect(paged.readerStyleAssetRevision == 7)

        #expect(paged.theme == scroll.theme)
        #expect(paged.textColor == scroll.textColor)
        #expect(paged.backgroundColor == scroll.backgroundColor)
        #expect(paged.fontSize == scroll.fontSize)
        #expect(paged.lineHeightMultiple == scroll.lineHeightMultiple)
        #expect(paged.lineSpacing == scroll.lineSpacing)
        #expect(paged.paragraphSpacing == scroll.paragraphSpacing)
        #expect(paged.letterSpacing == scroll.letterSpacing)
        #expect(paged.marginH == scroll.marginH)
        #expect(paged.writingMode == scroll.writingMode)
        #expect(paged.fontPostScriptName == scroll.fontPostScriptName)
        #expect(paged.isBold == scroll.isBold)
        #expect(paged.chapterTitleStyle == scroll.chapterTitleStyle)
        #expect(paged.readerBackgroundImageURL == scroll.readerBackgroundImageURL)
        #expect(paged.regexHighlightConfiguration == scroll.regexHighlightConfiguration)
        #expect(paged.readerStyleAppearance == scroll.readerStyleAppearance)
        #expect(paged.readerStyleAssetRevision == scroll.readerStyleAssetRevision)
        #expect(paged.contentInsets == pagedInsets)
        #expect(paged.marginV == 16)
        #expect(paged.footerHeight == 22)
        #expect(scroll.contentInsets == scrollInsets)
        #expect(scroll.marginV == 18)
        #expect(scroll.footerHeight == 24)
        #expect(paged.contentInsets != scroll.contentInsets)
    }

    @Test(
        "every chapter title style field participates in snapshot equality",
        arguments: ChapterTitleStyleMutation.allCases
    )
    func everyChapterTitleStyleFieldParticipatesInSnapshotEquality(
        mutation: ChapterTitleStyleMutation
    ) {
        let baseline = snapshot(chapterTitleStyle: .default)
        var changedStyle = ChapterTitleStyle.default
        mutation.apply(to: &changedStyle)

        #expect(snapshot(chapterTitleStyle: changedStyle) != baseline)
    }

    private func snapshot(chapterTitleStyle: ChapterTitleStyle) -> ReaderRenderSettings {
        var input = makeInput()
        input.chapterTitleStyle = chapterTitleStyle
        return ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .paged(
                contentInsets: UIEdgeInsets(top: 42, left: 24, bottom: 58, right: 24),
                marginV: 16,
                footerHeight: 22
            )
        )
    }

    private func makeInput() -> ReaderRenderSettingsSnapshotInput {
        ReaderRenderSettingsSnapshotInput(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.6,
            lineSpacing: 10.8,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            writingMode: .horizontal,
            fontPostScriptName: "Courier",
            isBold: false,
            chapterTitleStyle: .default,
            readerBackgroundImageURL: nil,
            regexHighlightConfiguration: .disabled,
            readerStyleAppearance: .dark,
            readerStyleAssetRevision: 7
        )
    }
}

enum ChapterTitleStyleMutation: CaseIterable {
    case visible
    case size
    case topSpacing
    case bottomSpacing
    case weight
    case alignment
    case followsBodyFont
    case splitEnabled
    case numberRelativeSize
    case numberFontPostScript
    case nameFontPostScript
    case advancedCSSEnabled
    case lightTemplate
    case darkTemplate

    func apply(to style: inout ChapterTitleStyle) {
        switch self {
        case .visible:
            style.visible.toggle()
        case .size:
            style.size += 1
        case .topSpacing:
            style.topSpacing += 1
        case .bottomSpacing:
            style.bottomSpacing += 1
        case .weight:
            style.weight = style.weight == .regular ? .bold : .regular
        case .alignment:
            style.alignment = style.alignment == .left ? .right : .left
        case .followsBodyFont:
            style.followsBodyFont.toggle()
        case .splitEnabled:
            style.splitEnabled.toggle()
        case .numberRelativeSize:
            style.numberRelativeSize = style.numberRelativeSize == 0.7 ? 0.8 : 0.7
        case .numberFontPostScript:
            style.numberFontPostScript = "Courier"
        case .nameFontPostScript:
            style.nameFontPostScript = "Courier-Bold"
        case .advancedCSSEnabled:
            style.advancedCSSEnabled.toggle()
        case .lightTemplate:
            style.lightTemplate += "<span>light</span>"
        case .darkTemplate:
            style.darkTemplate += "<span>dark</span>"
        }
    }
}
