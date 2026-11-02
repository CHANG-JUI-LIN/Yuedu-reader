# MOBI and AZW3 fixtures

## Made here

`generate_mobi_fixtures.py` writes two EPUBs from scratch (our own text and pictures) and converts
them with Calibre 9.17 (`/Applications/calibre.app/Contents/MacOS/ebook-convert`):

| EPUB | Conversions |
|---|---|
| `features.epub`: metadata, cover, nested TOC, links across chapters, inline picture, CSS classes, a table; English | `features.azw3` (KF8), `features.mobi` (MOBI 6, `--mobi-file-type old`), `features-combo.mobi` (`both`), `features-uncompressed.mobi` (MOBI 6, `--dont-compress`) |
| `vertical-zh.epub`: `writing-mode: vertical-rl`, `page-progression-direction="rtl"`; Traditional Chinese | `vertical-zh.azw3`, `vertical-zh.mobi` |
| `embedded-font.epub`: one chapter whose stylesheet names a font the book carries | `embedded-font.azw3` |
| `fixed-layout.epub`: `rendition:layout` pre-paginated, two 600 × 800 pages with a picture and a positioned caption | `fixed-layout.azw3` |

The script converts only the books it is named (`python3 generate_mobi_fixtures.py embedded-font`), so
adding a book leaves the others' bytes alone; with no name it makes them all.

The embedded font is `../Ahem.ttf`, already in the repo for the font tests: the CSS test font by Todd
Fahrner and Myles C. Maxfield, every glyph a box. Its README
(https://www.w3.org/Style/CSS/Test/Fonts/Ahem/README) says it "belongs to the public domain", with a CC0
waiver where public domain is not recognised.

Re-running the script changes bytes even with no edit: Calibre writes a fresh UUID
into EXTH 112/113 every run, and moved the 2026-11-01 date to 2026-11-02 (time
zone). Tests must not pin the ASIN, the UUID, the date or file sizes.

Calibre also drops the region from `zh-TW` (EXTH 524 and the locale say `zh`), and
writes `horizontal-rl` as the vertical book's primary writing mode (EXTH 525); the
vertical direction itself is in the KF8 CSS.

Calibre writes the embedded font as a `FONT` record with flags 3: zlib-compressed and
XOR-obfuscated with a 20-byte key. It writes the fixed-layout book's KF8 with no
fixed-layout markers at all: no EXTH 122 or 126, no RESC record. Only Amazon's tools
(Kindle Comic Creator, KindleGen) write those, so no file here has them.

## Downloaded

Project Gutenberg #11, Lewis Carroll, *Alice's Adventures in Wonderland*, public
domain in the USA; the Project Gutenberg licence text is inside each file.
Downloaded 2026-11-01.

| File | URL | SHA-256 |
|---|---|---|
| `gutenberg-11-kf8.azw3` | https://www.gutenberg.org/ebooks/11.kf8.images | `d8211269aed55ded8302f289950936db8368b4d4d384c463b722034152f8f1d2` |
| `gutenberg-11-kindle.mobi` | https://www.gutenberg.org/ebooks/11.kindle.images | `1b4222ffdf1862a39d0fae6d42c588f28a34c12ad73cc21c2849fe2646cac3e1` |
| `gutenberg-11.epub` | https://www.gutenberg.org/ebooks/11.epub3.images | `4f81245d31380ac1d6eafb9a321e3691369bc70985736ae4bccf849a4f784036` |

Gutenberg's Kindle files are made by Calibre too (9.5.0, EXTH 108), so they are a
second book, not a second producer.

## Census (2026-11-01)

Every file here: `BOOKMOBI`, encryption 0, PalmDOC compression (2) except
`features-uncompressed.mobi` (1), UTF-8 (65001), extra-record-data flags 3
(multibyte entry plus one sized entry). MOBI 6 headers are 232 bytes long, KF8
headers 264. No `.mobi`, `.azw`, `.azw3` or `.prc` file exists elsewhere on the
maintainer's Mac.

Not covered by any file here, because Calibre never writes it: HUFF/CDIC
compression (17480), cp1252 text, headers shorter than 0xE4, files made by
KindleGen or Amazon (their index and `SRCS` records differ from Calibre's), and a
fixed-layout KF8 book (EXTH 122/126, RESC page spreads). The
cp1252 and short-header cases are built in memory by `MOBIFileTests`; HUFF/CDIC
is refused until a DRM-free sample exists.
