import Foundation

extension EPUBTestFixtures {
    static func mathMLTypography() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "MathML Typography",
            language: "en",
            body: """
            <p id="identifier">Before <math display="inline" alttext="x"><mi>x</mi></math> after.</p>
            <p id="scripts"><math display="inline" alttext="x squared sub n"><msubsup><mi>x</mi><mi>n</mi><mn>2</mn></msubsup></math></p>
            <p id="fraction"><math display="inline" alttext="a over b"><mfrac><mi>a</mi><mi>b</mi></mfrac></math></p>
            <p id="root"><math display="inline" alttext="root x in parentheses"><mfenced><msqrt><mi>x</mi></msqrt></mfenced></math></p>
            <p id="matrix"><math display="block" alttext="two by two matrix"><mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr></mtable></math></p>
            <p id="wide" style="padding-left:24px;padding-right:24px"><math display="block" alttext="long aligned equation"><mrow><mi>abcdefghijklmnopqrstuvwxyz</mi><mo>=</mo><mi>abcdefghijklmnopqrstuvwxyz</mi></mrow></math></p>
            <p id="empty">Before <math display="inline" alttext="quadratic expression"></math> after.</p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    static func mathMLWithoutUsefulAlt() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "MathML Generic Fallback",
            language: "en",
            body: #"<p>Before <math display="inline" alttext="Alternative text not available"></math> after.</p>"#,
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    /// Reduced from IDPF `linear-algebra.epub`, chapter `fcla-xml-2.30li18.xhtml`,
    /// formula 479. The source table keeps the relation and the leading negative value in
    /// separate cells; flattening those cells must not turn the minus into an invalid binary atom.
    static func mathMLUnarySignAfterTableCell() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "MathML Table Cell Unary Sign",
            language: "en",
            body: """
            <p id="proof">
              <math display="block" alttext="implies negative two">
                <mtable>
                  <mtr>
                    <mtd><mo>⇒</mo></mtd>
                    <mtd><mo>−</mo><mn>2</mn></mtd>
                  </mtr>
                </mtable>
              </math>
            </p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }
}
