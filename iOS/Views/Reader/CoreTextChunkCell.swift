import CoreText
import UIKit

/// 顯示單塊 CoreText 切片的 cell。內含 `CoreTextChunkDrawView` 自繪。
final class CoreTextChunkCell: UITableViewCell {
    static let reuseIdentifier = "CoreTextChunkCell"

    let drawView = CoreTextChunkDrawView()
    let overlay = InteractionOverlayView()
    private var leftConstraint: NSLayoutConstraint!
    private var rightConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private(set) var currentChunk: CoreTextChunk?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        drawView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(drawView)
        contentView.addSubview(overlay)
        leftConstraint = drawView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        rightConstraint = drawView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        topConstraint = drawView.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            drawView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftConstraint,
            rightConstraint,
            overlay.leadingAnchor.constraint(equalTo: drawView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: drawView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: drawView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: drawView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(chunk: CoreTextChunk, horizontalInset: CGFloat, topSpacing: CGFloat) {
        leftConstraint.constant = horizontalInset
        rightConstraint.constant = -horizontalInset
        topConstraint.constant = topSpacing
        currentChunk = chunk
        drawView.chunk = chunk
        drawView.setNeedsDisplay()
        overlay.clearSelection()
    }

    /// 由 VC 推進來：對應的章節範圍若與本 chunk 有交集就畫反白
    func applySelection(chapterIndex: Int, chapterRange: NSRange?) {
        guard let chunk = currentChunk else { overlay.clearSelection(); return }
        guard let range = chapterRange, chunk.chapterIndex == chapterIndex, range.length > 0 else {
            overlay.clearSelection()
            return
        }
        let rects = chunk.selectionRects(forChapterRange: range)
        if rects.isEmpty { overlay.clearSelection(); return }
        overlay.selectionRects = rects

        // 判斷本 chunk 是否包含起點 / 終點，包含才畫對應端的圓點
        let chunkStart = chunk.charRange.location
        let chunkEnd = chunk.charRange.location + chunk.charRange.length
        let selStart = range.location
        let selEnd = range.location + range.length - 1
        let containsStart = selStart >= chunkStart && selStart < chunkEnd
        let containsEnd = selEnd >= chunkStart && selEnd < chunkEnd
        overlay.startHandlePoint = containsStart ? rects.first.map { CGPoint(x: $0.minX, y: $0.maxY) } : nil
        overlay.endHandlePoint = containsEnd ? rects.last.map { CGPoint(x: $0.maxX, y: $0.maxY) } : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        drawView.chunk?.evictFrame()
        drawView.chunk = nil
        currentChunk = nil
        overlay.clearSelection()
    }
}

/// 真正畫 CTFrame 的 view。座標系翻轉於此處理。
final class CoreTextChunkDrawView: UIView {
    var chunk: CoreTextChunk?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let chunk = chunk else { return }

        // 純圖 chunk（封面 / 整頁插圖）：跳過 CTFrame，直接畫附件
        if chunk.isImageOnly {
            for attachment in chunk.attachments {
                attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
            }
            return
        }

        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        chunk.materializeFrameIfNeeded()
        guard let frame = chunk.frame else { return }

        // 1) 文字（CoreText：原點左下 → 翻轉繪圖）
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()

        // 2) 圖片（UIKit 座標，原點左上）。CTFrame 已預留空白，我們把圖填上去。
        for attachment in chunk.attachments {
            attachment.image.draw(in: attachment.rect, blendMode: .normal, alpha: attachment.opacity)
        }
    }
}
