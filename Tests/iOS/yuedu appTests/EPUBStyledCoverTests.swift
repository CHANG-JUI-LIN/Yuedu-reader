import Testing
import UIKit
@testable import yuedu_app

struct EPUBStyledCoverTests {
    @Test func detectsStyledSVGImageCoverPage() async {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in UIImage(systemName: "book") }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html>
          <body>
            <div style="text-align: center; padding: 0pt; margin: 0pt;">
              <svg viewBox="0 0 1000 1333">
                <image width="1000" height="1333" xlink:href="../Images/cover.jpg"/>
              </svg>
            </div>
          </body>
        </html>
        """

        let result = await builder.build(html: html, config: config)

        #expect(result.imagePage?.source == "../Images/cover.jpg")
    }
}
