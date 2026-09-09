import Testing
import UIKit
@testable import yuedu_app

@Suite(.serialized)
struct LexborComputedStyleCoverageTests {
    private func declaration(_ property: String, _ value: String) -> FrontendWinningDeclaration {
        FrontendWinningDeclaration(nodeID: 7, property: property, value: value, specificity: 256,
            sourceOrder: 3, origin: 0, important: true, selector: ".Example",
            stylesheet: StylesheetIdentity(sourceOrder: 1, label: "Styles/Main.css"))
    }

    private func mapped(_ pairs: [(String, String)], parent: ComputedStyle = ComputedStyle(),
                        starting: ComputedStyle = ComputedStyle()) -> (ComputedStyle, FrontendCapabilityFacts) {
        var style = starting, facts = FrontendCapabilityFacts()
        var config = BrowserLayoutConfig(); config.rootFontSize = 20
        LexborComputedStyleAdapter.apply(winners: pairs.map { declaration($0.0, $0.1) },
            to: &style, parent: parent, config: config, facts: &facts, semanticPath: "body/p[1]")
        return (style, facts)
    }

    @Test func coverageTableMatchesMigrationContract() {
        let requiredProperties: Set<String> = [
            "display", "visibility", "float", "clear", "font-family", "font-size", "font-style", "font-weight", "line-height",
            "color", "background-color", "background-image", "background-size", "background-position", "background-repeat", "background-attachment",
            "white-space", "text-align", "text-indent", "width", "height", "min-width", "max-width", "min-height", "max-height",
            "margin-top", "margin-right", "margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom", "padding-left",
            "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "border-top-style", "border-right-style",
            "border-bottom-style", "border-left-style", "border-color", "border-radius", "ruby-align", "ruby-position", "ruby-merge"
        ]
        #expect(LexborComputedStyleAdapter.coveredProperties == requiredProperties)
    }

    @Test func boxLonghandsKeepSymbolicUnitsAndAuto() {
        let (style, facts) = mapped([
            ("width", "30%"), ("height", "auto"), ("max-width", "25rem"),
            ("margin-top", "-2em"), ("margin-right", "auto"), ("margin-bottom", "3pt"), ("margin-left", "2px"),
            ("padding-top", "1em"), ("padding-right", "2rem"), ("padding-bottom", "3%"), ("padding-left", "0")
        ])
        #expect(style.width == .percent(0.3)); #expect(style.height == .auto); #expect(style.maxWidth == .rem(25))
        #expect(style.marginTop == .em(-2)); #expect(style.marginRight == .auto)
        #expect(style.marginBottom == .pt(3)); #expect(style.marginLeft == .px(2))
        #expect(style.paddingTop == .em(1)); #expect(style.paddingRight == .rem(2))
        #expect(style.paddingBottom == .percent(0.03)); #expect(style.paddingLeft == .px(0))
        #expect(!facts.blocksCutover)
    }

    @Test func fontSizePrecedesDependentLengthsRegardlessOfDeclarationOrder() {
        let (style, facts) = mapped([
            ("line-height", "150%"), ("border-top-width", "0.5em"), ("border-right-width", "1rem"),
            ("border-bottom-width", "thin"), ("border-left-width", "3pt"), ("border-radius", "0.25em"), ("font-size", "2em")
        ], parent: ComputedStyle(fontSize: 12))
        #expect(style.fontSize == 24); #expect(style.lineHeight == 36)
        #expect(style.borderTopWidth == 12); #expect(style.borderRightWidth == 20)
        #expect(style.borderBottomWidth == 1); #expect(style.borderLeftWidth == 4); #expect(style.borderRadius == 6)
        #expect(style.pendingLineHeightLength == nil); #expect(style.pendingBorderTopWidth == nil)
        #expect(!facts.blocksCutover)
    }

    @Test func unitlessLineHeightAndAbsoluteLineHeightInheritDifferently() {
        let (multiplierParent, _) = mapped([("font-size", "20px"), ("line-height", "1.5")])
        let (multiplierChild, _) = mapped([("font-size", "40px"), ("line-height", "inherit")], parent: multiplierParent)
        #expect(multiplierChild.lineHeightMultiplier == 1.5); #expect(multiplierChild.lineHeight == 60)
        let (lengthParent, _) = mapped([("font-size", "20px"), ("line-height", "150%")])
        let (lengthChild, _) = mapped([("font-size", "40px"), ("line-height", "inherit")], parent: lengthParent)
        #expect(lengthChild.lineHeightMultiplier == nil); #expect(lengthChild.lineHeight == 30)
    }

    @Test func cssWideValuesRespectInheritanceAndCSSInitialValues() {
        var parent = ComputedStyle(fontSize: 30, fontWeight: 700, color: .red)
        parent.marginLeft = .px(45); parent.width = .percent(0.6); parent.textIndent = .length(.percent(0.1))
        let (style, facts) = mapped([
            ("font-size", "unset"), ("font-weight", "initial"), ("margin-left", "unset"),
            ("width", "inherit"), ("text-indent", "unset"), ("display", "initial"), ("border-top-style", "initial")
        ], parent: parent)
        #expect(style.fontSize == 30); #expect(style.fontWeight == 400); #expect(style.marginLeft == .px(0))
        #expect(style.width == .percent(0.6)); #expect(style.textIndent == .length(.percent(0.1)))
        #expect(style.display == .inline); #expect(style.borderTopStyle == .none); #expect(!facts.blocksCutover)
    }

    @Test func inheritedRelativeLengthsUseParentComputedFontSize() {
        var parent = ComputedStyle(fontSize: 20)
        parent.width = .em(2); parent.height = .em(3); parent.maxWidth = .rem(5)
        parent.marginTop = .em(1); parent.marginRight = .em(-2); parent.marginBottom = .rem(3); parent.marginLeft = .em(4)
        parent.paddingTop = .em(1); parent.paddingRight = .rem(2); parent.paddingBottom = .em(3); parent.paddingLeft = .em(4)
        parent.textIndent = .length(.em(1.5))
        let properties = ["width", "height", "max-width", "margin-top", "margin-right", "margin-bottom", "margin-left",
                          "padding-top", "padding-right", "padding-bottom", "padding-left", "text-indent"]
        let (style, facts) = mapped(properties.map { ($0, "inherit") } + [("font-size", "40px")], parent: parent)
        #expect(style.fontSize == 40); #expect(style.width == .px(40)); #expect(style.height == .px(60)); #expect(style.maxWidth == .px(100))
        #expect(style.marginTop == .px(20)); #expect(style.marginRight == .px(-40)); #expect(style.marginBottom == .px(60)); #expect(style.marginLeft == .px(80))
        #expect(style.paddingTop == .px(20)); #expect(style.paddingRight == .px(40)); #expect(style.paddingBottom == .px(60)); #expect(style.paddingLeft == .px(80))
        #expect(style.textIndent == .length(.px(30))); #expect(!facts.blocksCutover)
        let (unsetIndent, _) = mapped([("text-indent", "unset"), ("font-size", "40px")], parent: parent)
        #expect(unsetIndent.textIndent == .length(.px(30)))
    }

    @Test func inheritedPercentagesAndAutoRemainSymbolic() {
        var parent = ComputedStyle(fontSize: 20)
        parent.width = .percent(0.4); parent.height = .auto; parent.marginLeft = .auto
        parent.paddingTop = .percent(0.05); parent.textIndent = .length(.percent(0.1))
        let (style, facts) = mapped([("font-size", "40px"), ("width", "inherit"), ("height", "inherit"),
            ("margin-left", "inherit"), ("padding-top", "inherit"), ("text-indent", "inherit")], parent: parent)
        #expect(style.width == .percent(0.4)); #expect(style.height == .auto); #expect(style.marginLeft == .auto)
        #expect(style.paddingTop == .percent(0.05)); #expect(style.textIndent == .length(.percent(0.1))); #expect(!facts.blocksCutover)
    }

    @Test(arguments: ["inherit", "initial", "unset"])
    func cssWideBackgroundComponentsWithoutImageRetainGap(_ keyword: String) {
        var parent = ComputedStyle()
        var image = BackgroundImageStyle(source: "Parent.JPG")
        image.size = .cover; image.positionX = .keyword(1); image.positionY = .keyword(1)
        image.repeatMode = .noRepeat; image.attachment = .fixed; parent.backgroundImage = image
        let properties = ["background-size", "background-position", "background-repeat", "background-attachment"]
        let (style, facts) = mapped(properties.map { ($0, keyword) }, parent: parent)
        #expect(style.backgroundImage == nil)
        #expect(Set(facts.unsupportedDeclarations.map(\.property)) == Set(properties))
        #expect(facts.unsupportedDeclarations.allSatisfy { $0.value == keyword && $0.reason.contains("ADAPTER_GAP") })
        let (withImage, supportedFacts) = mapped(properties.map { ($0, keyword) } + [("background-image", "url(Child.JPG)")], parent: parent)
        #expect(withImage.backgroundImage?.source == "Child.JPG"); #expect(!supportedFacts.blocksCutover)
        if keyword == "inherit" {
            #expect(withImage.backgroundImage?.size == .cover); #expect(withImage.backgroundImage?.repeatMode == .noRepeat)
            #expect(withImage.backgroundImage?.positionX == .keyword(1)); #expect(withImage.backgroundImage?.attachment == .fixed)
        }
    }

    @Test func fontFamiliesAndURLsPreserveCaseAndDecodeEscapes() {
        let (style, facts) = mapped([
            ("font-family", #""Mixed Case, Family", My\46 ont, 'Other Face'"#),
            ("background-image", #"url('../Images/Cover\20 Art.JPG')"#),
            ("background-size", "cover"), ("background-position", "bottom right"),
            ("background-repeat", "no-repeat"), ("background-attachment", "fixed")
        ])
        #expect(style.fontFamilies == ["Mixed Case, Family", "MyFont", "Other Face"])
        #expect(style.backgroundImage?.source == "../Images/Cover Art.JPG")
        #expect(style.backgroundImage?.size == .cover); #expect(style.backgroundImage?.positionX == .keyword(1))
        #expect(style.backgroundImage?.positionY == .keyword(1)); #expect(style.backgroundImage?.repeatMode == .noRepeat)
        #expect(style.backgroundImage?.attachment == .fixed); #expect(!facts.blocksCutover)
    }

    @Test func backgroundPositionUsesEachAxisAndCurrentFont() {
        let (style, facts) = mapped([("background-position", "2em 30%"), ("background-image", "url(Cover.JPG)"), ("font-size", "25px")])
        #expect(style.backgroundImage?.positionX == .length(50)); #expect(style.backgroundImage?.positionY == .percent(0.3))
        #expect(!facts.blocksCutover)
        let (vertical, _) = mapped([("background-image", "url(Cover.JPG)"), ("background-position", "top")])
        #expect(vertical.backgroundImage?.positionX == .keyword(0.5)); #expect(vertical.backgroundImage?.positionY == .keyword(0))
    }

    @Test func imageNoneAndNormalLineHeightClearEarlierValues() {
        var old = ComputedStyle(lineHeight: 55)
        old.lineHeightMultiplier = 2; old.backgroundImage = BackgroundImageStyle(source: "Old.JPG")
        let (style, facts) = mapped([("background-image", "none"), ("line-height", "normal"), ("max-width", "none")], starting: old)
        #expect(style.backgroundImage == nil); #expect(style.lineHeight == nil); #expect(style.lineHeightMultiplier == nil)
        #expect(style.maxWidth == nil); #expect(!facts.blocksCutover)
    }

    @Test func unquotedEscapedURLPreservesTokenBoundaries() {
        let (style, facts) = mapped([("background-image", #"url(Images/Cover\20 Art.JPG)"#)])
        #expect(style.backgroundImage?.source == "Images/Cover Art.JPG")
        #expect(!facts.blocksCutover)
        let (_, invalidFacts) = mapped([("background-image", "url(First.JPG) url(Second.JPG)")])
        #expect(invalidFacts.blocksCutover)
    }

    @Test func backgroundComponentsWithoutImageCannotDisappearFromInheritance() {
        let (_, facts) = mapped([("background-size", "cover"), ("background-repeat", "no-repeat")])
        #expect(facts.unsupportedDeclarations.count == 2)
    }

    @Test func colorAndBorderLonghandsMapWithoutLosingCurrentColor() {
        let (style, facts) = mapped([
            ("border-color", "currentColor"), ("color", "#1234"), ("background-color", "transparent"),
            ("border-top-style", "dotted"), ("border-right-style", "dashed"), ("border-bottom-style", "none"), ("border-left-style", "solid")
        ])
        #expect(style.color == UIColor(red: 1.0 / 15, green: 2.0 / 15, blue: 3.0 / 15, alpha: 4.0 / 15))
        #expect(style.borderColor == style.color); #expect(style.backgroundColor == .clear)
        #expect(style.borderTopStyle == .dotted); #expect(style.borderRightStyle == .dashed)
        #expect(style.borderBottomStyle == .none); #expect(style.borderLeftStyle == .solid); #expect(!facts.blocksCutover)
    }

    @Test func textFloatClearRubyAndFontKeywordsMap() {
        let (style, facts) = mapped([
            ("display", #"in\6cine-block"#), ("visibility", "visible"), ("float", "left"), ("clear", "both"),
            ("font-style", "italic"), ("font-weight", "bolder"), ("white-space", "pre-wrap"), ("text-align", "justify"),
            ("text-indent", "5%"), ("ruby-align", "center"), ("ruby-position", "over"), ("ruby-merge", "separate")
        ], parent: ComputedStyle(fontWeight: 400))
        #expect(style.display == .inlineBlock); #expect(!style.isHidden); #expect(style.cssFloat == .left); #expect(style.cssClear == .both)
        #expect(style.isItalic); #expect(style.fontWeight == 700); #expect(style.whiteSpace == .preWrap)
        #expect(style.textAlign == .justified); #expect(style.textIndent == .length(.percent(0.05)))
        #expect(style.rubyAlign == .center); #expect(style.rubyPosition == .over); #expect(style.rubyMerge == .separate)
        #expect(!facts.blocksCutover)
    }

    @Test(arguments: [
        ("min-width", "10px"), ("min-height", "2em"), ("max-height", "none"), ("display", "flex"),
        ("background-image", "linear-gradient(red, blue)"), ("background-size", "10px 20px"),
        ("background-repeat", "repeat-x"), ("background-attachment", "local"), ("background-position", "right 10px bottom 20px"),
        ("border-top-style", "double"), ("border-top-color", "red"), ("border-radius", "10%"),
        ("font-style", "oblique 20deg"), ("text-indent", "-1em"), ("ruby-align", "space-around"),
        ("padding-top", "auto"), ("padding-left", "-1px"), ("width", "calc(100% - 2px)"), ("font-size", "10"),
        ("visibility", "hidden"), ("visibility", "collapse")
    ])
    func unsupportedValuesRetainWinningEvidence(_ item: (String, String)) throws {
        let (_, facts) = mapped([item])
        let fact = try #require(facts.unsupportedDeclarations.first)
        #expect(facts.blocksCutover); #expect(fact.property == item.0); #expect(fact.value == item.1)
        #expect(fact.semanticPath == "body/p[1]"); #expect(fact.source.selector == ".Example")
        #expect(fact.source.stylesheet?.label == "Styles/Main.css"); #expect(fact.source.important)
        #expect(fact.reason.hasPrefix("ADAPTER_GAP:"))
    }

    @Test(arguments: [
        ("margin", "1px 2px"), ("padding", "3em"), ("border", "1px solid red"), ("border-width", "1px 2px"),
        ("border-style", "solid"), ("font", "italic 16px/1.5 'Some Font'"), ("background", "url(Cover.JPG) center / cover"),
        ("border-color", "red blue"), ("border-radius", "1px 2px")
    ])
    func shorthandsRemainExplicitCutoverBlockers(_ item: (String, String)) {
        let (_, facts) = mapped([item])
        #expect(facts.blocksCutover)
        #expect(facts.unsupportedDeclarations.contains { $0.property == item.0 && $0.value == item.1 })
    }

    @Test func initialDoesNotOverwriteReaderConfiguration() {
        var starting = ComputedStyle(); starting.configLineSpacing = 4; starting.configLetterSpacing = 1
        starting.configParagraphSpacing = 8; starting.configBold = true
        let (style, _) = mapped([("font-size", "initial"), ("line-height", "initial")], starting: starting)
        #expect(style.configLineSpacing == 4); #expect(style.configLetterSpacing == 1)
        #expect(style.configParagraphSpacing == 8); #expect(style.configBold)
    }
}
