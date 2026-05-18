# EPUB Regression Compatibility Matrix

Status values:

- `supported`: expected behavior currently works in Yuedu Reader.
- `partial`: opens, but the specific behavior is incomplete or fragile.
- `unsupported`: not expected to work yet.
- `needs-check`: fixture exists but has not been verified recently.

| Sample | EPUB Version | Primary Feature | Apple Books Expected | Yuedu Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `block-image-before-paragraph.epub` | EPUB 2 | Image-only block reserves height | Logo appears centered above `CHAPTER ONE`; no overlap. | supported | Covers the #4 block image overlap regression. |
| `centered-percent-image.epub` | EPUB 2 | Percentage block image sizing | Image is centered at 40% content width with proportional height. | supported | Exercises `width: 40%; height: auto`. |
| `paragraph-border-background.epub` | EPUB 2 | Paragraph border/background box | Background and border wrap paragraph text with padding and margins. | partial | CoreText block decoration support exists but should be watched for geometry drift. |
| `hr-divider-width-alignment-margins.epub` | EPUB 2 | HR width/alignment/margins | Divider is centered, not full-width, and honors margins. | supported | Matches existing HR divider rendering support. |
| `toc-ncx-basic.epub` | EPUB 2 | NCX table of contents | TOC shows Chapter One and Chapter Two without duplicates. | supported | Covers `toc.ncx` navigation. |
| `nav-xhtml-basic.epub` | EPUB 3 | `nav.xhtml` table of contents | TOC shows Chapter One and Chapter Two without duplicates. | needs-check | Included as the EPUB 3 navigation baseline. |

