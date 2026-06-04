import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

// 暫時診斷：把直排頁面連同標註 highlight render 成圖，親眼看「上方空白」。
@Suite("VerticalRectDiag", .serialized)
struct VerticalRectDiagTests {

    @Test("render vertical page with highlight")
    func renderVerticalPageWithHighlight() async throws {
        let font = UIFont.systemFont(ofSize: 22)
        let p1 = NSMutableParagraphStyle()
        p1.paragraphSpacing = 14
        p1.lineSpacing = 4
        let p2 = NSMutableParagraphStyle()
        p2.paragraphSpacing = 14
        p2.lineSpacing = 4
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: "第一段甲乙丙丁戊己庚辛壬癸子丑\n", attributes: [.font: font, .paragraphStyle: p1]))
        m.append(NSAttributedString(string: "第二段寅卯辰巳午未申酉戌亥天地玄黃", attributes: [.font: font, .paragraphStyle: p2]))

        let renderSize = CGSize(width: 260, height: 380)
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: m,
            renderSize: renderSize,
            fontSize: 22,
            contentInsets: UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18),
            writingMode: .verticalRTL
        )

        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let range = layout.pageRanges[0]
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CoreTextPaginator.makeFrame(
            framesetter: layout.framesetter,
            range: range,
            path: path,
            writingMode: layout.writingMode
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        // 第二段全選的 highlight rects（UIKit 座標）
        let nsAll = layout.attributedString.string as NSString
        // highlight 第一段（含 \n 的那段，ascent 會被灌大）
        let p2Start = nsAll.range(of: "第二段").location
        let highlightRange = NSRange(location: 0, length: p2Start)
        let rects = CoreTextAnnotationRenderer.rects(
            forRange: highlightRange,
            lines: lines,
            lineOrigins: origins,
            contentOffset: CGPoint(x: contentPathRect.minX, y: contentPathRect.minY),
            layoutHeight: layout.renderSize.height,
            writingMode: .verticalRTL
        )

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { rctx in
            let ctx = rctx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: renderSize))

            // 畫文字（與 app 相同的翻轉）
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: renderSize.height)
            ctx.scaleBy(x: 1, y: -1)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()

            // 內容區框（藍）
            UIColor.systemBlue.withAlphaComponent(0.5).setStroke()
            ctx.stroke(CoreTextPaginator.uiContentRect(
                renderSize: layout.renderSize,
                contentInsets: layout.contentInsets,
                fontSize: layout.fontSize,
                writingMode: layout.writingMode
            ), width: 1)

            // highlight rects（紅 0.3）
            UIColor.red.withAlphaComponent(0.3).setFill()
            for r in rects { ctx.fill(r) }
        }

        let png = image.pngData()
        try? png?.write(to: URL(fileURLWithPath: "/tmp/vdiag.png"))

        var out = "highlightRange=\(highlightRange) p2Start=\(p2Start)\n"
        for (i, line) in lines.enumerated() {
            let lr = CTLineGetStringRange(line)
            out += "line=\(i) range=\(lr.location)..<\(lr.location + lr.length) origin=(\(origins[i].x),\(origins[i].y))\n"
        }
        out += "rects=\(rects)\n"
        try? out.write(toFile: "/tmp/vdiag_out.txt", atomically: true, encoding: .utf8)
    }
}
