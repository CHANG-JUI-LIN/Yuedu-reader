import CoreText
import UIKit

/// 顯示單塊 CoreText 切片的 cell。內含 `CoreTextChunkDrawView` 自繪。
final class CoreTextChunkCell: UITableViewCell {
    static let reuseIdentifier = "CoreTextChunkCell"

    private let drawView = CoreTextChunkDrawView()
    private var leftConstraint: NSLayoutConstraint!
    private var rightConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        drawView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(drawView)
        leftConstraint = drawView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        rightConstraint = drawView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        topConstraint = drawView.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            drawView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftConstraint,
            rightConstraint
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func bind(chunk: CoreTextChunk, horizontalInset: CGFloat, topSpacing: CGFloat) {
        leftConstraint.constant = horizontalInset
        rightConstraint.constant = -horizontalInset
        topConstraint.constant = topSpacing
        drawView.chunk = chunk
        drawView.setNeedsDisplay()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 通知 chunk 釋放 frame（保留高度與 framesetter，下次重建）
        drawView.chunk?.evictFrame()
        drawView.chunk = nil
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
