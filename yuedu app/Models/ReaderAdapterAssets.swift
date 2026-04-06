import Foundation

/* DISABLED: WebView/TXT/HTML adapter assets temporarily removed pending CoreText migration

enum ReaderAdapterAssets {
    static func css() -> String {
        """
        :root {
            --reader-font-family: "PingFang SC", "PingFang TC", "Noto Sans CJK SC", "Noto Sans CJK TC", "Source Han Sans SC", "Microsoft YaHei", -apple-system, serif;
            --reader-font-size: 18px;
            --reader-line-height: 1.6;
            --reader-baseline: calc(var(--reader-font-size) * var(--reader-line-height));
            --reader-column-gap: 28px;
            --reader-padding-vertical: 20px;
            --reader-padding-horizontal: 18px;
            --reader-space-1: calc(var(--reader-baseline) * 0.5);
            --reader-space-2: calc(var(--reader-baseline) * 0.9);
            --reader-space-3: calc(var(--reader-baseline) * 1.4);
            --reader-text-color: #111111;
            --reader-bg-color: #ffffff;
            --reader-max-column-width: 720px;
            --reader-paragraph-indent: 2em;
            --reader-dropcap-size: 3.2em;
            --reader-footer-offset: 0px;
            --reader-viewport-height: 100vh;
            --reader-viewport-width: 100vw;
            --reader-page-width: 100vw;
            --reader-page-height: 100vh;
            --reader-page-span: 100vw;
            --reader-page-inset-block-start: 0px;
            --reader-page-inset-block-end: 0px;
            --reader-page-inset-inline-start: 0px;
            --reader-page-inset-inline-end: 0px;
            --reader-active-line-height: var(--reader-line-height);
            --reader-active-column-gap: var(--reader-column-gap);
            --reader-active-padding-vertical: var(--reader-padding-vertical);
            --reader-active-padding-horizontal: var(--reader-padding-horizontal);
            --reader-active-paragraph-indent: var(--reader-paragraph-indent);
            --reader-active-paragraph-spacing: var(--reader-space-2);
            --reader-active-heading-top: calc(var(--reader-baseline) * 0.75);
            --reader-active-heading-bottom: calc(var(--reader-baseline) * 0.42);
        }

        :root[data-reader-writing-mode="horizontal-tb"] body,
        :root[data-reader-writing-mode="horizontal-tb"] #reader-content {
            writing-mode: horizontal-tb;
        }

        :root[data-reader-writing-mode="vertical-rl"] body,
        :root[data-reader-writing-mode="vertical-rl"] #reader-content {
            writing-mode: vertical-rl;
        }

        :root[data-reader-writing-mode="vertical-lr"] body,
        :root[data-reader-writing-mode="vertical-lr"] #reader-content {
            writing-mode: vertical-lr;
        }

        html, body {
            height: 100%;
            width: 100%;
            margin: 0;
            padding: 0;
            background: var(--reader-bg-color);
            color: var(--reader-text-color);
            -webkit-text-size-adjust: 100%;
            box-sizing: border-box;
            -webkit-font-smoothing: antialiased;
            -moz-osx-font-smoothing: grayscale;
            text-rendering: optimizeLegibility;
        }

        body, #reader-content {
            font-family: var(--reader-font-family);
            font-size: var(--reader-font-size);
            line-height: var(--reader-active-line-height);
            color: inherit;
            background: transparent;
            word-break: break-word;
            overflow-wrap: break-word;
            hyphens: none;
            line-break: strict;
            hanging-punctuation: first allow-end last;
            font-kerning: normal;
        }

        #reader-content {
            box-sizing: border-box;
            padding-block-start: var(--reader-active-padding-vertical);
            padding-block-end: calc(var(--reader-active-padding-vertical) + env(safe-area-inset-bottom));
            padding-inline-start: max(var(--reader-active-padding-horizontal), env(safe-area-inset-left));
            padding-inline-end: max(var(--reader-active-padding-horizontal), env(safe-area-inset-right));
        }

        :root[data-reader-flow="vertical"] #reader-content,
        body.vertical-reader #reader-content {
            padding-bottom: calc(var(--reader-active-padding-vertical) + env(safe-area-inset-bottom));
        }

        :root[data-reader-page-axis="y"][data-reader-layout="paginated"] body.paginated-flow,
        :root[data-reader-page-axis="y"][data-reader-layout="paginated"] body {
            column-width: auto !important;
            -webkit-column-width: auto !important;
            column-gap: 0 !important;
            -webkit-column-gap: 0 !important;
            min-height: var(--reader-viewport-height) !important;
        }

        :root[data-reader-strategy="stacked-pages"][data-reader-layout="paginated"] body.paginated-flow,
        :root[data-reader-strategy="stacked-pages"][data-reader-layout="paginated"] body,
        :root[data-reader-strategy="continuous-flow"] body.paginated-flow,
        :root[data-reader-strategy="continuous-flow"] body {
            column-width: auto !important;
            -webkit-column-width: auto !important;
            column-gap: 0 !important;
            -webkit-column-gap: 0 !important;
        }

        :root[data-reader-strategy="stacked-pages"] body.paginated-flow #reader-content,
        :root[data-reader-strategy="stacked-pages"] body #reader-content,
        :root[data-reader-strategy="continuous-flow"] body.paginated-flow #reader-content,
        :root[data-reader-strategy="continuous-flow"] body #reader-content {
            padding: 0 !important;
            margin: 0 !important;
            height: auto !important;
            min-height: 0 !important;
            column-width: auto !important;
            column-gap: normal !important;
            column-fill: auto !important;
            break-inside: auto !important;
            -webkit-column-break-inside: auto !important;
        }

        :root[data-reader-flow="horizontal"][data-reader-layout="paginated"] body,
        :root[data-reader-flow="horizontal"] body.paginated-flow,
        body.horizontal-reader.paginated-flow,
        body.paginated-flow.horizontal-reader {
            text-rendering: optimizeLegibility;
        }

        :root[data-reader-flow="vertical"][data-reader-layout="paginated"] body #reader-content,
        :root[data-reader-flow="vertical"] body.paginated-flow #reader-content,
        body.vertical-reader.paginated-flow #reader-content {
            padding: 0 !important;
            margin: 0 !important;
        }

        #reader-content img,
        img {
            max-inline-size: 100%;
            block-size: auto;
            display: block;
            page-break-inside: avoid;
            -webkit-column-break-inside: avoid;
        }

        #reader-content h1,
        #reader-content h2,
        #reader-content h3,
        h1, h2, h3 {
            break-inside: auto;
            -webkit-column-break-inside: auto;
            break-after: avoid;
            margin-block-start: var(--reader-active-heading-top);
            margin-block-end: var(--reader-active-heading-bottom);
            margin-inline: 0;
            text-indent: 0;
            text-wrap: pretty;
        }

        #reader-content > h1:first-child,
        #reader-content > h2:first-child,
        #reader-content > h3:first-child,
        body > h1:first-child,
        body > h2:first-child,
        body > h3:first-child {
            margin-block-start: 0;
        }

        #reader-content blockquote,
        #reader-content pre,
        #reader-content table,
        blockquote, pre, table {
            margin-block-start: 0;
            margin-block-end: var(--reader-space-2);
            margin-inline: 0;
            break-inside: avoid;
            -webkit-column-break-inside: avoid;
            page-break-inside: avoid;
        }

        :root[data-reader-flow="vertical"] body #reader-content > :first-child,
        body.vertical-reader #reader-content > :first-child {
            margin-top: 0 !important;
        }

        #reader-content p,
        p {
            margin-block-start: 0;
            margin-block-end: var(--reader-active-paragraph-spacing);
            margin-inline: 0;
            text-indent: var(--reader-active-paragraph-indent);
            break-inside: auto;
            -webkit-column-break-inside: auto;
            widows: 1;
            orphans: 1;
        }

        .no-fancy * {
            transition: none !important;
            animation: none !important;
            filter: none !important;
            backface-visibility: hidden !important;
            will-change: auto !important;
            box-shadow: none !important;
        }

        :root[data-theme="dark"] {
            --reader-bg-color: #0b0b0b;
            --reader-text-color: #dddddd;
        }

        @media (max-width: 420px) {
            :root {
                --reader-font-size: 16px;
                --reader-column-gap: 18px;
                --reader-max-column-width: 420px;
            }
        }
        """
    }

    static func javaScript() -> String {
        """
        function getReaderRoot() {
            return document.documentElement;
        }

        function setReaderCSSVar(name, value, unit) {
            try {
                if (value === undefined || value === null || value === '') return;
                var normalized = typeof value === 'number' && unit ? (value + unit) : String(value);
                getReaderRoot().style.setProperty(name, normalized);
            } catch (e) {}
        }

        function pickReaderLayoutValue(primary, fallback) {
            return primary === undefined || primary === null || primary === '' ? fallback : primary;
        }

        function defaultReaderStrategy(paginated) {
            return paginated ? 'paged-columns' : 'continuous-flow';
        }

        var readerLayoutConfigState = null;

        function readerLegacyLayoutKey(prefix, key) {
            if (!prefix) return key;
            if (!key) return prefix;
            return prefix + key.charAt(0).toUpperCase() + key.slice(1);
        }

        function readLegacyReaderLayoutField(config, legacyPrefix, fieldKey, fallbackValue) {
            var legacyValue = config ? config[readerLegacyLayoutKey(legacyPrefix, fieldKey)] : undefined;
            return pickReaderLayoutValue(legacyValue, fallbackValue);
        }

        function resolveLegacyReaderProfileConfig(config, legacyPrefix, fallbackProfile, paginated) {
            config = config || {};
            var fallbackGeometry = fallbackProfile && fallbackProfile.geometry ? fallbackProfile.geometry : {};
            var fallbackTypography = fallbackProfile && fallbackProfile.typography ? fallbackProfile.typography : {};
            return {
                geometry: {
                    strategy: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'strategy',
                        pickReaderLayoutValue(fallbackGeometry.strategy, defaultReaderStrategy(paginated))
                    ),
                    writingMode: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'writingMode',
                        pickReaderLayoutValue(fallbackGeometry.writingMode, 'horizontal-tb')
                    ),
                    pageAxis: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageAxis',
                        pickReaderLayoutValue(fallbackGeometry.pageAxis, 'x')
                    ),
                    pageProgression: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageProgression',
                        pickReaderLayoutValue(fallbackGeometry.pageProgression, 'ltr')
                    ),
                    viewportWidth: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'viewportWidth',
                        fallbackGeometry.viewportWidth
                    ),
                    viewportHeight: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'viewportHeight',
                        fallbackGeometry.viewportHeight
                    ),
                    pageWidth: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageWidth',
                        fallbackGeometry.pageWidth
                    ),
                    pageHeight: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageHeight',
                        fallbackGeometry.pageHeight
                    ),
                    pageSpan: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageSpan',
                        fallbackGeometry.pageSpan
                    ),
                    pageInsetBlockStart: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageInsetBlockStart',
                        pickReaderLayoutValue(fallbackGeometry.pageInsetBlockStart, 0)
                    ),
                    pageInsetBlockEnd: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageInsetBlockEnd',
                        pickReaderLayoutValue(fallbackGeometry.pageInsetBlockEnd, 0)
                    ),
                    pageInsetInlineStart: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageInsetInlineStart',
                        pickReaderLayoutValue(fallbackGeometry.pageInsetInlineStart, 0)
                    ),
                    pageInsetInlineEnd: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'pageInsetInlineEnd',
                        pickReaderLayoutValue(fallbackGeometry.pageInsetInlineEnd, 0)
                    ),
                    columnGap: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'columnGap',
                        pickReaderLayoutValue(fallbackGeometry.columnGap, 0)
                    )
                },
                typography: {
                    lineHeight: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'lineHeight',
                        pickReaderLayoutValue(fallbackTypography.lineHeight, 1.6)
                    ),
                    paddingVertical: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'paddingVertical',
                        pickReaderLayoutValue(fallbackTypography.paddingVertical, 0)
                    ),
                    paddingHorizontal: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'paddingHorizontal',
                        pickReaderLayoutValue(fallbackTypography.paddingHorizontal, 0)
                    ),
                    paragraphIndent: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'paragraphIndent',
                        pickReaderLayoutValue(fallbackTypography.paragraphIndent, '2em')
                    ),
                    paragraphSpacing: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'paragraphSpacing',
                        pickReaderLayoutValue(fallbackTypography.paragraphSpacing, 0)
                    ),
                    headingTop: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'headingTop',
                        pickReaderLayoutValue(fallbackTypography.headingTop, 0)
                    ),
                    headingBottom: readLegacyReaderLayoutField(
                        config, legacyPrefix, 'headingBottom',
                        pickReaderLayoutValue(fallbackTypography.headingBottom, 0)
                    )
                }
            };
        }

        function resolveReaderProfileConfig(profile, fallbackProfile, paginated) {
            profile = profile && typeof profile === 'object' ? profile : {};
            var geometry = profile.geometry && typeof profile.geometry === 'object' ? profile.geometry : {};
            var typography = profile.typography && typeof profile.typography === 'object' ? profile.typography : {};
            var fallbackGeometry = fallbackProfile && fallbackProfile.geometry ? fallbackProfile.geometry : {};
            var fallbackTypography = fallbackProfile && fallbackProfile.typography ? fallbackProfile.typography : {};
            return {
                geometry: {
                    strategy: pickReaderLayoutValue(geometry.strategy, pickReaderLayoutValue(fallbackGeometry.strategy, defaultReaderStrategy(paginated))),
                    writingMode: pickReaderLayoutValue(geometry.writingMode, pickReaderLayoutValue(fallbackGeometry.writingMode, 'horizontal-tb')),
                    pageAxis: pickReaderLayoutValue(geometry.pageAxis, pickReaderLayoutValue(fallbackGeometry.pageAxis, 'x')),
                    pageProgression: pickReaderLayoutValue(geometry.pageProgression, pickReaderLayoutValue(fallbackGeometry.pageProgression, 'ltr')),
                    viewportWidth: pickReaderLayoutValue(geometry.viewportWidth, fallbackGeometry.viewportWidth),
                    viewportHeight: pickReaderLayoutValue(geometry.viewportHeight, fallbackGeometry.viewportHeight),
                    pageWidth: pickReaderLayoutValue(geometry.pageWidth, fallbackGeometry.pageWidth),
                    pageHeight: pickReaderLayoutValue(geometry.pageHeight, fallbackGeometry.pageHeight),
                    pageSpan: pickReaderLayoutValue(geometry.pageSpan, fallbackGeometry.pageSpan),
                    pageInsetBlockStart: pickReaderLayoutValue(geometry.pageInsetBlockStart, pickReaderLayoutValue(fallbackGeometry.pageInsetBlockStart, 0)),
                    pageInsetBlockEnd: pickReaderLayoutValue(geometry.pageInsetBlockEnd, pickReaderLayoutValue(fallbackGeometry.pageInsetBlockEnd, 0)),
                    pageInsetInlineStart: pickReaderLayoutValue(geometry.pageInsetInlineStart, pickReaderLayoutValue(fallbackGeometry.pageInsetInlineStart, 0)),
                    pageInsetInlineEnd: pickReaderLayoutValue(geometry.pageInsetInlineEnd, pickReaderLayoutValue(fallbackGeometry.pageInsetInlineEnd, 0)),
                    columnGap: pickReaderLayoutValue(geometry.columnGap, pickReaderLayoutValue(fallbackGeometry.columnGap, 0))
                },
                typography: {
                    lineHeight: pickReaderLayoutValue(typography.lineHeight, pickReaderLayoutValue(fallbackTypography.lineHeight, 1.6)),
                    paddingVertical: pickReaderLayoutValue(typography.paddingVertical, pickReaderLayoutValue(fallbackTypography.paddingVertical, 0)),
                    paddingHorizontal: pickReaderLayoutValue(typography.paddingHorizontal, pickReaderLayoutValue(fallbackTypography.paddingHorizontal, 0)),
                    paragraphIndent: pickReaderLayoutValue(typography.paragraphIndent, pickReaderLayoutValue(fallbackTypography.paragraphIndent, '2em')),
                    paragraphSpacing: pickReaderLayoutValue(typography.paragraphSpacing, pickReaderLayoutValue(fallbackTypography.paragraphSpacing, 0)),
                    headingTop: pickReaderLayoutValue(typography.headingTop, pickReaderLayoutValue(fallbackTypography.headingTop, 0)),
                    headingBottom: pickReaderLayoutValue(typography.headingBottom, pickReaderLayoutValue(fallbackTypography.headingBottom, 0))
                }
            };
        }

        function normalizeReaderLayoutConfig(config) {
            config = config || {};
            var flow = config.flow === 'vertical' ? 'vertical' : 'horizontal';
            var paginated = config.paginated !== false;
            var legacyHorizontalProfile = resolveLegacyReaderProfileConfig(config, '', null, paginated);
            var horizontalProfile = resolveReaderProfileConfig(config.horizontalProfile, legacyHorizontalProfile, paginated);
            var legacyVerticalProfile = resolveLegacyReaderProfileConfig(config, 'vertical', horizontalProfile, paginated);
            var verticalProfile = resolveReaderProfileConfig(config.verticalProfile, legacyVerticalProfile, paginated);
            return {
                flow: flow,
                paginated: paginated,
                fontSize: Math.max(0, config.fontSize || 0),
                horizontalProfile: horizontalProfile,
                verticalProfile: verticalProfile
            };
        }

        function resolveReaderActiveProfile(normalized) {
            normalized = normalizeReaderLayoutConfig(normalized);
            return normalized.flow === 'vertical' ? normalized.verticalProfile : normalized.horizontalProfile;
        }

        function projectReaderOperationalLayout(normalized, activeProfile) {
            normalized = normalizeReaderLayoutConfig(normalized);
            var flow = normalized.flow;
            var paginated = normalized.paginated;
            activeProfile = activeProfile || resolveReaderActiveProfile(normalized);
            var activeGeometry = activeProfile.geometry || {};
            var activeTypography = activeProfile.typography || {};
            return {
                flow: flow,
                paginated: paginated,
                strategy: activeGeometry.strategy,
                lineHeight: activeTypography.lineHeight,
                columnGap: activeGeometry.columnGap,
                paddingVertical: activeTypography.paddingVertical,
                paddingHorizontal: activeTypography.paddingHorizontal,
                paragraphIndent: activeTypography.paragraphIndent || '2em',
                paragraphSpacing: activeTypography.paragraphSpacing,
                headingTop: activeTypography.headingTop,
                headingBottom: activeTypography.headingBottom,
                writingMode: activeGeometry.writingMode,
                pageAxis: activeGeometry.pageAxis,
                pageProgression: activeGeometry.pageProgression,
                viewportWidth: activeGeometry.viewportWidth,
                viewportHeight: activeGeometry.viewportHeight,
                pageWidth: activeGeometry.pageWidth,
                pageHeight: activeGeometry.pageHeight,
                pageSpan: activeGeometry.pageSpan,
                pageInsetBlockStart: activeGeometry.pageInsetBlockStart,
                pageInsetBlockEnd: activeGeometry.pageInsetBlockEnd,
                pageInsetInlineStart: activeGeometry.pageInsetInlineStart,
                pageInsetInlineEnd: activeGeometry.pageInsetInlineEnd
            };
        }

        function resolveReaderOperationalLayout(config) {
            var normalized = normalizeReaderLayoutConfig(config);
            return projectReaderOperationalLayout(normalized, resolveReaderActiveProfile(normalized));
        }

        function resolveReaderMetricsLayout(layout) {
            return layout && layout.horizontalProfile ? resolveReaderOperationalLayout(layout) : layout;
        }

        function resolveActiveReaderLayoutConfig(config) {
            return resolveReaderOperationalLayout(config);
        }

        function applyReaderLayoutConfig(config) {
            try {
                var normalized = normalizeReaderLayoutConfig(config);
                var active = projectReaderOperationalLayout(normalized, resolveReaderActiveProfile(normalized));
                var flow = active.flow;
                var paginated = active.paginated;
                readerLayoutConfigState = normalized;
                setReaderFlowMode(flow);
                document.documentElement.setAttribute('data-reader-layout', paginated ? 'paginated' : 'flow');
                setReaderCSSVar('--reader-font-size', normalized.fontSize, 'px');
                setReaderCSSVar('--reader-line-height', normalized.horizontalProfile.typography.lineHeight, '');
                setReaderCSSVar('--reader-column-gap', normalized.horizontalProfile.geometry.columnGap, 'px');
                setReaderCSSVar('--reader-padding-vertical', normalized.horizontalProfile.typography.paddingVertical, 'px');
                setReaderCSSVar('--reader-padding-horizontal', normalized.horizontalProfile.typography.paddingHorizontal, 'px');
                setReaderCSSVar('--reader-paragraph-indent', normalized.horizontalProfile.typography.paragraphIndent || '2em', '');

                setReaderCSSVar('--reader-active-line-height', active.lineHeight, '');
                setReaderCSSVar('--reader-active-column-gap', active.columnGap, 'px');
                setReaderCSSVar('--reader-active-padding-vertical', active.paddingVertical, 'px');
                setReaderCSSVar('--reader-active-padding-horizontal', active.paddingHorizontal, 'px');
                setReaderCSSVar('--reader-active-paragraph-indent', active.paragraphIndent || '2em', '');
                setReaderCSSVar('--reader-active-paragraph-spacing', active.paragraphSpacing, 'em');
                setReaderCSSVar('--reader-active-heading-top', active.headingTop, 'em');
                setReaderCSSVar('--reader-active-heading-bottom', active.headingBottom, 'em');
                setReaderCSSVar('--reader-viewport-width', active.viewportWidth, 'px');
                setReaderCSSVar('--reader-viewport-height', active.viewportHeight, 'px');
                setReaderCSSVar('--reader-page-width', active.pageWidth, 'px');
                setReaderCSSVar('--reader-page-height', active.pageHeight, 'px');
                setReaderCSSVar('--reader-page-span', active.pageSpan, 'px');
                setReaderCSSVar('--reader-page-inset-block-start', active.pageInsetBlockStart, 'px');
                setReaderCSSVar('--reader-page-inset-block-end', active.pageInsetBlockEnd, 'px');
                setReaderCSSVar('--reader-page-inset-inline-start', active.pageInsetInlineStart, 'px');
                setReaderCSSVar('--reader-page-inset-inline-end', active.pageInsetInlineEnd, 'px');
                document.documentElement.setAttribute('data-reader-writing-mode', active.writingMode);
                document.documentElement.setAttribute('data-reader-page-axis', active.pageAxis === 'y' ? 'y' : 'x');
                document.documentElement.setAttribute('data-reader-page-progression', active.pageProgression === 'rtl' ? 'rtl' : 'ltr');
                document.documentElement.setAttribute('data-reader-strategy', active.strategy || defaultReaderStrategy(paginated));
                document.documentElement.style.writingMode = active.writingMode;
                document.documentElement.dir = active.pageProgression === 'rtl' ? 'rtl' : 'ltr';
                if (document.body) {
                    document.body.classList.toggle('paginated-flow', paginated);
                    document.body.dir = active.pageProgression === 'rtl' ? 'rtl' : 'ltr';
                }
            } catch (e) {}
        }

        function readCurrentReaderLayoutState() {
            var root = getReaderRoot();
            var styles = window.getComputedStyle(root);
            return {
                flow: getReaderFlowMode(),
                paginated: root.getAttribute('data-reader-layout') !== 'flow',
                fontSize: parseFloat(styles.getPropertyValue('--reader-font-size') || '0') || 0,
                lineHeight: parseFloat(styles.getPropertyValue('--reader-line-height') || '0') || 0,
                columnGap: parseFloat(styles.getPropertyValue('--reader-column-gap') || '0') || 0,
                paddingVertical: parseFloat(styles.getPropertyValue('--reader-padding-vertical') || '0') || 0,
                paddingHorizontal: parseFloat(styles.getPropertyValue('--reader-padding-horizontal') || '0') || 0,
                paragraphIndent: styles.getPropertyValue('--reader-active-paragraph-indent').trim() || '2em',
                paragraphSpacing: parseFloat(styles.getPropertyValue('--reader-active-paragraph-spacing') || '0') || 0,
                headingTop: parseFloat(styles.getPropertyValue('--reader-active-heading-top') || '0') || 0,
                headingBottom: parseFloat(styles.getPropertyValue('--reader-active-heading-bottom') || '0') || 0,
                viewportWidth: parseFloat(styles.getPropertyValue('--reader-viewport-width') || '0') || window.innerWidth,
                viewportHeight: parseFloat(styles.getPropertyValue('--reader-viewport-height') || '0') || window.innerHeight,
                pageWidth: parseFloat(styles.getPropertyValue('--reader-page-width') || '0') || window.innerWidth,
                pageHeight: parseFloat(styles.getPropertyValue('--reader-page-height') || '0') || window.innerHeight,
                pageSpan: parseFloat(styles.getPropertyValue('--reader-page-span') || '0') || window.innerWidth,
                pageInsetBlockStart: parseFloat(styles.getPropertyValue('--reader-page-inset-block-start') || '0') || 0,
                pageInsetBlockEnd: parseFloat(styles.getPropertyValue('--reader-page-inset-block-end') || '0') || 0,
                pageInsetInlineStart: parseFloat(styles.getPropertyValue('--reader-page-inset-inline-start') || '0') || 0,
                pageInsetInlineEnd: parseFloat(styles.getPropertyValue('--reader-page-inset-inline-end') || '0') || 0,
                writingMode: root.getAttribute('data-reader-writing-mode') || 'horizontal-tb',
                pageAxis: root.getAttribute('data-reader-page-axis') || 'x',
                pageProgression: root.getAttribute('data-reader-page-progression') || 'ltr',
                strategy: root.getAttribute('data-reader-strategy') || defaultReaderStrategy(root.getAttribute('data-reader-layout') !== 'flow')
            };
        }

        function cloneReaderProfile(profile) {
            profile = profile || {};
            return {
                geometry: Object.assign({}, profile.geometry || {}),
                typography: Object.assign({}, profile.typography || {})
            };
        }

        function buildReaderConfigFromState(state) {
            var activeProfile = {
                geometry: {
                    strategy: state.strategy || defaultReaderStrategy(state.paginated !== false),
                    writingMode: state.writingMode || 'horizontal-tb',
                    pageAxis: state.pageAxis === 'y' ? 'y' : 'x',
                    pageProgression: state.pageProgression === 'rtl' ? 'rtl' : 'ltr',
                    viewportWidth: Math.max(1, state.viewportWidth || window.innerWidth),
                    viewportHeight: Math.max(1, state.viewportHeight || window.innerHeight),
                    pageWidth: Math.max(1, state.pageWidth || state.viewportWidth || window.innerWidth),
                    pageHeight: Math.max(1, state.pageHeight || state.viewportHeight || window.innerHeight),
                    pageSpan: Math.max(
                        1,
                        state.pageSpan || ((state.pageAxis === 'y' ? state.pageHeight : state.pageWidth) || state.viewportWidth || window.innerWidth)
                    ),
                    pageInsetBlockStart: Math.max(0, state.pageInsetBlockStart || 0),
                    pageInsetBlockEnd: Math.max(0, state.pageInsetBlockEnd || 0),
                    pageInsetInlineStart: Math.max(0, state.pageInsetInlineStart || 0),
                    pageInsetInlineEnd: Math.max(0, state.pageInsetInlineEnd || 0),
                    columnGap: Math.max(0, state.columnGap || 0)
                },
                typography: {
                    lineHeight: Math.max(0, state.lineHeight || 0),
                    paddingVertical: Math.max(0, state.paddingVertical || 0),
                    paddingHorizontal: Math.max(0, state.paddingHorizontal || 0),
                    paragraphIndent: state.paragraphIndent || '2em',
                    paragraphSpacing: Math.max(0, state.paragraphSpacing || 0),
                    headingTop: Math.max(0, state.headingTop || 0),
                    headingBottom: Math.max(0, state.headingBottom || 0)
                }
            };
            var baseConfig = readerLayoutConfigState
                ? normalizeReaderLayoutConfig(readerLayoutConfigState)
                : {
                    flow: state.flow === 'vertical' ? 'vertical' : 'horizontal',
                    paginated: state.paginated !== false,
                    fontSize: Math.max(0, state.fontSize || 0),
                    horizontalProfile: cloneReaderProfile(activeProfile),
                    verticalProfile: cloneReaderProfile(activeProfile)
                };
            var normalized = {
                flow: state.flow === 'vertical' ? 'vertical' : 'horizontal',
                paginated: state.paginated !== false,
                fontSize: Math.max(0, state.fontSize || baseConfig.fontSize || 0),
                horizontalProfile: cloneReaderProfile(baseConfig.horizontalProfile),
                verticalProfile: cloneReaderProfile(baseConfig.verticalProfile)
            };
            if (normalized.flow === 'vertical') {
                normalized.verticalProfile = activeProfile;
            } else {
                normalized.horizontalProfile = activeProfile;
            }
            return normalizeReaderLayoutConfig(normalized);
        }

        function resolveCurrentReaderLayoutConfig() {
            try {
                var state = readCurrentReaderLayoutState();
                return buildReaderConfigFromState(state);
            } catch (e) {
                return normalizeReaderLayoutConfig({
                    flow: getReaderFlowMode(),
                    paginated: true,
                    fontSize: 0,
                    horizontalProfile: {
                        geometry: {
                            strategy: 'paged-columns',
                            writingMode: 'horizontal-tb',
                            pageAxis: 'x',
                            pageProgression: 'ltr',
                            viewportWidth: window.innerWidth,
                            viewportHeight: window.innerHeight,
                            pageWidth: window.innerWidth,
                            pageHeight: window.innerHeight,
                            pageSpan: window.innerWidth,
                            pageInsetBlockStart: 0,
                            pageInsetBlockEnd: 0,
                            pageInsetInlineStart: 0,
                            pageInsetInlineEnd: 0,
                            columnGap: 0
                        },
                        typography: {
                            lineHeight: 0,
                            paddingVertical: 0,
                            paddingHorizontal: 0,
                            paragraphIndent: '2em',
                            paragraphSpacing: 0,
                            headingTop: 0,
                            headingBottom: 0
                        }
                    },
                    verticalProfile: {
                        geometry: {
                            strategy: 'stacked-pages',
                            writingMode: 'vertical-rl',
                            pageAxis: 'y',
                            pageProgression: 'ltr',
                            viewportWidth: window.innerWidth,
                            viewportHeight: window.innerHeight,
                            pageWidth: window.innerWidth,
                            pageHeight: window.innerHeight,
                            pageSpan: window.innerHeight,
                            pageInsetBlockStart: 0,
                            pageInsetBlockEnd: 0,
                            pageInsetInlineStart: 0,
                            pageInsetInlineEnd: 0,
                            columnGap: 0
                        },
                        typography: {
                            lineHeight: 0,
                            paddingVertical: 0,
                            paddingHorizontal: 0,
                            paragraphIndent: '2em',
                            paragraphSpacing: 0,
                            headingTop: 0,
                            headingBottom: 0
                        }
                    }
                });
            }
        }

        function getReaderLayoutConfig() {
            return resolveCurrentReaderLayoutConfig();
        }

        function updateColumnLayout(footerPx) {
            try {
                var vw = window.innerWidth;
                var footer = Math.max(0, footerPx || 0);
                var vh = Math.max(1, window.innerHeight - footer);
                document.documentElement.style.setProperty('--reader-footer-offset', footer + 'px');
                var layout = resolveReaderMetricsLayout(getReaderLayoutConfig());
                if (!layout.viewportWidth || layout.viewportWidth <= 0) {
                    document.documentElement.style.setProperty('--reader-viewport-width', vw + 'px');
                }
                if (!layout.viewportHeight || layout.viewportHeight <= 0) {
                    document.documentElement.style.setProperty('--reader-viewport-height', vh + 'px');
                }
                var content = document.body;
                if (!document.body || !layout.paginated) {
                    content = document.getElementById('reader-content') || document.body;
                }
                if (!content) return;
                var strategy = layout.strategy || (layout.paginated ? 'paged-columns' : 'continuous-flow');
                if (document.body && layout.paginated) {
                    if (strategy === 'stacked-pages' || layout.pageAxis === 'y') {
                        content.style.columnWidth = 'auto';
                        content.style.webkitColumnWidth = 'auto';
                        content.style.height = 'auto';
                        content.style.minHeight = Math.max(1, layout.pageHeight || vh) + 'px';
                    } else if (strategy === 'continuous-flow') {
                        content.style.columnWidth = 'auto';
                        content.style.webkitColumnWidth = 'auto';
                        content.style.height = 'auto';
                        content.style.minHeight = Math.max(1, layout.pageHeight || vh) + 'px';
                    } else {
                        var pageWidth = Math.max(1, layout.pageWidth || vw);
                        content.style.setProperty('column-width', pageWidth + 'px', 'important');
                        content.style.setProperty('-webkit-column-width', pageWidth + 'px', 'important');
                        // 用 window.innerHeight 確保 body 高度與 WKWebView viewport 一致
                        var actualHeight = Math.max(1, window.innerHeight);
                        content.style.setProperty('height', actualHeight + 'px', 'important');
                        content.style.setProperty('min-height', actualHeight + 'px', 'important');
                    }
                } else {
                    content.style.columnWidth = 'auto';
                    content.style.webkitColumnWidth = 'auto';
                    content.style.height = 'auto';
                    content.style.minHeight = Math.max(1, layout.pageHeight || vh) + 'px';
                }
            } catch (e) {}
        }

        function updateColumnWidth(footerPx) {
            updateColumnLayout(footerPx);
        }

        function getReaderFlowMode() {
            try {
                var rootMode = document.documentElement.getAttribute('data-reader-flow');
                if (rootMode === 'vertical' || rootMode === 'horizontal') {
                    return rootMode;
                }
                if (document.body && document.body.classList.contains('vertical-reader')) {
                    return 'vertical';
                }
            } catch (e) {}
            return 'horizontal';
        }

        function setReaderFlowMode(mode) {
            try {
                var normalized = mode === 'vertical' ? 'vertical' : 'horizontal';
                document.documentElement.setAttribute('data-reader-flow', normalized);
                if (document.body) {
                    document.body.classList.toggle('vertical-reader', normalized === 'vertical');
                    document.body.classList.toggle('horizontal-reader', normalized !== 'vertical');
                }
            } catch (e) {}
        }

        function resolveReaderPaginationMetrics(layout) {
            layout = resolveReaderMetricsLayout(layout);
            var strategy = layout.strategy || defaultReaderStrategy(layout.paginated !== false);
            var body = document.body;
            if (!body) {
                var fallbackAxis = (strategy === 'stacked-pages' || layout.pageAxis === 'y') ? 'y' : 'x';
                var fallbackSpan = fallbackAxis === 'y'
                    ? Math.max(1, layout.pageSpan || layout.pageHeight || window.innerHeight)
                    : Math.max(1, layout.pageSpan || layout.pageWidth || window.innerWidth);
                return {
                    axis: fallbackAxis,
                    columnWidth: Math.max(1, layout.pageWidth || window.innerWidth),
                    columnGap: 0,
                    pageSpan: fallbackSpan,
                    scrollSpan: fallbackSpan
                };
            }
            if (strategy === 'continuous-flow') {
                var flowAxis = layout.pageAxis === 'y' ? 'y' : 'x';
                if (flowAxis === 'y') {
                    var verticalFlowSpan = Math.max(1, layout.pageSpan || layout.pageHeight || window.innerHeight);
                    var verticalScroll = Math.max(
                        body.scrollHeight || 0,
                        document.documentElement.scrollHeight || 0,
                        verticalFlowSpan
                    );
                    return {
                        axis: 'y',
                        columnWidth: Math.max(1, layout.pageWidth || window.innerWidth),
                        columnGap: 0,
                        pageSpan: verticalFlowSpan,
                        scrollSpan: verticalScroll
                    };
                }
                var horizontalFlowSpan = Math.max(1, layout.pageSpan || layout.pageWidth || window.innerWidth);
                var horizontalScroll = Math.max(
                    body.scrollWidth || 0,
                    document.documentElement.scrollWidth || 0,
                    horizontalFlowSpan
                );
                return {
                    axis: 'x',
                    columnWidth: horizontalFlowSpan,
                    columnGap: 0,
                    pageSpan: horizontalFlowSpan,
                    scrollSpan: horizontalScroll
                };
            }
            if (strategy === 'stacked-pages' || layout.pageAxis === 'y') {
                var verticalSpan = Math.max(
                    1,
                    layout.pageSpan || layout.pageHeight || parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--reader-viewport-height') || '0') || window.innerHeight
                );
                var scrollHeight = Math.max(
                    body.scrollHeight || 0,
                    document.documentElement.scrollHeight || 0,
                    verticalSpan
                );
                return {
                    axis: 'y',
                    columnWidth: Math.max(1, layout.pageWidth || window.innerWidth),
                    columnGap: 0,
                    pageSpan: verticalSpan,
                    scrollSpan: scrollHeight
                };
            }
            var styles = window.getComputedStyle(body);
            var columnWidth = parseFloat(styles.columnWidth || styles.webkitColumnWidth || '0');
            var columnGap = parseFloat(styles.columnGap || styles.webkitColumnGap || '0');
            if (!columnWidth || !isFinite(columnWidth)) {
                columnWidth = Math.max(1, layout.pageWidth || window.innerWidth);
            }
            if (!columnGap || !isFinite(columnGap)) {
                columnGap = 0;
            }
            var scrollWidth = Math.max(body.scrollWidth || 0, document.documentElement.scrollWidth || 0, window.innerWidth);
            return {
                axis: 'x',
                columnWidth: columnWidth,
                columnGap: columnGap,
                pageSpan: Math.max(1, layout.pageSpan || (columnWidth + columnGap)),
                scrollSpan: scrollWidth
            };
        }

        function getReaderPaginationMetrics() {
            try {
                return resolveReaderPaginationMetrics(getReaderLayoutConfig());
            } catch (e) {
                return { axis: 'x', columnWidth: window.innerWidth, columnGap: 0, pageSpan: window.innerWidth, scrollSpan: window.innerWidth };
            }
        }

        function prepareSnapshot(timeoutMs) {
            document.documentElement.classList.add('no-fancy');
            var delay = (typeof timeoutMs === 'number' ? timeoutMs : 80);
            setTimeout(function(){}, delay);
            return true;
        }

        function restoreAfterSnapshot() {
            document.documentElement.classList.remove('no-fancy');
        }
        """
    }

    static func placeholderHTML(title: String) -> String {
        let escapedTitle = escapeHTML(title)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta charset="UTF-8" />
        <title>\(escapedTitle)</title>
        <link rel="stylesheet" type="text/css" href="reader.css" />
        <script>\(javaScript())</script>
        </head>
        <body>
        <script>
        applyReaderLayoutConfig({
            flow: 'horizontal',
            paginated: false,
            fontSize: 18,
            horizontalProfile: {
                geometry: {
                    strategy: 'continuous-flow',
                    writingMode: 'horizontal-tb',
                    pageAxis: 'x',
                    pageProgression: 'ltr',
                    columnGap: 28
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: 20,
                    paddingHorizontal: 18,
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.9,
                    headingTop: 0.75,
                    headingBottom: 0.42
                }
            },
            verticalProfile: {
                geometry: {
                    strategy: 'continuous-flow',
                    writingMode: 'vertical-rl',
                    pageAxis: 'y',
                    pageProgression: 'ltr',
                    columnGap: 28
                },
                typography: {
                    lineHeight: 1.6,
                    paddingVertical: 20,
                    paddingHorizontal: 18,
                    paragraphIndent: '2em',
                    paragraphSpacing: 0.82,
                    headingTop: 0.58,
                    headingBottom: 0.35
                }
            }
        });
        </script>
        <div id="reader-content">
            <h1>\(escapedTitle)</h1>
            <p>載入章節中…</p>
        </div>
        </body>
        </html>
        """
    }
*/

enum ReaderAdapterAssets {
    static func normalizedChapterHTML(
        title: String,
        paragraphs: [String],
        language: String = "zh-Hant"
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedTitle = escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading =
            trimmedTitle.isEmpty
            ? ""
            : "<h1>\(escapeHTML(trimmedTitle))</h1>\n"
        let body = paragraphs.enumerated()
            .map { _, paragraph in
                return "<p>\(escapeHTML(paragraph))</p>"
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escapedTitle)</title>
        </head>
        <body>
        <article id="reader-content">
        \(heading)\(body)
        </article>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }
}
