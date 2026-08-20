import Testing
import UIKit
@testable import yuedu_app

/// `float` / `clear` computed values and their horizontal-layout integration.
///
/// The load-bearing case is `float: center`. 红楼梦 declares
/// `div.duokan-float-center { float: center }` on 51 of its 57 float-classed
/// boxes; `center` is not a `float` value, so the declaration is invalid and
/// dropped, leaving the initial `none` — a browser lays those out as ordinary
/// blocks. An engine that dispatches on the CLASS NAME, or that maps unknown
/// tokens onto a side, floats 89% of this book's "float" boxes wrongly.
@MainActor
struct BrowserLayoutFloatStyleTests {

    /// Computed style of the first box matching `tag` under the root.
    private func style(html: String, css: String = "", tag: String) throws -> ComputedStyle? {
        let config = BrowserLayoutConfig(
            renderWidth: 300, renderHeight: 400, rootFontSize: 17,
            fontFamilies: [], textColor: .black, backgroundColor: .white
        )
        let doc = BrowserLayoutDocument(
            html: html, cssTexts: css.isEmpty ? [] : [css], config: config, imageLoader: nil
        )
        let result = try doc.makeLayout(containerSize: CGSize(width: 300, height: 400))
        var found: ComputedStyle?
        func walk(_ box: BlockBox) {
            if found == nil, box.debugTag == tag { found = box.style }
            for child in box.children { walk(child) }
        }
        walk(result.rootBox)
        return found
    }

    // MARK: - The invalid-value trap

    @Test func floatCenterIsInvalidAndComputesToNone() throws {
        // The real 红楼梦 rule, verbatim.
        let css = """
        div.duokan-float-center { float: center; width: 100%; margin-top: 1em;
                                  margin-bottom: 1em; text-align: center; }
        """
        let html = """
        <html><body><div class="duokan-float-center"><p>x</p></div></body></html>
        """
        let s = try #require(try style(html: html, css: css, tag: "div"))
        #expect(s.cssFloat == .none,
                "`float: center` is not a CSS float value — the declaration must be dropped")
        // The rest of the block still applies: only the invalid DECLARATION is
        // dropped, never the whole rule.
        #expect(s.textAlign == .center, "sibling declarations in the same rule must survive")
    }

    @Test func unknownFloatAndClearTokensAreDropped() throws {
        for token in ["center", "inline-start", "middle", "1", "auto", "lefT-ish"] {
            let s = try #require(try style(
                html: "<html><body><div style=\"float: \(token)\"><p>x</p></div></body></html>",
                tag: "div"
            ))
            #expect(s.cssFloat == .none, "float: \(token) must not resolve to a side")
        }
        for token in ["all", "inline-end", "yes"] {
            let s = try #require(try style(
                html: "<html><body><div style=\"clear: \(token)\"><p>x</p></div></body></html>",
                tag: "div"
            ))
            #expect(s.cssClear == .none, "clear: \(token) must not resolve")
        }
    }

    // MARK: - The supported subset

    @Test func validFloatValuesResolve() throws {
        let cases: [(String, CSSFloat)] = [("none", .none), ("left", .left), ("right", .right)]
        for (token, expected) in cases {
            let s = try #require(try style(
                html: "<html><body><div style=\"float: \(token)\"><p>x</p></div></body></html>",
                tag: "div"
            ))
            #expect(s.cssFloat == expected, "float: \(token)")
        }
    }

    @Test func validClearValuesResolve() throws {
        let cases: [(String, CSSClear)] = [("none", .none), ("left", .left), ("right", .right), ("both", .both)]
        for (token, expected) in cases {
            let s = try #require(try style(
                html: "<html><body><div style=\"clear: \(token)\"><p>x</p></div></body></html>",
                tag: "div"
            ))
            #expect(s.cssClear == expected, "clear: \(token)")
        }
    }

    /// CSS keywords are case-insensitive.
    @Test func keywordsAreCaseInsensitive() throws {
        let s = try #require(try style(
            html: "<html><body><div style=\"float: RIGHT; clear: Both\"><p>x</p></div></body></html>",
            tag: "div"
        ))
        #expect(s.cssFloat == .right)
        #expect(s.cssClear == .both)
    }

    /// The real 红楼梦 float rule.
    @Test func duokanFloatRightResolvesToRight() throws {
        let css = """
        div.duokan-float-right { float: right; width: 50%; margin-top: 0;
                                 margin-bottom: 0.5em; margin-left: 0.5em;
                                 text-align: center; }
        """
        let html = """
        <html><body><div class="duokan-float-right"><p>x</p></div></body></html>
        """
        let s = try #require(try style(html: html, css: css, tag: "div"))
        #expect(s.cssFloat == .right)
    }

    // MARK: - Inheritance

    @Test func floatAndClearDoNotInherit() throws {
        let html = """
        <html><body><div style="float: right; clear: both"><p>child</p></div></body></html>
        """
        let child = try #require(try style(html: html, tag: "p"))
        #expect(child.cssFloat == .none, "float must not inherit")
        #expect(child.cssClear == .none, "clear must not inherit")
    }

    /// Phase 4B consumes `cssFloat`: a right float is removed from normal flow,
    /// aligned to the right edge, and the following paragraph occupies the
    /// available band beside it.
    @Test func floatDeclarationChangesGeometry() async throws {
        let plain = """
        <html><body style="margin:0"><div style="width:100px"><p>浮動內容</p></div><p>之後</p></body></html>
        """
        let floated = """
        <html><body style="margin:0"><div style="float:right;width:100px"><p>浮動內容</p></div><p>之後</p></body></html>
        """
        let (a, _) = try await BrowserLayoutTestSupport.layout(plain, width: 300, height: 400)
        let (b, _) = try await BrowserLayoutTestSupport.layout(floated, width: 300, height: 400)
        let ra = BrowserLayoutTestSupport.allTextFragments(a).map(\.rect.rawValue)
        let rb = BrowserLayoutTestSupport.allTextFragments(b).map(\.rect.rawValue)
        #expect(ra.count == 2)
        #expect(rb.count == 2)
        #expect(rb[0].minX > ra[0].minX + 150, "right float must align to the right: \(ra) vs \(rb)")
        #expect(rb[1].minY < ra[1].minY, "following text must wrap beside the float: \(ra) vs \(rb)")
    }
}
