# EPUB Regression Corpus

This directory contains small, legal EPUB files that reproduce reader layout and
navigation cases without copying text or assets from commercial books. The goal
is to turn each real-world rendering bug into a repeatable fixture that can be
opened manually, compared against Apple Books, or wired into automated tests.

## Directory Layout

- `samples/`: packaged `.epub` files for manual and automated regression checks.
- `sources/`: editable source trees used to build the packaged EPUB files.
- `screenshots/`: expected or observed render references when a case needs a
  visual comparison.
- `compatibility-matrix.md`: current Yuedu support status for each sample.
- `build-samples.sh`: rebuilds all packaged EPUB files from `sources/`.

## Samples

| Sample | Area | What It Covers |
| --- | --- | --- |
| `block-image-before-paragraph.epub` | Reflow layout | An image-only block before a chapter heading must reserve its rendered height. |
| `centered-percent-image.epub` | Reflow layout | A centered block image with percentage width and `height: auto`. |
| `paragraph-border-background.epub` | Block box layout | Paragraph margin, padding, border, and background geometry. |
| `hr-divider-width-alignment-margins.epub` | Block box layout | HR divider width, center alignment, and horizontal margins. |
| `toc-ncx-basic.epub` | EPUB navigation | EPUB 2 `toc.ncx` table of contents with two spine chapters. |
| `nav-xhtml-basic.epub` | EPUB navigation | EPUB 3 `nav.xhtml` table of contents with two spine chapters. |

## Adding A Regression Sample

1. Reduce the real bug to the smallest synthetic XHTML/CSS that still fails.
2. Do not copy copyrighted prose, publisher art, or embedded fonts from the
   original book. Use short synthetic text and generated assets.
3. Add an editable source tree under `sources/<sample-name>/`.
4. Add the packaged EPUB to `samples/<sample-name>.epub` by running:

   ```bash
   ./docs/epub-regression/build-samples.sh
   ```

5. Add the expected behavior to this README and `compatibility-matrix.md`.
6. If the bug is visual, add an expected or observed screenshot under
   `screenshots/`.

EPUB packages must keep `mimetype` as the first zip entry and store it
uncompressed. The build script handles that packaging detail.

