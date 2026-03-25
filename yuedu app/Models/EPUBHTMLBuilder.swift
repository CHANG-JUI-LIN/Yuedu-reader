import Foundation
import UIKit

struct EPUBHTMLConfig {
    let viewportSize: CGSize
    let marginH: Int
    let marginV: Int
    let theme: String
    let fontSize: CGFloat
    let isEPUB: Bool
    let scrollModeEnabled: Bool
    let safeAreaInsets: UIEdgeInsets
    let footerHeight: CGFloat
}

struct EPUBHTMLBuilder {
    
    // MARK: - HTML 建構

    static func buildChapterHTML(
        chapter: EPUBChapterRaw,
        bridgeName: String,
        config: EPUBHTMLConfig
    ) -> String {
        let bookCSS = chapter.cssEntries.map { entry in
            rewriteCSSURLs(entry.content, cssBaseDir: entry.baseDir)
        }.joined(separator: "\n")
        return buildChapterHTML(
            chapterHTML: chapter.html,
            chapterBaseURL: chapter.baseURL,
            bridgeName: bridgeName,
            inlineBookCSS: bookCSS,
            config: config
        )
    }

    static func buildChapterHTML(
        chapterHTML: String,
        chapterBaseURL: URL,
        bridgeName: String,
        inlineBookCSS: String = "",
        config: EPUBHTMLConfig
    ) -> String {
        let size = config.viewportSize == .zero ? UIScreen.main.bounds.size : config.viewportSize
        let marginH = config.marginH
        let marginV = config.marginV
        let (bgColor, textColor) = themeColors(config.theme)
        let useReadiumCSS = config.isEPUB
        let adapterCSS = useReadiumCSS ? "" : ReaderAdapterAssets.css()
        let adapterJS = useReadiumCSS ? "" : ReaderAdapterAssets.javaScript()
        let adapterCSSBlock = adapterCSS.isEmpty ? "" : "<style>\(adapterCSS)</style>"
        let adapterJSBlock = adapterJS.isEmpty ? "" : "<script>\(adapterJS)</script>"

        let bodyContent = extractBodyContent(chapterHTML)
        let headContent = extractHeadContent(chapterHTML)
        let bodyAttributes = useReadiumCSS ? extractBodyAttributes(chapterHTML) : ""
        let bodyTagAttributes = bodyAttributes.isEmpty ? "" : " \(bodyAttributes)"
        let wrappedBodyContent: String
        if useReadiumCSS {
            wrappedBodyContent = bodyContent
        } else if bodyContent.contains("id=\"reader-content\"") {
            wrappedBodyContent = bodyContent
        } else {
            wrappedBodyContent = "<div id=\"reader-content\">\(bodyContent)</div>"
        }

        let layoutConfigJS = layoutConfigJSLiteral(marginH: marginH, marginV: marginV, config: config)
        let layoutBootstrapJS = useReadiumCSS ? "" : "applyReaderLayoutConfig(\(layoutConfigJS));"

        let viewportWidth = max(Int(size.width.rounded(.down)), 1)
        let topPadding = max(Int(config.safeAreaInsets.top.rounded(.up)) + 6, marginV)
        let bottomPadding = max(
            Int(config.safeAreaInsets.bottom.rounded(.up)) + Int(config.footerHeight.rounded(.up)),
            marginV
        )

        let readiumBeforeCSS: String
        let readiumDefaultCSS: String
        let readiumAfterCSS: String
        let htmlAttrs: String
        if useReadiumCSS {
            let fontSizePct = "\(Int(config.fontSize / 16.0 * 100))%"
            let readiumTheme: String
            switch config.theme {
            case "night": readiumTheme = "readium-night-on"
            case "sepia": readiumTheme = "readium-sepia-on"
            default: readiumTheme = "readium-default-on"
            }
            let bundle = ReadiumCSSLoader.bundle(
                configuration: ReadiumCSSConfiguration(
                    fontSize: fontSizePct,
                    lineHeight: "1.6",
                    theme: readiumTheme,
                    colWidth: viewportWidth,
                    pageGutter: marginH,
                    scroll: config.scrollModeEnabled
                )
            )
            readiumBeforeCSS = bundle.beforeStyleTag
            readiumDefaultCSS = bundle.defaultStyleTag
            readiumAfterCSS = bundle.afterStyleTag
            htmlAttrs = bundle.htmlAttributes.attributeString()
        } else {
            readiumBeforeCSS = ""
            readiumDefaultCSS = ""
            readiumAfterCSS = ""
            htmlAttrs = ""
        }

        let inlineLayoutCSS: String
        if useReadiumCSS {
            inlineLayoutCSS = """
            html {
                height: 100%;
                margin: 0;
                padding: 0;
                overflow: hidden;
                background: \(bgColor);
                color: \(textColor);
            }
            body {
                height: 100vh;
                margin: 0;
                overflow: visible;
                padding-top: \(topPadding)px !important;
                padding-bottom: \(bottomPadding)px !important;
                box-sizing: border-box;
            }
            img, video, audio, object, svg {
                max-width: 100% !important;
                height: auto;
                display: block;
                break-inside: avoid;
                margin-left: auto;
                margin-right: auto;
            }
            @page { margin: 0 !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important;
                min-height: 0 !important;
                max-height: none !important;
            }
            """
        } else {
            inlineLayoutCSS = """
            html {
                height: 100%; margin: 0; padding: 0; overflow: hidden;
                background: \(bgColor);
            }
            body {
                height: 100%;
                margin: 0 !important;
                overflow: visible !important;
                background: \(bgColor);
                -webkit-column-width: \(viewportWidth)px !important;
                column-width: \(viewportWidth)px !important;
                -webkit-column-gap: 0 !important;
                column-gap: 0 !important;
                column-fill: auto !important;
                -webkit-column-fill: auto !important;
                padding-top: \(topPadding)px !important;
                padding-bottom: \(bottomPadding)px !important;
                padding-left: 0 !important;
                padding-right: 0 !important;
                box-sizing: border-box !important;
                color: \(textColor);
                font-size: \(Int(config.fontSize))px;
                line-height: 1.6;
                text-align: justify;
                text-justify: inter-ideograph;
                -webkit-text-size-adjust: none;
                word-break: break-word;
                overflow-wrap: break-word;
                hyphens: none;
                line-break: strict;
                text-rendering: optimizeLegibility;
            }
            img {
                max-width: 100% !important; height: auto; display: block;
                break-inside: avoid; page-break-inside: avoid; -webkit-column-break-inside: avoid;
            }
            svg { max-width: 100% !important; }
            @page { margin: 0 !important; }
            p, p[class], blockquote, blockquote[class], pre, pre[class],
            li, li[class], dd, dd[class], dt, dt[class], figcaption, figcaption[class] {
                line-height: 1.6 !important;
                margin-block-start: 0 !important; margin-block-end: 0.5em !important;
                padding-block-start: 0 !important; padding-block-end: 0 !important;
                height: auto !important; min-height: 0 !important; max-height: none !important;
                break-inside: auto !important; page-break-inside: auto !important;
                -webkit-column-break-inside: auto !important;
                widows: 1 !important; orphans: 1 !important;
                word-break: normal !important; overflow-wrap: anywhere !important;
                white-space: normal !important;
            }
            p, p[class] {
                text-indent: 2em !important;
                text-align: justify !important;
                text-justify: inter-ideograph !important;
            }
            p.lk, p.dibian, p[class~="lk"], p[class~="dibian"],
            p.normaltext2, p[class~="normaltext2"] {
                text-indent: 0 !important; text-align: right !important;
            }
            p.yingwen, p[class~="yingwen"] {
                text-indent: 0 !important; text-align: center !important;
            }
            div, div[class], section, section[class], article, article[class], figure, figure[class] {
                margin-block-start: 0 !important; margin-block-end: 0 !important;
                padding-block-start: 0 !important; padding-block-end: 0 !important;
                height: auto !important; min-height: 0 !important; max-height: none !important;
            }
            h1, h1[class], h2, h2[class], h3, h3[class],
            h4, h4[class], h5, h5[class], h6, h6[class] {
                break-after: avoid !important; break-inside: auto !important;
                page-break-inside: auto !important; -webkit-column-break-inside: auto !important;
                margin-block-start: 0.8em !important; margin-block-end: 0.4em !important;
                line-height: 1.4 !important; text-indent: 0 !important;
            }
            h1.title, h2.title, h3.title, h1.title1, h2.title1, h3.title1,
            h1.title2, h2.title2, h3.title2, h1.title3, h2.title3, h3.title3,
            h1.bqbt, h2.bqbt, h3.bqbt, .title, .title1, .title2, .title3, .bqbt {
                margin-block-start: 0 !important; margin-block-end: 0.6em !important;
            }
            body > *:first-child, #reader-content > *:first-child { margin-block-start: 0 !important; }
            body > *:last-child, #reader-content > *:last-child { margin-block-end: 0 !important; }
            body, html { max-width: none !important; max-height: none !important; position: static !important; }
            body > div, body > section, body > article,
            #reader-content > div, #reader-content > section {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                width: auto !important; max-width: 100% !important;
                margin: 0 !important; position: static !important; float: none !important;
            }
            #reader-content {
                padding-left: \(marginH)px !important; padding-right: \(marginH)px !important;
                padding-top: 0 !important; padding-bottom: 0 !important;
                box-sizing: border-box !important;
            }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                margin: 0 !important; padding: 0 !important; position: static !important;
            }
            """
        }

        return """
        <!DOCTYPE html>
        <html \(htmlAttrs)>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=\(viewportWidth), initial-scale=1.0, maximum-scale=1.0, user-scalable=no, shrink-to-fit=no, viewport-fit=cover">
        <base href="\(chapterBaseURL.absoluteString)">
        \(readiumBeforeCSS)
        \(headContent)
        \(inlineBookCSS.isEmpty ? "" : "<style>\\(inlineBookCSS)</style>")
        \(readiumDefaultCSS)
        \(adapterCSSBlock)
        <style>\(inlineLayoutCSS)</style>
        \(readiumAfterCSS)
        \(adapterJSBlock)
        </head>
        <body\(bodyTagAttributes)>
        \(wrappedBodyContent)
        <script>
        window.onerror = function(msg, url, line, col, error) {
            try {
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: "jsLog",
                    payload: { message: "Error: " + msg + " at " + line + ":" + col + " - " + (error ? error.stack : "") }
                });
            } catch (e) {}
        };
        window.addEventListener('unhandledrejection', function(event) {
            try {
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: "jsLog",
                    payload: { message: "Unhandled Rejection: " + event.reason }
                });
            } catch (e) {}
        });

        \(layoutBootstrapJS)

        // 跟手翻頁全域狀態
        var _currentLocalPage = 0;
        var _pageSpan = \(viewportWidth);
        var _totalPages = 1;
        var _pageOffsets = [0];
        var _isDragging = false;
        var _dragBaseScroll = 0;

        function _pageOffsetAt(n) {
            if (!_pageOffsets.length) return 0;
            if (n <= 0) return _pageOffsets[0] || 0;
            if (n >= _pageOffsets.length) return _pageOffsets[_pageOffsets.length - 1] || 0;
            return _pageOffsets[n] || 0;
        }

        function _markPagesForNodes(nodes, pageMap) {
            var currentScroll = window.scrollX || document.documentElement.scrollLeft || document.body.scrollLeft || 0;
            Array.from(nodes || []).forEach(function(el) {
                if (!el || !el.tagName) return;
                var tag = el.tagName.toLowerCase();
                if (['script', 'style', 'link', 'meta', 'br'].indexOf(tag) !== -1) return;
                var style = window.getComputedStyle(el);
                if (!style || style.display === 'none' || style.visibility === 'hidden') return;

                var rect = el.getBoundingClientRect();
                if (!rect || rect.height < 2 || rect.width < 2) return;

                var text = (el.innerText || el.textContent || '').replace(/\\s+/g, '');
                var isContentTag =
                    /^h[1-6]$/.test(tag)
                    || ['p', 'li', 'dt', 'dd', 'blockquote', 'pre', 'figcaption', 'address', 'img', 'svg', 'video', 'audio', 'object', 'canvas', 'figure', 'table', 'hr'].indexOf(tag) !== -1;
                if (!isContentTag && text.length === 0) return;

                var left = rect.left + currentScroll;
                var right = rect.right + currentScroll;
                var firstPage = Math.max(0, Math.floor(left / _pageSpan));
                var lastPage = Math.max(firstPage, Math.floor((Math.max(right - 1, left)) / _pageSpan));
                for (var page = firstPage; page <= lastPage; page += 1) {
                    pageMap[page] = true;
                }
            });
        }

        function _collectPageOffsets() {
            var pages = Object.create(null);
            _markPagesForNodes(
                document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,dt,dd,blockquote,pre,figcaption,address,img,svg,video,audio,object,canvas,figure,table,hr'),
                pages
            );

            if (Object.keys(pages).length === 0 && document.body) {
                _markPagesForNodes(document.body.children, pages);
            }

            var pageIndexes = Object.keys(pages)
                .map(function(value) { return parseInt(value, 10); })
                .filter(function(value) { return !isNaN(value) && value >= 0; })
                .sort(function(a, b) { return a - b; });

            if (pageIndexes.length === 0) {
                var sw = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth, _pageSpan);
                var fallbackCount = Math.max(1, Math.ceil(sw / _pageSpan));
                for (var i = 0; i < fallbackCount; i += 1) {
                    pageIndexes.push(i);
                }
            }

            return pageIndexes.map(function(index) { return index * _pageSpan; });
        }

        function getPaginationMetrics() {
            \(useReadiumCSS ? "" : "updateColumnWidth(\(Int(config.footerHeight)));")
            _pageSpan = Math.max(window.innerWidth, 1);
            _pageOffsets = _collectPageOffsets();
            _totalPages = Math.max(1, _pageOffsets.length);
            if (_currentLocalPage >= _totalPages) {
                _currentLocalPage = _totalPages - 1;
            }
            return { pageCount: _totalPages, pageOffsets: _pageOffsets };
        }

        function initLiveReader() {
            return getPaginationMetrics().pageCount;
        }

        function _scrollTo(x) {
            document.documentElement.scrollLeft = x;
            document.body.scrollLeft = x;
            window.scrollTo(x, 0);
        }

        function setPageOffset(dx) {
            if (!_isDragging) {
                _isDragging = true;
                _dragBaseScroll = _pageOffsetAt(_currentLocalPage);
            }
            var raw = _dragBaseScroll - dx;
            var maxScroll = _pageOffsetAt(_totalPages - 1);
            var clamped = Math.max(0, Math.min(raw, maxScroll));
            _scrollTo(clamped);

            var overflow = clamped - raw;
            if (Math.abs(overflow) > 1) {
                document.body.style.transition = 'none';
                document.body.style.transform = 'translateX(' + overflow + 'px)';
            } else {
                document.body.style.transform = 'none';
            }
        }

        function animateToPage(n, ms) {
            _isDragging = false;
            // 重置跨章拖動的 translateX
            if (ms > 0) {
                document.body.style.transition = 'transform ' + ms + 'ms ease-out';
            } else {
                document.body.style.transition = 'none';
            }
            document.body.style.transform = 'none';

            if (n >= 0 && n < _totalPages) _currentLocalPage = n;
            var target = _pageOffsetAt(n);
            if (ms > 0) {
                var start = document.documentElement.scrollLeft || document.body.scrollLeft || 0;
                var distance = target - start;
                if (Math.abs(distance) < 1) { _scrollTo(target); return; }
                var startTime = performance.now();
                function step(now) {
                    var elapsed = now - startTime;
                    var progress = Math.min(elapsed / ms, 1);
                    var eased = 1 - Math.pow(1 - progress, 3);
                    _scrollTo(start + distance * eased);
                    if (progress < 1) requestAnimationFrame(step);
                }
                requestAnimationFrame(step);
            } else {
                _scrollTo(target);
            }
        }

        function snapToPage(n) { animateToPage(n, 0); }

        function recalcPages() {
            return getPaginationMetrics().pageCount;
        }

        document.addEventListener('click', function(e) {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.\(bridgeName)) {
                return;
            }
            var interactive = e.target && e.target.closest
                ? e.target.closest('a, button, input, textarea, select, summary, label')
                : null;
            if (interactive) {
                return;
            }

            var x = e.clientX || 0;
            var y = e.clientY || 0;
            var w = Math.max(window.innerWidth, 1);
            var h = Math.max(window.innerHeight, 1);
            if (y < h * 0.1 || y > h * 0.9) {
                return;
            }

            var zone = 'center';
            if (x < w / 3) {
                zone = 'left';
            } else if (x > w * 2 / 3) {
                zone = 'right';
            }

            window.webkit.messageHandlers.\(bridgeName).postMessage({
                type: 'tap',
                payload: { zone: zone }
            });
        }, true);

        function gotoPage(index) {
            var targetX = _pageOffsetAt(index);
            window.scrollTo(targetX, 0);
        }

        // 初始化：等 fonts + images 載入後計算分頁並發送 renderReady 合約
        (function() {
            function calculateAndNotify() {
                var metrics = getPaginationMetrics();
                
                // 新的 Minimal Contract: renderReady 
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: 'renderReady',
                    payload: {
                        pageIndex: 0
                    }
                });
                
                // 相容舊架構的 paginationReady
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: 'paginationReady',
                    payload: {
                        pageCount: metrics.pageCount,
                        pageOffsets: metrics.pageOffsets
                    }
                });
            }

            function waitForWindowLoad() {
                return new Promise(function(resolve) {
                    if (document.readyState === 'complete') return resolve();
                    window.addEventListener('load', resolve, { once: true });
                });
            }

            function waitForFonts() {
                if (document.fonts && document.fonts.ready) return document.fonts.ready.catch(function(){});
                return Promise.resolve();
            }

            function waitForImages() {
                var imgs = Array.from(document.images);
                var imagePromises = imgs.map(function(img) {
                    if (img.complete) return Promise.resolve();
                    if (typeof img.decode === 'function') {
                        return img.decode().catch(function(){});
                    }
                    return new Promise(function(resolve) {
                        img.addEventListener('load', resolve, { once: true });
                        img.addEventListener('error', resolve, { once: true });
                    });
                });
                return Promise.all(imagePromises);
            }

            Promise.all([waitForWindowLoad(), waitForFonts(), waitForImages()]).then(calculateAndNotify).catch(calculateAndNotify);
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Scroll Mode HTML（上下滑動專用，無 CSS Column）

    static func buildScrollModeHTML(
        startChapterIndex: Int,
        chapterBodyHTML: String,
        chapterTitle: String,
        chapterBaseURL: URL,
        chapterHeadHTML: String = "",
        bodyAttributes: String = "",
        bridgeName: String,
        inlineBookCSS: String = "",
        config: EPUBHTMLConfig
    ) -> String {
        let size = config.viewportSize == .zero ? UIScreen.main.bounds.size : config.viewportSize
        let marginH = config.marginH
        let marginV = config.marginV
        let (bgColor, textColor) = themeColors(config.theme)
        let useReadiumCSS = config.isEPUB
        let adapterCSS = useReadiumCSS ? "" : ReaderAdapterAssets.css()
        let adapterCSSBlock = adapterCSS.isEmpty ? "" : "<style>\(adapterCSS)</style>"

        let viewportWidth = max(Int(size.width.rounded(.down)), 1)
        let topPadding = max(Int(config.safeAreaInsets.top.rounded(.up)) + 6, marginV)
        let bottomPadding = max(
            Int(config.safeAreaInsets.bottom.rounded(.up)) + Int(config.footerHeight.rounded(.up)),
            marginV
        )

        // Readium CSS 三明治注入（EPUB 專用）
        let readiumBeforeCSS: String
        let readiumDefaultCSS: String
        let readiumAfterCSS: String
        let htmlAttrs: String
        if useReadiumCSS {
            let fontSizePct = "\(Int(config.fontSize / 16.0 * 100))%"
            let readiumTheme: String
            switch config.theme {
            case "night": readiumTheme = "readium-night-on"
            case "sepia": readiumTheme = "readium-sepia-on"
            default: readiumTheme = "readium-default-on"
            }
            let bundle = ReadiumCSSLoader.bundle(
                configuration: ReadiumCSSConfiguration(
                    fontSize: fontSizePct,
                    lineHeight: "1.6",
                    theme: readiumTheme,
                    colWidth: viewportWidth,
                    pageGutter: marginH,
                    scroll: true
                )
            )
            readiumBeforeCSS = bundle.beforeStyleTag
            readiumDefaultCSS = bundle.defaultStyleTag
            readiumAfterCSS = bundle.afterStyleTag
            htmlAttrs = bundle.htmlAttributes.attributeString()
        } else {
            readiumBeforeCSS = ""
            readiumDefaultCSS = ""
            readiumAfterCSS = ""
            htmlAttrs = ""
        }

        let bodyContent: String
        if useReadiumCSS {
            bodyContent = chapterBodyHTML
        } else if chapterBodyHTML.contains("id=\"reader-content\"") {
            bodyContent = chapterBodyHTML
        } else {
            bodyContent = "<div id=\"reader-content\">\(chapterBodyHTML)</div>"
        }
        let bodyTagAttributes = bodyAttributes.isEmpty ? "" : " \(bodyAttributes)"

        // 滾動模式：EPUB 不再疊加自訂排版，只保留最小容器與安全邊界。
        let scrollInlineCSS: String
        if useReadiumCSS {
            scrollInlineCSS = """
            html {
                height: auto;
                margin: 0;
                padding: 0;
                overflow-x: hidden;
                overflow-y: auto;
                background: \(bgColor);
                color: \(textColor);
            }
            body {
                min-height: 100vh;
                margin: 0;
                padding-top: \(topPadding)px;
                padding-bottom: \(bottomPadding)px;
                box-sizing: border-box;
            }
            img, video, audio, object, svg {
                max-width: 100% !important;
                height: auto;
                display: block;
                break-inside: avoid;
                margin-left: auto;
                margin-right: auto;
            }
            @page { margin: 0 !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important;
                min-height: 0 !important;
                max-height: none !important;
            }
            #scroll-content { min-height: 100vh; }
            .chapter-container { box-sizing: border-box; }
            """
        } else {
            scrollInlineCSS = """
            html {
                height: auto !important; margin: 0; padding: 0;
                overflow-x: hidden !important; overflow-y: auto !important;
                background: \(bgColor);
            }
            body {
                height: auto !important; margin: 0 !important; overflow: visible !important;
                background: \(bgColor);
                column-width: auto !important; -webkit-column-width: auto !important;
                column-count: auto !important; -webkit-column-count: auto !important;
                padding-top: \(topPadding)px !important;
                padding-bottom: \(bottomPadding)px !important;
                padding-left: 0 !important; padding-right: 0 !important;
                box-sizing: border-box !important;
                color: \(textColor);
                font-size: \(Int(config.fontSize))px;
                line-height: 1.6; text-align: justify; text-justify: inter-ideograph;
                -webkit-text-size-adjust: none;
                word-break: break-word; overflow-wrap: break-word;
                hyphens: none; line-break: strict; text-rendering: optimizeLegibility;
            }
            #scroll-content { min-height: 100vh; }
            .chapter-container { padding-left: \(marginH)px; padding-right: \(marginH)px; box-sizing: border-box; }
            .chapter-title-bar {
                font-size: \(Int(config.fontSize) + 2)px; font-weight: bold;
                color: \(textColor); opacity: 0.5; padding: 1.5em 0 0.8em 0;
                text-align: center; text-indent: 0 !important;
            }
            .chapter-separator {
                border: none;
                border-top: 1px solid \(config.theme == "night" ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.1)");
                margin: 0 \(marginH)px;
            }
            img { max-width: 100% !important; height: auto; display: block; }
            svg { max-width: 100% !important; }
            p, p[class] {
                line-height: 1.6 !important; margin-block-start: 0 !important;
                margin-block-end: 0.5em !important;
                text-indent: 2em !important; text-align: justify !important;
            }
            h1, h2, h3, h4, h5, h6 {
                margin-block-start: 0.8em !important; margin-block-end: 0.4em !important;
                line-height: 1.4 !important; text-indent: 0 !important;
            }
            body > *:first-child, #reader-content > *:first-child,
            .chapter-body > *:first-child { margin-block-start: 0 !important; }
            body > *:last-child, #reader-content > *:last-child,
            .chapter-body > *:last-child { margin-block-end: 0 !important; }
            body, html { max-width: none !important; max-height: none !important; position: static !important; }
            .calibre, .calibre1, .calibre2, .calibre3, .calibre4, .calibre5,
            .calibre6, .calibre7, .calibre8, .calibre9, .calibre10 {
                height: auto !important; min-height: 0 !important; max-height: none !important;
                margin: 0 !important; padding: 0 !important; position: static !important;
            }
            """
        }

        return """
        <!DOCTYPE html>
        <html \(htmlAttrs)>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=\(viewportWidth), initial-scale=1.0, maximum-scale=1.0, user-scalable=no, shrink-to-fit=no, viewport-fit=cover">
        <base href="\(chapterBaseURL.absoluteString)">
        \(readiumBeforeCSS)
        \(chapterHeadHTML)
        \(inlineBookCSS.isEmpty ? "" : "<style>\\(inlineBookCSS)</style>")
        \(readiumDefaultCSS)
        \(adapterCSSBlock)
        <style>\(scrollInlineCSS)</style>
        \(readiumAfterCSS)
        </head>
        <body\(bodyTagAttributes)>
        <div id="scroll-content">
            <div class="chapter-container" data-chapter="\(startChapterIndex)" id="ch-\(startChapterIndex)">
                <div class="chapter-body">\(bodyContent)</div>
            </div>
        </div>
        <script>
        // ===== 上下滑動模式 JS Bridge =====
        var _scrollChapters = [\(startChapterIndex)];
        var _bridgeName = '\(bridgeName)';
        var _showChapterChrome = \(useReadiumCSS ? "false" : "true");

        function _postMessage(msg) {
            try { window.webkit.messageHandlers[_bridgeName].postMessage(msg); } catch(e) {}
        }

        // 注入章節到 DOM
        function _injectChapter(index, base64html, title, position) {
            if (document.getElementById('ch-' + index)) return -1; // 已存在

            var div = document.createElement('div');
            div.className = 'chapter-container';
            div.dataset.chapter = String(index);
            div.id = 'ch-' + index;

            var bodyDiv = document.createElement('div');
            bodyDiv.className = 'chapter-body';
            bodyDiv.innerHTML = decodeURIComponent(escape(window.atob(base64html)));

            if (_showChapterChrome) {
                var titleBar = document.createElement('div');
                titleBar.className = 'chapter-title-bar';
                titleBar.textContent = title;
                div.appendChild(titleBar);
            }
            div.appendChild(bodyDiv);

            var content = document.getElementById('scroll-content');
            var sep = null;
            if (_showChapterChrome) {
                sep = document.createElement('hr');
                sep.className = 'chapter-separator';
            }

            if (position === 'before') {
                var oldHeight = document.documentElement.scrollHeight;
                var oldScroll = window.scrollY || window.pageYOffset;
                content.insertBefore(div, content.firstChild);
                if (sep) content.insertBefore(sep, div.nextSibling);
                // 補償滾動位置，讓畫面不跳
                var newHeight = document.documentElement.scrollHeight;
                window.scrollTo(0, oldScroll + (newHeight - oldHeight));
            } else {
                if (sep) content.appendChild(sep);
                content.appendChild(div);
            }

            _scrollChapters.push(index);
            _scrollChapters.sort(function(a, b) { return a - b; });
            return document.documentElement.scrollHeight;
        }

        // 移除遠端章節（虛擬 DOM）
        function _removeChapter(index) {
            var el = document.getElementById('ch-' + index);
            if (!el) return;
            var isAbove = (el.offsetTop + el.offsetHeight) < (window.scrollY || 0);
            var removedHeight = el.offsetHeight;

            // 移除分隔線
            if (_showChapterChrome) {
                var prev = el.previousElementSibling;
                var next = el.nextElementSibling;
                if (next && next.className === 'chapter-separator') next.remove();
                else if (prev && prev.className === 'chapter-separator') prev.remove();
            }
            el.remove();

            // 如果移除的是上方章節，補償滾動位置
            if (isAbove) {
                window.scrollTo(0, Math.max(0, (window.scrollY || 0) - removedHeight));
            }

            _scrollChapters = _scrollChapters.filter(function(c) { return c !== index; });
        }

        // 回傳當前可見章節及進度
        function _getVisibleChapter() {
            var chapters = document.querySelectorAll('.chapter-container');
            var anchor = (window.scrollY || 0) + window.innerHeight * 0.3;
            var best = null;
            for (var i = 0; i < chapters.length; i++) {
                var ch = chapters[i];
                var top = ch.offsetTop;
                var bottom = top + ch.offsetHeight;
                if (anchor >= top && anchor <= bottom) {
                    var progress = Math.min(1, Math.max(0, (anchor - top) / Math.max(ch.offsetHeight, 1)));
                    best = { chapter: parseInt(ch.dataset.chapter), progress: progress };
                    break;
                }
            }
            if (!best && chapters.length > 0) {
                var last = chapters[chapters.length - 1];
                best = { chapter: parseInt(last.dataset.chapter), progress: 1.0 };
            }
            return best || { chapter: \(startChapterIndex), progress: 0 };
        }

        // 跳到指定章節
        function _scrollToChapter(index, progressInChapter) {
            var el = document.getElementById('ch-' + index);
            if (!el) return;
            var targetY = el.offsetTop;
            if (progressInChapter > 0) {
                targetY += el.offsetHeight * Math.min(1, progressInChapter);
            }
            window.scrollTo(0, targetY);
        }

        // 點擊區域偵測（上下滑動也需要點中間呼出工具列）
        document.addEventListener('click', function(e) {
            var x = e.clientX, w = window.innerWidth;
            var y = e.clientY, h = window.innerHeight;
            // 中間 1/3 區域
            if (x > w / 3 && x < w * 2 / 3 && y > h / 4 && y < h * 3 / 4) {
                _postMessage({ type: 'tap', payload: { zone: 'center' } });
            }
        }, true);

        function gotoPage(index) {
            window.scrollTo(0, 0);
        }
        function getPaginationMetrics() {
            return { pageCount: 1, pageOffsets: [0] };
        }

        // 通知 Swift ready
        (function() {
            function notifyReady() {
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: 'renderReady',
                    payload: { pageIndex: 0 }
                });
                window.webkit.messageHandlers.\(bridgeName).postMessage({
                    type: 'paginationReady',
                    payload: { pageCount: 1, scrollMode: true }
                });
            }
            
            function waitForWindowLoad() {
                return new Promise(function(resolve) {
                    if (document.readyState === 'complete') return resolve();
                    window.addEventListener('load', resolve, { once: true });
                });
            }

            function waitForFonts() {
                if (document.fonts && document.fonts.ready) return document.fonts.ready.catch(function(){});
                return Promise.resolve();
            }

            function waitForImages() {
                var imgs = Array.from(document.images);
                var imagePromises = imgs.map(function(img) {
                    if (img.complete) return Promise.resolve();
                    if (typeof img.decode === 'function') {
                        return img.decode().catch(function(){});
                    }
                    return new Promise(function(resolve) {
                        img.addEventListener('load', resolve, { once: true });
                        img.addEventListener('error', resolve, { once: true });
                    });
                });
                return Promise.all(imagePromises); // Promise.all(imagePromises)
            }

            Promise.all([waitForWindowLoad(), waitForFonts(), waitForImages()]).then(notifyReady).catch(notifyReady);
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Layout Config JS

    static func layoutConfigJSLiteral(marginH: Int, marginV: Int, config: EPUBHTMLConfig) -> String {
        let size = config.viewportSize == .zero ? UIScreen.main.bounds.size : config.viewportSize
        let viewportWidth = Int(size.width)
        let viewportHeight = Int(size.height)
        let pageWidth = viewportWidth
        let pageHeight = viewportHeight
        let pageSpan = viewportWidth

        return """
        {
            flow: 'horizontal',
            paginated: true,
            fontSize: \(Int(config.fontSize)),
            horizontalProfile: {
                geometry: {
                    strategy: 'paged-columns',
                    writingMode: 'horizontal-tb',
                    pageAxis: 'x',
                    pageProgression: 'ltr',
                    viewportWidth: \(viewportWidth),
                    viewportHeight: \(viewportHeight),
                    pageWidth: \(pageWidth),
                    pageHeight: \(pageHeight),
                    pageSpan: \(pageSpan),
                    pageInsetBlockStart: 0,
                    pageInsetBlockEnd: 0,
                    pageInsetInlineStart: 0,
                    pageInsetInlineEnd: 0,
                    columnGap: 0
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: \(marginV),
                    paddingHorizontal: \(marginH),
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.9,
                    headingTop: 0.75,
                    headingBottom: 0.42
                }
            },
            verticalProfile: {
                geometry: {
                    strategy: 'stacked-pages',
                    writingMode: 'horizontal-tb',
                    pageAxis: 'y',
                    pageProgression: 'ltr',
                    viewportWidth: \(viewportWidth),
                    viewportHeight: \(viewportHeight),
                    pageWidth: \(pageWidth),
                    pageHeight: \(pageHeight),
                    pageSpan: \(viewportHeight),
                    pageInsetBlockStart: 0,
                    pageInsetBlockEnd: 0,
                    pageInsetInlineStart: 0,
                    pageInsetInlineEnd: 0,
                    columnGap: 0
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: \(marginV),
                    paddingHorizontal: \(marginH),
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.82,
                    headingTop: 0.58,
                    headingBottom: 0.35
                }
            }
        }
        """
    }

    // MARK: - HTML 工具

    static func extractBodyContent(_ html: String) -> String {
        let lower = html.lowercased()
        if let bodyStart = lower.range(of: "<body"),
           let tagEnd = lower[bodyStart.upperBound...].range(of: ">")
        {
            let contentStart = tagEnd.upperBound
            if let bodyEnd = lower.range(of: "</body>") {
                let startIdx = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: contentStart))
                let endIdx = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: bodyEnd.lowerBound))
                return String(html[startIdx..<endIdx])
            }
        }
        return html
    }

    static func extractBodyAttributes(_ html: String) -> String {
        let lower = html.lowercased()
        guard let bodyStart = lower.range(of: "<body"),
              let tagEnd = lower[bodyStart.upperBound...].range(of: ">")
        else {
            return ""
        }

        let attrStart = html.index(
            html.startIndex,
            offsetBy: lower.distance(from: lower.startIndex, to: bodyStart.upperBound)
        )
        let attrEnd = html.index(
            html.startIndex,
            offsetBy: lower.distance(from: lower.startIndex, to: tagEnd.lowerBound)
        )
        return String(html[attrStart..<attrEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractHeadContent(_ html: String) -> String {
        let lower = html.lowercased()
        guard let headStart = lower.range(of: "<head"),
              let headTagEnd = lower[headStart.upperBound...].range(of: ">"),
              let headEnd = lower.range(of: "</head>")
        else {
            return ""
        }

        let contentStart = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: headTagEnd.upperBound))
        let contentEnd = html.index(html.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: headEnd.lowerBound))
        return String(html[contentStart..<contentEnd])
    }

    static func rewriteCSSURLs(_ css: String, cssBaseDir: URL) -> String {
        let pattern = #"url\\(\\s*(['"]?)([^)'"]+)\\1\\s*\\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return css }
        let ns = css as NSString
        var result = css
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let quoteRange = m.range(at: 1)
            let pathRange = m.range(at: 2)
            let fullRange = m.range
            let quote = ns.substring(with: quoteRange)
            let rawPath = ns.substring(with: pathRange)
            if rawPath.hasPrefix("data:") || rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") || rawPath.hasPrefix("file://") {
                continue
            }
            let resolved = cssBaseDir.appendingPathComponent(rawPath).standardized
            let replacement = "url(\(quote)\(resolved.absoluteString)\(quote))"
            let start = result.index(result.startIndex, offsetBy: fullRange.location)
            let end = result.index(start, offsetBy: fullRange.length)
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }

    // MARK: - 主題工具

    static func themeColors(_ theme: String) -> (bg: String, text: String) {
        switch theme {
        case "white": return ("#ffffff", "#333333")
        case "sepia": return ("#f4ecd8", "#5b4636")
        case "night": return ("#1a1a1a", "#d9d9d9")
        default: return ("#f4ecd8", "#5b4636")
        }
    }
}
