# EPUB Regression Samples

Minimal EPUB files that capture real reader rendering bugs. Keep each sample small,
legal, and focused on one layout behavior so it can be used manually or wired into
automated EPUB rendering tests.

## Samples

- `block-image-reserves-height.epub`: image-only block before a chapter heading.
  The block image must reserve its rendered height in the CoreText layout flow, so
  the following `CHAPTER` paragraph does not overlap the image.

