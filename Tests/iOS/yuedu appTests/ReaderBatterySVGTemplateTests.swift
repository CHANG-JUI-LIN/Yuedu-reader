import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader battery SVG templates")
struct ReaderBatterySVGTemplateTests {
    @Test("Accepts dynamic markers and preserves them in the validated template")
    func acceptsDynamicMarkers() throws {
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40">
          <rect data-yuedu-role="battery-level" fill="currentColor" height="40" width="100"/>
          <text data-yuedu-role="battery-percent">old <tspan>value</tspan></text>
          <path data-yuedu-visible="charging" d="M 45 5 L 30 22 H 45 L 38 35 L 70 15 H 52 Z"/>
        </svg>
        """

        let template = try ReaderBatterySVGTemplate(source: source)

        #expect(template.validatedSource.contains(#"data-yuedu-role="battery-level""#))
        #expect(template.validatedSource.contains(#"data-yuedu-role="battery-percent""#))
        #expect(template.validatedSource.contains(#"data-yuedu-visible="charging""#))
        #expect(template.validatedSource.contains(#"fill="currentColor""#))
    }

    @Test("Documentation horizontal and vertical examples pass production validation")
    func documentationExamplesAreValid() throws {
        let horizontal = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 48">
          <title>Horizontal battery</title>
          <rect x="2" y="2" width="104" height="44" rx="8"
                fill="none" stroke="currentColor" stroke-width="4"/>
          <rect x="108" y="15" width="10" height="18" rx="3" fill="currentColor"/>
          <rect data-yuedu-role="battery-level" data-yuedu-direction="left-to-right"
                x="8" y="8" width="92" height="32" rx="4" fill="currentColor"/>
          <text data-yuedu-role="battery-percent" x="54" y="31"
                fill="currentColor" font-size="14" text-anchor="middle">0%</text>
          <path data-yuedu-visible="charging" d="M58 7 L45 25 H56 L51 41 L73 19 H62 Z"
                fill="currentColor"/>
        </svg>
        """
        let vertical = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 120">
          <title>Vertical battery</title>
          <rect x="2" y="12" width="44" height="106" rx="8"
                fill="none" stroke="currentColor" stroke-width="4"/>
          <rect x="15" y="2" width="18" height="8" rx="3" fill="currentColor"/>
          <rect data-yuedu-role="battery-level" data-yuedu-direction="bottom-to-top"
                x="8" y="18" width="32" height="92" rx="4" fill="currentColor"/>
          <text data-yuedu-role="battery-percent" x="24" y="67"
                fill="currentColor" font-size="12" text-anchor="middle">0%</text>
        </svg>
        """

        for source in [horizontal, vertical] {
            let template = try ReaderBatterySVGTemplate(source: source)
            let rendered = try template.render(
                level: 0.72,
                isCharging: true,
                colorHex: "#112233FF"
            )

            #expect(rendered.contains(">72%</text>"))
            #expect(rendered.contains("color=\"#112233FF\""))
        }
    }

    @Test("Injects a stable viewBox from positive pixel dimensions")
    func injectsViewBoxFromDimensions() throws {
        let template = try ReaderBatterySVGTemplate(
            source: #"<svg width="120px" height="48"><rect width="120" height="48"/></svg>"#
        )

        #expect(template.validatedSource.contains(#"viewBox="0 0 120 48""#))
    }

    @Test("Rejects executable and unknown elements", arguments: [
        "script", "foreignObject", "iframe", "object", "embed", "animate", "filter", "image"
    ])
    func rejectsForbiddenElements(element: String) {
        let source = #"<svg viewBox="0 0 100 40"><\#(element)/></svg>"#

        #expect(throws: ReaderBatterySVGError.forbiddenElement(element)) {
            try ReaderBatterySVGTemplate(source: source)
        }
    }

    @Test("Rejects event and unknown attributes")
    func rejectsUnsafeAttributes() {
        #expect(throws: ReaderBatterySVGError.forbiddenAttribute("onclick")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40"><rect onclick="alert(1)"/></svg>"#
            )
        }
        #expect(throws: ReaderBatterySVGError.forbiddenAttribute("data-other")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40"><rect data-other="value"/></svg>"#
            )
        }
        #expect(throws: ReaderBatterySVGError.forbiddenAttribute("data-yuedu-command")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40"><rect data-yuedu-command="run"/></svg>"#
            )
        }
    }

    @Test("Rejects external references and CSS")
    func rejectsExternalReferences() {
        let sources = [
            #"<svg viewBox="0 0 100 40"><linearGradient href="https://example.com/a.svg#g"/></svg>"#,
            #"<svg viewBox="0 0 100 40"><linearGradient xlink:href="//example.com/a.svg#g"/></svg>"#,
            #"<svg viewBox="0 0 100 40"><rect fill="url(https://example.com/fill.svg#g)"/></svg>"#,
            #"<svg viewBox="0 0 100 40"><rect style="fill: url('data:image/svg+xml;base64,AA')"/></svg>"#,
            #"<svg viewBox="0 0 100 40"><rect style="@import 'https://example.com/a.css'; fill: red"/></svg>"#,
            #"<svg viewBox="0 0 100 40"><rect style="fill:u\72l(\2f\2fevil.example/a.svg)"/></svg>"#
        ]

        for source in sources {
            #expect(throws: ReaderBatterySVGError.self) {
                try ReaderBatterySVGTemplate(source: source)
            }
        }
    }

    @Test("Allows internal references")
    func allowsInternalReferences() throws {
        let source = """
        <svg viewBox="0 0 100 40">
          <defs><linearGradient id="g"><stop offset="0" stop-color="currentColor"/></linearGradient></defs>
          <rect fill="url(#g)" width="100" height="40"/>
        </svg>
        """

        let template = try ReaderBatterySVGTemplate(source: source)
        #expect(template.validatedSource.contains(#"fill="url(#g)""#))
    }

    @Test("Rejects malformed, multiple-root, DTD, and entity documents")
    func rejectsUnsafeDocuments() {
        let documents = [
            #"<svg viewBox="0 0 100 40"><rect></svg>"#,
            #"<svg viewBox="0 0 100 40"/><svg viewBox="0 0 100 40"/>"#,
            #"<!DOCTYPE svg><svg viewBox="0 0 100 40"/>"#,
            #"<!DOCTYPE svg [<!ENTITY payload "unsafe">]><svg viewBox="0 0 100 40"><text>&payload;</text></svg>"#
        ]

        for source in documents {
            #expect(throws: ReaderBatterySVGError.self) {
                try ReaderBatterySVGTemplate(source: source)
            }
        }
    }

    @Test("Rejects missing or unstable coordinate systems")
    func rejectsInvalidCoordinateSystems() {
        let sources = [
            #"<svg><rect/></svg>"#,
            #"<svg viewBox="0 0 0 40"><rect/></svg>"#,
            #"<svg viewBox="0 0 -100 40"><rect/></svg>"#,
            #"<svg width="100%" height="40"><rect/></svg>"#,
            #"<svg width="10cm" height="40px"><rect/></svg>"#,
            #"<svg width="100" height="0"><rect/></svg>"#
        ]

        for source in sources {
            #expect(throws: ReaderBatterySVGError.self) {
                try ReaderBatterySVGTemplate(source: source)
            }
        }
    }

    @Test("Rejects coordinate systems whose clip arithmetic would overflow")
    func rejectsOverflowingCoordinateSystems() throws {
        let source = """
        <svg viewBox="1.7e308 1.7e308 1.7e308 1.7e308">
          <rect data-yuedu-role="battery-level" data-yuedu-direction="right-to-left"/>
        </svg>
        """

        #expect(throws: ReaderBatterySVGError.invalidViewBox) {
            try ReaderBatterySVGTemplate(source: source)
        }

        let stable = try ReaderBatterySVGTemplate(
            source: #"<svg viewBox="-1.7e308 0 1.7e308 40"><rect data-yuedu-role="battery-level" data-yuedu-direction="right-to-left"/></svg>"#
        )
        let rendered = try stable.render(level: 0.37, isCharging: false, colorHex: "#112233FF").lowercased()
        #expect(!rendered.contains("inf"))
        #expect(!rendered.contains("nan"))
    }

    @Test("Rejects every undocumented direction")
    func rejectsInvalidDirection() {
        #expect(throws: ReaderBatterySVGError.invalidDirection("rtl")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40"><rect data-yuedu-role="battery-level" data-yuedu-direction="rtl"/></svg>"#
            )
        }
    }

    @Test("Rejects dynamic visibility and level markers on the document root")
    func rejectsRootMarkers() {
        #expect(throws: ReaderBatterySVGError.invalidRole("battery-level")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40" data-yuedu-role="battery-level"/>"#
            )
        }
        #expect(throws: ReaderBatterySVGError.invalidVisibility("charging")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40" data-yuedu-visible="charging"/>"#
            )
        }
        #expect(throws: ReaderBatterySVGError.invalidRole("battery-level")) {
            try ReaderBatterySVGTemplate(
                source: #"<svg viewBox="0 0 100 40"><defs><rect data-yuedu-role="battery-level"/></defs></svg>"#
            )
        }
    }

    @Test("Clips all four directions at boundary and partial levels", arguments: [
        ("left-to-right", 0.0, "0", "0", "0", "40"),
        ("left-to-right", 0.37, "0", "0", "37", "40"),
        ("left-to-right", 1.0, "0", "0", "100", "40"),
        ("right-to-left", 0.0, "100", "0", "0", "40"),
        ("right-to-left", 0.37, "63", "0", "37", "40"),
        ("right-to-left", 1.0, "0", "0", "100", "40"),
        ("bottom-to-top", 0.0, "0", "40", "100", "0"),
        ("bottom-to-top", 0.37, "0", "25.2", "100", "14.8"),
        ("bottom-to-top", 1.0, "0", "0", "100", "40"),
        ("top-to-bottom", 0.0, "0", "0", "100", "0"),
        ("top-to-bottom", 0.37, "0", "0", "100", "14.8"),
        ("top-to-bottom", 1.0, "0", "0", "100", "40")
    ])
    func clipsDirection(
        direction: String,
        level: Double,
        x: String,
        y: String,
        width: String,
        height: String
    ) throws {
        let source = """
        <svg viewBox="0 0 100 40">
          <rect data-yuedu-role="battery-level" data-yuedu-direction="\(direction)" width="100" height="40"/>
          <text data-yuedu-role="battery-percent">old</text>
        </svg>
        """
        let template = try ReaderBatterySVGTemplate(source: source)

        let rendered = try template.render(level: level, isCharging: false, colorHex: "#112233FF")

        #expect(rendered.contains(#"<rect height="\#(height)" width="\#(width)" x="\#(x)" y="\#(y)"/>"#))
        #expect(rendered.contains(">\(Int((level * 100).rounded()))%</text>"))
    }

    @Test("Rendering changes only marked percentage and charging visibility")
    func rendersDynamicTextAndChargingVisibility() throws {
        let source = """
        <svg viewBox="0 0 100 40">
          <text>unchanged &amp; safe</text>
          <text data-yuedu-role="battery-percent">old <tspan>nested</tspan></text>
          <path data-yuedu-visible="charging" d="M0 0L1 1"/>
        </svg>
        """
        let template = try ReaderBatterySVGTemplate(source: source)

        let idle = try template.render(level: 0.37, isCharging: false, colorHex: "#112233FF")
        let charging = try template.render(level: 0.37, isCharging: true, colorHex: "#112233FF")

        #expect(idle.contains("unchanged &amp; safe"))
        #expect(idle.contains(">37%</text>"))
        #expect(!idle.contains("M0 0L1 1"))
        #expect(charging.contains("M0 0L1 1"))
        #expect(!idle.contains("data-yuedu-"))
        #expect(!charging.contains("data-yuedu-"))
        #expect(charging.contains("color=\"#112233FF\""))
    }

    @Test("Battery clipping preserves an existing artwork clip")
    func preservesExistingArtworkClip() throws {
        let source = """
        <svg viewBox="0 0 100 40">
          <defs><clipPath id="artwork"><rect width="80" height="30"/></clipPath></defs>
          <path data-yuedu-role="battery-level" clip-path="url(#artwork)" d="M0 0H100V40H0Z"/>
        </svg>
        """
        let template = try ReaderBatterySVGTemplate(source: source)

        let rendered = try template.render(level: 0.5, isCharging: false, colorHex: "#112233FF")

        #expect(rendered.contains(#"<g clip-path="url(#yuedu-battery-level-clip)"><path clip-path="url(#artwork)""#))
    }

    @Test("Generated clip IDs avoid dangling internal reference targets")
    func generatedClipIDAvoidsDanglingReferences() throws {
        let source = """
        <svg viewBox="0 0 100 40">
          <defs><linearGradient href="#yuedu-battery-level-clip-2" id="gradient"/></defs>
          <rect clip-path="url(#yuedu-battery-level-clip)" width="100" height="40"/>
          <rect data-yuedu-role="battery-level" width="100" height="40"/>
        </svg>
        """
        let template = try ReaderBatterySVGTemplate(source: source)

        let rendered = try template.render(level: 0.5, isCharging: false, colorHex: "#112233FF")

        #expect(rendered.contains(#"<clipPath id="yuedu-battery-level-clip-3">"#))
        #expect(rendered.contains(#"<g clip-path="url(#yuedu-battery-level-clip-3)">"#))
        #expect(rendered.contains(#"clip-path="url(#yuedu-battery-level-clip)""#))
        #expect(rendered.contains("href=\"#yuedu-battery-level-clip-2\""))
        #expect(!rendered.contains(#"id="yuedu-battery-level-clip""#))
        #expect(!rendered.contains(#"id="yuedu-battery-level-clip-2""#))
    }

    @Test("Serialization is deterministic and escapes XML")
    func serializationIsDeterministicAndEscaped() throws {
        let source = """
        <svg height="40" width="100">
          <title>A &amp; B &lt; C</title>
          <text y="2" x="1">&quot;quoted&quot; &amp; 'safe'</text>
        </svg>
        """

        let first = try ReaderBatterySVGTemplate(source: source)
        let second = try ReaderBatterySVGTemplate(source: first.validatedSource)
        let rendered = try first.render(level: 0.5, isCharging: false, colorHex: "#AABBCCDD")

        #expect(first.validatedSource == second.validatedSource)
        #expect(first.validatedSource.contains(#"<svg height="40" viewBox="0 0 100 40" width="100">"#))
        #expect(first.validatedSource.contains(#"<text x="1" y="2">&quot;quoted&quot; &amp; &apos;safe&apos;</text>"#))
        #expect(rendered.contains("color=\"#AABBCCDD\""))
    }

    @Test("Rejects invalid colors and nonfinite levels")
    func rejectsInvalidRenderInputs() throws {
        let template = try ReaderBatterySVGTemplate(source: #"<svg viewBox="0 0 100 40"/>"#)

        #expect(throws: ReaderBatterySVGError.invalidColor("#123456")) {
            try template.render(level: 0.5, isCharging: false, colorHex: "#123456")
        }
        #expect(throws: ReaderBatterySVGError.invalidLevel) {
            try template.render(level: .nan, isCharging: false, colorHex: "#112233FF")
        }
    }

    @Test("Enforces source, depth, and node limits")
    func enforcesResourceLimits() {
        let oversized = "<svg viewBox=\"0 0 1 1\"><desc>" + String(repeating: "a", count: 262_145) + "</desc></svg>"
        let tooDeep = "<svg viewBox=\"0 0 1 1\">" + String(repeating: "<g>", count: 64)
            + String(repeating: "</g>", count: 64) + "</svg>"
        let tooManyNodes = "<svg viewBox=\"0 0 1 1\">" + String(repeating: "<g/>", count: 10_000) + "</svg>"

        #expect(throws: ReaderBatterySVGError.sourceTooLarge) {
            try ReaderBatterySVGTemplate(source: oversized)
        }
        #expect(throws: ReaderBatterySVGError.maximumDepthExceeded) {
            try ReaderBatterySVGTemplate(source: tooDeep)
        }
        #expect(throws: ReaderBatterySVGError.maximumNodeCountExceeded) {
            try ReaderBatterySVGTemplate(source: tooManyNodes)
        }
    }
}
