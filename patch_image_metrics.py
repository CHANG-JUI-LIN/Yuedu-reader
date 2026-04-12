import sys

file_path = "yuedu app/Models/CoreText/HTMLAttributedStringBuilder.swift"

with open(file_path, "r") as f:
    content = f.read()

# 1. Replace makeParagraphStyle
old_style_block = """        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }"""

new_style_block = """        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        
        paragraph.minimumLineHeight = lineHeight
        
        // ⚠️【關鍵修復 3】：將 maximumLineHeight 設為 0 (或直接刪除這行)
        // 否則 CoreText 遇到帶圖片的段落，會強制把那行裁切成純文字的高度，導致圖片消失或重疊
        paragraph.maximumLineHeight = 0 
        
        return paragraph
    }"""

if old_style_block in content:
    content = content.replace(old_style_block, new_style_block)
    print("makeParagraphStyle replaced")
else:
    print("makeParagraphStyle block not found!")


# 2. Replace resolvedImageMetrics
old_metrics_block = """    private func resolvedImageMetrics(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle
    ) -> ImageMetrics {
        let maxWidth = config.renderWidth
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        if let image {
            if let explicitWidth = style.width, let explicitHeight = style.height {
                drawWidth = explicitWidth
                drawHeight = explicitHeight
            } else if let explicitWidth = style.width {
                let ratio = max(0.01, explicitWidth / max(image.size.width, 1))
                drawWidth = explicitWidth
                drawHeight = image.size.height * ratio
            } else {
                let resolvedHeight = style.height ?? image.size.height
                let ratio = max(0.01, resolvedHeight / max(image.size.height, 1))
                drawWidth = image.size.width * ratio
                drawHeight = resolvedHeight
            }
        } else {
            let fallbackHeight = style.height ?? (maxWidth * 0.6)
            drawWidth = min(maxWidth, style.width ?? fallbackHeight)
            drawHeight = fallbackHeight
        }
        let totalWidth = min(maxWidth, drawWidth + style.paddingLeft + style.paddingRight)
        let font = makeFont(from: style, config: config)
        let lineHeight = max(style.fontSize, font.lineHeight)
        let verticalSlack = max(0, lineHeight - drawHeight)
        let ascent = min(lineHeight, drawHeight + verticalSlack * 0.7)
        let descent: CGFloat = max(0, lineHeight - ascent)
        return ImageMetrics(
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            totalWidth: totalWidth,
            ascent: ascent,
            descent: descent
        )
    }"""

new_metrics_block = """    private func resolvedImageMetrics(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle
    ) -> ImageMetrics {
        // 1. 計算可用最大寬度（螢幕寬度扣除左右 Padding）
        let maxDrawWidth = max(1, config.renderWidth - style.paddingLeft - style.paddingRight)
        
        var dWidth: CGFloat
        var dHeight: CGFloat
        
        // 2. 獲取初始尺寸
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
        
        // ⚠️【關鍵修復 1】：等比例縮放圖片，確保絕對不會超出螢幕寬度
        if dWidth > maxDrawWidth {
            let scale = maxDrawWidth / max(dWidth, 1)
            dWidth = maxDrawWidth
            dHeight = dHeight * scale
        }
        
        let drawWidth = dWidth
        let drawHeight = dHeight
        let totalWidth = drawWidth + style.paddingLeft + style.paddingRight
        
        let font = makeFont(from: style, config: config)
        let lineHeight = max(style.fontSize, font.lineHeight)
        
        // ⚠️【關鍵修復 2】：不要用 min() 把圖片壓成單行字高！
        // 必須讓 CTRunDelegate 根據圖片的實際高度撐開排版空間
        let ascent: CGFloat
        let descent: CGFloat
        if drawHeight > lineHeight {
            // 如果圖片比字還要高，全部交給 Ascent 撐開
            ascent = drawHeight
            descent = 0
        } else {
            // 如果是行內小圖示（比字矮），稍微做對齊調整
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

if old_metrics_block in content:
    content = content.replace(old_metrics_block, new_metrics_block)
    print("resolvedImageMetrics replaced")
else:
    print("resolvedImageMetrics block not found!")

with open(file_path, "w") as f:
    f.write(content)

