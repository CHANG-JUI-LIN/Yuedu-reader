"""Source EPUBs for the MOBI/AZW3 tests, and their Calibre conversions.

Run with any Python 3 on a Mac that has Calibre installed:

    python3 generate_mobi_fixtures.py [book …]

Every EPUB here is written from scratch by this script (our own text and
pictures, no third-party content), then converted with Calibre's
`ebook-convert` into the Kindle formats the importer reads. The EPUB stays
next to its conversions: it is the oracle the converted book is compared with.
"""
import shutil
import struct
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

root = Path(__file__).parent
calibre = Path('/Applications/calibre.app/Contents/MacOS/ebook-convert')


def png(width, height, pixel):
    """A truecolour PNG; `pixel(x, y)` returns (r, g, b)."""
    rows = b''.join(
        b'\x00' + b''.join(bytes(pixel(x, y)) for x in range(width))
        for y in range(height))

    def chunk(kind, body):
        return (struct.pack('>I', len(body)) + kind + body
                + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, 9))
            + chunk(b'IEND', b''))


def cover_png():
    return png(300, 400, lambda x, y: (30 + y // 4, 60, 120 + (x // 30) % 2 * 60))


def figure_png():
    return png(160, 100, lambda x, y: (200, 150 + x // 4, 40 + y))


def xhtml(title, body, language, stylesheet='style.css', head=''):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{language}" lang="{language}">
<head><meta charset="utf-8"/>{head}<title>{title}</title><link rel="stylesheet" type="text/css" href="{stylesheet}"/></head>
<body>
{body}
</body>
</html>
'''


def write_epub(path, *, metadata, language, chapters, nav, css, images, direction=None, fonts=None,
               rendition='', head=''):
    """`chapters`: [(file, title, body)]; `nav`: nested [(title, href, children)];
    `fonts`: {file: bytes}, stored in `fonts/`; `rendition`: OPF `<meta>` elements;
    `head`: markup for every chapter's `<head>`."""
    fonts = fonts or {}
    def nav_list(items):
        return '<ol>' + ''.join(
            f'<li><a href="{href}">{title}</a>{nav_list(children) if children else ""}</li>'
            for title, href, children in items) + '</ol>'

    def ncx_points(items, counter):
        out = ''
        for title, href, children in items:
            counter[0] += 1
            out += (f'<navPoint id="p{counter[0]}" playOrder="{counter[0]}">'
                    f'<navLabel><text>{title}</text></navLabel><content src="{href}"/>'
                    f'{ncx_points(children, counter)}</navPoint>')
        return out

    nav_doc = xhtml(metadata['title'],
                    f'<nav epub:type="toc" id="toc"><h1>{metadata["title"]}</h1>{nav_list(nav)}</nav>',
                    language)
    ncx = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
           f'<head><meta name="dtb:uid" content="{metadata["uuid"]}"/></head>'
           f'<docTitle><text>{metadata["title"]}</text></docTitle>'
           f'<navMap>{ncx_points(nav, [0])}</navMap></ncx>\n')

    manifest = ['<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
                '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
                '<item id="css" href="style.css" media-type="text/css"/>',
                '<item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>']
    for name in images:
        properties = ' properties="cover-image"' if name == 'cover.png' else ''
        manifest.append(f'<item id="{name.replace(".", "-")}" href="{name}" media-type="image/png"{properties}/>')
    for name in fonts:
        manifest.append(f'<item id="{name.replace(".", "-")}" href="fonts/{name}" media-type="font/ttf"/>')
    spine = ['<itemref idref="cover-page" linear="no"/>']
    for index, (file, _, _) in enumerate(chapters):
        manifest.append(f'<item id="c{index}" href="{file}" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="c{index}"/>')

    dc = [f'<dc:identifier id="uid">urn:uuid:{metadata["uuid"]}</dc:identifier>',
          f'<dc:identifier>urn:isbn:{metadata["isbn"]}</dc:identifier>',
          f'<dc:title>{metadata["title"]}</dc:title>',
          f'<dc:language>{language}</dc:language>',
          f'<dc:publisher>{metadata["publisher"]}</dc:publisher>',
          f'<dc:date>{metadata["date"]}</dc:date>',
          f'<dc:description>{metadata["description"]}</dc:description>']
    dc += [f'<dc:creator>{name}</dc:creator>' for name in metadata['authors']]
    dc += [f'<dc:subject>{subject}</dc:subject>' for subject in metadata['subjects']]
    progression = f' page-progression-direction="{direction}"' if direction else ''
    opf = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           + ''.join(dc)
           + '<meta property="dcterms:modified">2026-11-01T00:00:00Z</meta>'
           + rendition
           + '<meta name="cover" content="cover-png"/>'
           '</metadata><manifest>' + ''.join(manifest) + '</manifest>'
           f'<spine toc="ncx"{progression}>' + ''.join(spine) + '</spine></package>\n')

    cover_doc = xhtml(metadata['title'], '<div class="cover"><img src="cover.png" alt=""/></div>', language,
                      head=head)
    with zipfile.ZipFile(path, 'w') as epub:
        epub.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', zipfile.ZIP_STORED)
        def add(name, data):
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 1, 0, 0, 0))
            epub.writestr(info, data, zipfile.ZIP_DEFLATED)
        add('META-INF/container.xml',
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>')
        add('OEBPS/content.opf', opf)
        add('OEBPS/nav.xhtml', nav_doc)
        add('OEBPS/toc.ncx', ncx)
        add('OEBPS/style.css', css)
        add('OEBPS/cover.xhtml', cover_doc)
        for name, data in images.items():
            add(f'OEBPS/{name}', data)
        for name, data in fonts.items():
            add(f'OEBPS/fonts/{name}', data)
        for file, title, body in chapters:
            add(f'OEBPS/{file}', xhtml(title, body, language, head=head))


# English prose long enough that every chapter spans several 4,096-byte text
# records, so record boundaries, trailing entries and PalmDOC back-references
# across records are all exercised.
WEATHER = ['fog', 'rain', 'sleet', 'a clear sky', 'a west wind', 'hail', 'a calm sea', 'snow']
TASKS = ['trimmed the wick', 'polished the lens', 'wound the clockwork',
         'logged the passing ships', 'carried oil up the stair', 'mended the shutter']


def english_paragraphs(chapter, count):
    out = []
    for i in range(count):
        weather = WEATHER[(chapter * 3 + i) % len(WEATHER)]
        task = TASKS[(chapter + i * 5) % len(TASKS)]
        out.append(f'<p>On night {chapter * 100 + i + 1} the keeper noted {weather} over the '
                   f'harbour, {task}, and wrote in the almanac that the light had burned for '
                   f'{7 + (i * 13) % 6} hours without a single flicker worth recording.</p>')
    return '\n'.join(out)


def features():
    chapters = [
        ('chapter1.xhtml', 'The First Watch',
         '<h1 id="watch">The First Watch</h1>\n'
         '<p class="lead">This almanac begins on the night the old keeper handed over the keys.</p>\n'
         + english_paragraphs(1, 40)
         + '\n<p>The tide tables are explained in <a href="chapter3.xhtml#tides">the last chapter</a>.</p>'),
        ('chapter2.xhtml', 'Instruments',
         '<h1 id="instruments">Instruments</h1>\n'
         '<p>Every instrument in the lamp room has its own page.</p>\n'
         '<h2 id="lens">The Lens</h2>\n'
         + english_paragraphs(2, 20)
         + '\n<p class="figure"><img src="figure.png" alt="A sketch of the lens"/></p>\n'
         '<h2 id="clock">The Clockwork</h2>\n'
         + english_paragraphs(3, 20)
         + '\n<table><thead><tr><th>Part</th><th>Turns</th></tr></thead>'
         '<tbody><tr><td>Main spring</td><td>40</td></tr><tr><td>Governor</td><td>12</td></tr></tbody></table>'),
        ('chapter3.xhtml', 'Tides',
         '<h1 id="tides">Tides</h1>\n'
         + english_paragraphs(4, 30)
         + '\n<p class="note">Back to <a href="chapter1.xhtml#watch">the first watch</a>.</p>'),
    ]
    nav = [('The First Watch', 'chapter1.xhtml', []),
           ('Instruments', 'chapter2.xhtml',
            [('The Lens', 'chapter2.xhtml#lens', []), ('The Clockwork', 'chapter2.xhtml#clock', [])]),
           ('Tides', 'chapter3.xhtml', [])]
    css = ('.lead { font-style: italic; }\n.note { margin-left: 2em; }\n'
           '.figure { text-align: center; }\ntable { border-collapse: collapse; }\n'
           'td, th { border: 1px solid black; padding: 0.2em; }\n')
    write_epub(root / 'features.epub',
               metadata=dict(title="The Lantern Keeper's Almanac", uuid='6f1d1c0e-5b7a-4c1e-9a0e-0d3c8b2f4a11',
                             isbn='9780000000002', publisher='Yuedu Test Fixtures', date='2026-11-01',
                             description='A small book written for the MOBI importer tests.',
                             authors=['Mira Holt', 'Daniel Ashe'], subjects=['Lighthouses', 'Almanacs']),
               language='en', chapters=chapters, nav=nav, css=css,
               images={'cover.png': cover_png(), 'figure.png': figure_png()})


def chinese_paragraphs(chapter, count):
    places = ['港口', '山腰', '石階', '燈室', '海岸', '小屋']
    things = ['擦亮了鏡片', '添了燈油', '記下過往的船', '修好了窗板', '上緊了發條']
    return '\n'.join(
        f'<p>第{chapter * 100 + i + 1}夜，守燈人在{places[(chapter + i) % len(places)]}'
        f'{things[(chapter * 2 + i) % len(things)]}，又在本子上寫下：今夜燈火未曾熄滅，'
        f'海面風浪{"大" if i % 3 == 0 else "小"}，一共點了{7 + i % 5}個時辰。</p>'
        for i in range(count))


def vertical_chinese():
    chapters = [
        ('chapter1.xhtml', '第一章　交接',
         '<h1>第一章　交接</h1>\n' + chinese_paragraphs(1, 40)),
        ('chapter2.xhtml', '第二章　潮汐',
         '<h1>第二章　潮汐</h1>\n' + chinese_paragraphs(2, 40)),
    ]
    nav = [('第一章　交接', 'chapter1.xhtml', []), ('第二章　潮汐', 'chapter2.xhtml', [])]
    css = ('html { writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; '
           '-epub-writing-mode: vertical-rl; }\np { text-indent: 1em; margin: 0; }\n')
    write_epub(root / 'vertical-zh.epub',
               metadata=dict(title='守燈人手記', uuid='0b6c7e2a-93d4-4f58-8f0c-2e9d5a1b7c33',
                             isbn='9787000000001', publisher='閱讀測試書', date='2026-11-01',
                             description='為 MOBI 匯入測試寫的直排小書。',
                             authors=['林知秋'], subjects=['燈塔']),
               language='zh-TW', chapters=chapters, nav=nav, css=css,
               images={'cover.png': cover_png()}, direction='rtl')


def embedded_font():
    """A book whose stylesheet names a font it carries: Ahem (`../Ahem.ttf`, the
    CSS test font, public domain), every glyph a box, so a reader that loads it
    shows its text as boxes."""
    chapters = [
        ('chapter1.xhtml', 'Specimen',
         '<h1>Specimen</h1>\n<p class="specimen">The keeper wrote this line in the box font.</p>\n'
         '<p>And this one in the reader&#8217;s own.</p>'),
    ]
    css = ('@font-face { font-family: "Ahem"; src: url(fonts/Ahem.ttf); }\n'
           '.specimen { font-family: "Ahem"; }\n')
    write_epub(root / 'embedded-font.epub',
               metadata=dict(title='A Box Font Specimen', uuid='3e8f2a71-6c4d-4b9e-8a15-7d2c9f0e5b44',
                             isbn='9780000000019', publisher='Yuedu Test Fixtures', date='2026-11-01',
                             description='A one-page book that carries its own font.',
                             authors=['Mira Holt'], subjects=['Typography']),
               language='en', chapters=chapters, nav=[('Specimen', 'chapter1.xhtml', [])], css=css,
               images={'cover.png': cover_png()}, fonts={'Ahem.ttf': (root.parent / 'Ahem.ttf').read_bytes()})


def fixed_layout():
    """A two-page fixed-layout book: `rendition:layout` pre-paginated, each page a
    600 x 800 viewport with a picture and a positioned caption."""
    page = '<div class="page"><img src="{image}" alt=""/><p class="caption">{caption}</p></div>'
    chapters = [
        ('page1.xhtml', 'The Lamp', page.format(image='page1.png', caption='The lamp at dusk.')),
        ('page2.xhtml', 'The Sea', page.format(image='page2.png', caption='The sea at dawn.')),
    ]
    css = ('html, body { margin: 0; padding: 0; width: 600px; height: 800px; }\n'
           '.page { position: relative; width: 600px; height: 800px; }\n'
           '.page img { position: absolute; top: 0; left: 0; width: 600px; height: 800px; }\n'
           '.caption { position: absolute; bottom: 40px; left: 40px; font-size: 24px; color: white; }\n')
    write_epub(root / 'fixed-layout.epub',
               metadata=dict(title='Two Pictures of the Lighthouse', uuid='9a4b6d20-1e3f-4c7a-b2d8-5f6e0a1c3b77',
                             isbn='9780000000026', publisher='Yuedu Test Fixtures', date='2026-11-01',
                             description='A fixed-layout book for the MOBI importer tests.',
                             authors=['Daniel Ashe'], subjects=['Lighthouses']),
               language='en', chapters=chapters,
               nav=[('The Lamp', 'page1.xhtml', []), ('The Sea', 'page2.xhtml', [])], css=css,
               images={'cover.png': cover_png(),
                       'page1.png': png(600, 800, lambda x, y: (20 + y // 8, 40, 90 + x // 10)),
                       'page2.png': png(600, 800, lambda x, y: (10, 80 + y // 8, 140 + x // 12))},
               rendition=('<meta property="rendition:layout">pre-paginated</meta>'
                          '<meta property="rendition:spread">none</meta>'),
               head='<meta name="viewport" content="width=600, height=800"/>')


def convert(source, target, *options):
    subprocess.run([str(calibre), str(root / source), str(root / target), *options],
                   check=True, stdout=subprocess.DEVNULL)


def features_books():
    features()
    convert('features.epub', 'features.azw3')
    convert('features.epub', 'features.mobi', '--mobi-file-type', 'old')
    convert('features.epub', 'features-combo.mobi', '--mobi-file-type', 'both')
    convert('features.epub', 'features-uncompressed.mobi', '--mobi-file-type', 'old', '--dont-compress')


def vertical_books():
    vertical_chinese()
    convert('vertical-zh.epub', 'vertical-zh.azw3')
    convert('vertical-zh.epub', 'vertical-zh.mobi', '--mobi-file-type', 'old')


def embedded_font_books():
    embedded_font()
    convert('embedded-font.epub', 'embedded-font.azw3')


def fixed_layout_books():
    fixed_layout()
    convert('fixed-layout.epub', 'fixed-layout.azw3')


BOOKS = {'features': features_books, 'vertical-zh': vertical_books,
         'embedded-font': embedded_font_books, 'fixed-layout': fixed_layout_books}

if __name__ == '__main__':
    # Every run rewrites what it converts (Calibre writes a fresh UUID each time),
    # so name the books to make and leave the others' bytes alone. No name: all.
    if not calibre.exists():
        raise SystemExit(f'Calibre not found at {calibre}')
    for name in sys.argv[1:] or BOOKS:
        if name not in BOOKS:
            raise SystemExit(f'{name}: not one of {", ".join(BOOKS)}')
        BOOKS[name]()
    shutil.rmtree(root / '__pycache__', ignore_errors=True)
