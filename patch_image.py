import re

file_path = "yuedu app/Models/CoreText/HTMLAttributedStringBuilder.swift"
with open(file_path, "r") as f:
    code = f.read()

resolved_image_metrics_new = """    private func resolvedImageMetrics(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle
    ) -> ImageMetrics {
        // 1. 計算可用最大寬度
        let maxDrawWidth = max(1, config.renderWidth - style.paddingLeft - style.paddingRight)
        // ⚠️ 預估最大安全高度，防止直式長圖超出螢幕上下邊界 (以寬度的 1.5 倍為極限)
        let maxDrawHeight = max(1, config.renderWidth * 1.5)
        
        var dWidth: CGFloat
        var dHeight: CGFloat
        
        if let image {
            if let explicitWidth = style.width, let explicitHeight = style.height {
                dWidth = explicitWidth
                dHeight = explicitHeight
            } else if let explicitWidth = style.width {
                let ratio = explicitWidth / max(image.size.width, 1)
                dWidth = explicitWidth
                dHeight = image.size.height * ratio
            } else if let explicitHeight = style.height {
                let ratio = explicitHeight / max(image.size.height, 1)
                dWidth = image.size.width * ratio
                dHeight = explicitHeight
            } else {
                dWidth = image.size.width
                dHeight = image.size.height
            }
        } else {
            let fallbackHeight = style.height ?? (maxDrawWidth * 0.6)
            dWidth = style.width ?? maxDrawWidth
            dHeight = fallbackHeight
        }
        
        // ⚠️【關鍵修復 3】：雙重限制，寬度與高度都不可越界
        // 先限制寬度
        if dWidth > maxDrawWidth {
            let scale = maxDrawWidth / max(dWidth, 1)
            dWidth = maxDrawWidth
            dHeight = dHeight * scale
        }
        // 再限制高度
        if dHeight > maxDrawHeight {
            let scale = maxDrawHeight / max(dHeight, 1)
            dHeight = maxDrawHeight
            dWidth = dWidth * scale
        }
        
        let drawWidth = dWidth
        let drawHeight = dHeight
        let totalWidth = drawWidth + style.paddingLeft + style.paddingRight
        
        let font = makeFont(from: style, config: config)
        let lineHeight = max(style.fontSize, font.lineHeight)
        
        let ascent: CGFloat
        let descent: CGFloat
        if drawHeight > lineHeight {
            ascent = drawHeight
            descent = 0
        } else {
            let verticalSlack = lineHeight - drawHeight
            ascent = drawHeight + verticalSlack * 0.7
            descent = verticalSlack * 0.3
        }
        
        return ImageMetrics(
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            totalWidth: totalWidth,
            ascent: ascent,
            descent: descent
        )
    }"""

old_pattern = re.compile(r'    private func resolvedImageMetrics\(\s*image: UIImage\?,\s*config: Config,\s*style: ResolvedStyle\s*\) -> ImageMetrics \{[\s\S]*?return ImageMetrics\(\s*drawWidth: drawWidth,\s*drawHeight: drawHeight,\s*totalWidth: totalWidth,\s*ascent: ascent,\s*descent: descent\s*\)\s*\}')

code = old_pattern.sub(resolved_image_metrics_new, code)

with open(file_path, "w") as f:
    f.write(code)

