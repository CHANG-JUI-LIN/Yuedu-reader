# CoreText Reader Notes

This directory is the contributor entry point for the paged CoreText reader. It
documents the code paths that are easiest to break when changing EPUB/TXT layout,
vertical writing, links, selection, images, or annotation rendering.

## Main Code Map

| Area | Files |
| --- | --- |
| Pagination and page ranges | `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`, `PaginationManager.swift` |
| Page rendering and interaction | `CoreTextPageView.swift`, `InteractionOverlayView.swift` |
| EPUB HTML/CSS to attributed text | `HTMLAttributedStringBuilder.swift`, `HTMLBuilderPipelines.swift`, `EPUBAttributedStringBuilder.swift` |
| Renderable node pipeline | `HTMLStyledASTRenderableNodeConverter.swift`, `RenderableNode.swift`, `NodeAttributedStringRenderer.swift` |
| Images, inline annotation placeholders | `RunDelegateProvider.swift`, `CoreTextChunkAttachmentExtractor.swift` |
| Vertical writing helpers | `CoreTextCommon/String+VerticalNormalization.swift`, `CoreTextCommon/VerticalLayoutConfig.swift` |
| Engine and reader bridge | `CoreTextPageEngine.swift`, `PageRenderingProvider.swift`, `ReaderView.swift` |
| Text selection and underline bookmarks | `TextSelectionManager.swift`, `CoreTextTextAnnotation.swift` |

## Supporting Notes

- [rendering-pipeline.md](rendering-pipeline.md): how content moves from EPUB/TXT/HTML into pages.
- [vertical-writing.md](vertical-writing.md): vertical-rl coordinate rules, Latin centering, inline image and annotation behavior.
- [interaction.md](interaction.md): link hit-testing, selection rects, underline drawing, and reader navigation callbacks.
- [contributing.md](contributing.md): change checklist and focused test commands.

## Focused Tests

Run the vertical writing suite before changing vertical layout or interaction:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -parallel-testing-enabled NO
```
