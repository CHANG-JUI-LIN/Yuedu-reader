#!/usr/bin/env python3
"""Prepare/serve/clean the deterministic sources for DetailReaderBackSwipeUITests.

Two books on one server: "Navigation Swipe Fixture" (text) and "Navigation Manga
Fixture" (image pages, opened in the fixed-page reader). The text book's genre names the
source's second category, "Related" (one word: the detail page splits genres on spaces and
drops long ones), which also lists "Navigation Related Fixture": the detail page's genre
link and its 同題材 section lead there. "Navigation Audio Fixture" (an audiobook source) has the
same genre and category, for the audiobook detail page's links.

The app must be installed on the selected, booted simulator. Stop the app before
prepare/clean. Only records belonging to these fixture source UUIDs are changed.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import struct
import subprocess
import zlib

SOURCE_ID = "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4"
MANGA_SOURCE_ID = "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"
AUDIO_SOURCE_ID = "8B0E6A52-3C1F-4D7A-9E25-6F4C2B1D9A73"
SOURCE_IDS = {SOURCE_ID, MANGA_SOURCE_ID, AUDIO_SOURCE_ID}
ROOT = Path("/tmp/yuedu-back-swipe-fixture")
BASE = "http://localhost:18765"
MANGA_BASE = BASE + "/manga"
RELATED_BASE = BASE + "/related"
AUDIO_BASE = BASE + "/audio"
RELATED_CATEGORY = "Related"
# One colour per page. Chapter 1 has three pages and chapter 2 two, so the reader's
# page indicator also tells the chapters apart.
MANGA_PAGES = [[(214, 69, 65), (65, 131, 215), (38, 166, 91)], [(244, 179, 80), (142, 68, 173)]]


def support(simulator):
    container = subprocess.check_output([
        "xcrun", "simctl", "get_app_container", simulator,
        "com.zhangruilin.yuedureader", "data",
    ], text=True).strip()
    return Path(container) / "Library/Application Support"


def update_records(path, keep, additions=()):
    records = json.loads(path.read_text()) if path.exists() else []
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps([r for r in records if keep(r)] + list(additions)))


def drop_cached_pages(simulator):
    """Remove the app's cached detail and contents packages of the fixture's books.

    They are kept per source and book URL, not per rule, so a fixture rule added since (the
    genre) would not be read until they expire."""
    for name in ("book_info_cache", "toc_cache"):
        directory = support(simulator) / name
        if not directory.is_dir():
            continue
        for package in directory.glob("*.json"):
            # The host alone: JSON may write the URL's slashes escaped.
            if BASE.split("//", 1)[1] in package.read_text(errors="ignore"):
                for sibling in directory.glob(package.stem + ".*"):
                    sibling.unlink()


def png(width, height, rgb):
    """A solid-colour RGB PNG, written without an imaging library."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = (b"\x00" + bytes(rgb) * width) * height
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def catalog_entry(base, title):
    return (f'<div class="book"><h2>{title}</h2>'
            f'<a href="{base}/book.html">Read</a><span class="author">Regression</span></div>')


def write_book(directory, base, title, intro, chapters, kind=""):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "catalog.html").write_text(catalog_entry(base, title))
    (directory / "book.html").write_text(
        f'<h1>{title}</h1><div class="author">Regression</div><div class="kind">{kind}</div>'
        f'<div class="intro">{intro}</div><a class="toc" href="{base}/toc.html">Contents</a>')
    (directory / "toc.html").write_text(''.join(
        f'<a class="chapter" href="{base}/chapter{i}.html">Chapter {i+1}</a>' for i in range(len(chapters))))
    for i, content in enumerate(chapters):
        (directory / f"chapter{i}.html").write_text(f'<div id="content">{content}</div>')


def source(source_id, name, base, category, extra_categories=(), **fields):
    book_list = {"bookList": ".book", "name": "h2@text", "author": ".author@text", "bookUrl": "a@href"}
    categories = [{"title": category, "url": base + "/catalog.html"}] + list(extra_categories)
    return {
        "id": source_id, "bookSourceName": name, "bookSourceUrl": base,
        "enabled": True, "enabledExplore": True,
        "searchUrl": base + "/catalog.html?key={{key}}",
        "exploreUrl": json.dumps(categories),
        "ruleSearch": book_list,
        "ruleExplore": book_list,
        "ruleBookInfo": {"name": "h1@text", "author": ".author@text", "kind": ".kind@text",
                         "intro": ".intro@text", "tocUrl": ".toc@href"},
        "ruleToc": {"chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href"},
        "ruleContent": {"content": "#content@html"},
        **fields,
    }


def prepare(simulator):
    write_book(ROOT, BASE, "Navigation Swipe Fixture", "Edge swipe regression", [''.join(
        f'<p>Chapter {i+1} paragraph {j}. Reserved edge navigation must return to the original detail. '
        'Regular page turning remains available inside the reading surface.</p>' for j in range(60)) for i in range(3)],
        kind=RELATED_CATEGORY)
    write_book(ROOT / "related", RELATED_BASE, "Navigation Related Fixture", "Reached from a genre",
               ['<p>The related book.</p>'])
    (ROOT / "related.html").write_text(catalog_entry(BASE, "Navigation Swipe Fixture")
                                       + catalog_entry(RELATED_BASE, "Navigation Related Fixture"))
    write_book(ROOT / "audio", AUDIO_BASE, "Navigation Audio Fixture", "An audiobook with a genre",
               ['<p>Track one.</p>'], kind=RELATED_CATEGORY)
    (ROOT / "audio" / "related.html").write_text(catalog_entry(AUDIO_BASE, "Navigation Audio Fixture")
                                                 + catalog_entry(RELATED_BASE, "Navigation Related Fixture"))
    # MangaChapterParser reads the pages from the chapter's <img> tags.
    write_book(ROOT / "manga", MANGA_BASE, "Navigation Manga Fixture", "Image pages opened from a book detail", [''.join(
        f'<img src="{MANGA_BASE}/chapter{i}-page{j}.png">' for j in range(len(pages))) for i, pages in enumerate(MANGA_PAGES)])
    for i, pages in enumerate(MANGA_PAGES):
        for j, colour in enumerate(pages):
            (ROOT / "manga" / f"chapter{i}-page{j}.png").write_bytes(png(400, 600, colour))
    sources = [
        source(SOURCE_ID, "Navigation Swipe Fixture", BASE, "Navigation Test",
               extra_categories=[{"title": RELATED_CATEGORY, "url": BASE + "/related.html"}]),
        # bookSourceType 2 (image) is what BookStore.addOnlineBook reads as manga
        # (OnlineBookContentInference), so the detail opens FixedPageReaderView.
        source(MANGA_SOURCE_ID, "Navigation Manga Fixture", MANGA_BASE, "Manga Test", bookSourceType=2),
        # bookSourceType 1 (audio) opens AudiobookDetailView.
        source(AUDIO_SOURCE_ID, "Navigation Audio Fixture", AUDIO_BASE, "Audio Test",
               extra_categories=[{"title": RELATED_CATEGORY, "url": AUDIO_BASE + "/related.html"}], bookSourceType=1),
    ]
    update_records(support(simulator) / "book_sources.json", lambda r: r.get("id") not in SOURCE_IDS, sources)
    drop_cached_pages(simulator)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "serve", "clean"])
    parser.add_argument("--simulator", help="Live simulator UDID from scripts/sim.sh")
    args = parser.parse_args()
    if args.action == "serve":
        ThreadingHTTPServer(("127.0.0.1", 18765), partial(SimpleHTTPRequestHandler, directory=str(ROOT))).serve_forever()
    elif not args.simulator:
        parser.error("prepare/clean require --simulator")
    elif args.action == "prepare":
        prepare(args.simulator)
    else:
        directory = support(args.simulator)
        update_records(directory / "book_sources.json", lambda r: r.get("id") not in SOURCE_IDS)
        update_records(directory / "books_meta.json", lambda r: r.get("bookSourceId") not in SOURCE_IDS)
        drop_cached_pages(args.simulator)


if __name__ == "__main__":
    main()
