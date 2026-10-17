#!/usr/bin/env python3
"""Prepare/serve/clean a 發現頁 whose covers overflow the app's cover memory.

One source, "Explore Cover Fixture", with CATEGORIES categories of BOOKS_PER_CATEGORY books.
Every book has its own solid-colour 480×640 cover — about 1.2 MB decoded, so the 500 covers
are well past CoverImagePipeline's 128 MB memory budget, which then evicts covers while the
page scrolls. Stop the server mid-session to check that a cover scrolled back into view is
still the source's cover (the slot holds it) and not the generated one (a refetch that fails).

The app must be installed on the selected, booted simulator. Stop the app before
prepare/clean. Only this fixture source's records are changed.
"""
import argparse
import colorsys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import struct
import subprocess
import time
import zlib

SOURCE_ID = "6A1F2C3D-4E5B-4C7D-8E9F-0A1B2C3D4E5F"
ROOT = Path("/tmp/yuedu-explore-cover-fixture")
PORT = 18769
BASE = f"http://localhost:{PORT}"
CATEGORIES = 25
BOOKS_PER_CATEGORY = 20


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


def png(width, height, rgb):
    """A solid-colour RGB PNG, written without an imaging library."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = (b"\x00" + bytes(rgb) * width) * height
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def colour(index, count):
    r, g, b = colorsys.hsv_to_rgb(index / count, 0.6, 0.85)
    return int(r * 255), int(g * 255), int(b * 255)


def prepare(simulator):
    ROOT.mkdir(parents=True, exist_ok=True)
    (ROOT / "book.html").write_text(
        '<h1>Explore Cover Book</h1><div class="author">Fixture</div>'
        f'<a class="toc" href="{BASE}/toc.html">Contents</a>')
    (ROOT / "toc.html").write_text(f'<a class="chapter" href="{BASE}/chapter.html">Chapter 1</a>')
    (ROOT / "chapter.html").write_text('<div id="content"><p>Fixture chapter.</p></div>')
    total = CATEGORIES * BOOKS_PER_CATEGORY
    categories = []
    for c in range(CATEGORIES):
        entries = []
        for b in range(BOOKS_PER_CATEGORY):
            n = c * BOOKS_PER_CATEGORY + b
            (ROOT / f"cover{n:03}.png").write_bytes(png(480, 640, colour(n, total)))
            entries.append(f'<div class="book"><h2>Cover {n:03}</h2><img src="{BASE}/cover{n:03}.png">'
                           f'<a href="{BASE}/book.html?n={n}">Read</a><span class="author">Fixture</span></div>')
        (ROOT / f"category{c}.html").write_text("".join(entries))
        categories.append({"title": f"Shelf {c + 1}", "url": f"{BASE}/category{c}.html"})
    book_list = {"bookList": ".book", "name": "h2@text", "author": ".author@text",
                 "bookUrl": "a@href", "coverUrl": "img@src"}
    source = {
        "id": SOURCE_ID, "bookSourceName": "Explore Cover Fixture", "bookSourceUrl": BASE,
        "enabled": True, "enabledExplore": True,
        "searchUrl": BASE + "/category0.html?key={{key}}",
        "exploreUrl": json.dumps(categories),
        "ruleSearch": book_list,
        "ruleExplore": book_list,
        "ruleBookInfo": {"name": "h1@text", "author": ".author@text", "tocUrl": ".toc@href"},
        "ruleToc": {"chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href"},
        "ruleContent": {"content": "#content@html"},
    }
    update_records(support(simulator) / "book_sources.json", lambda r: r.get("id") != SOURCE_ID, [source])


class SlowCoverHandler(SimpleHTTPRequestHandler):
    """Serves the fixture, holding each cover back `delay` seconds like a real CDN would."""
    delay = 0.0

    def do_GET(self):
        if self.path.endswith(".png") and self.delay:
            time.sleep(self.delay)
        super().do_GET()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "serve", "clean"])
    parser.add_argument("--simulator", help="Live simulator UDID from scripts/sim.sh")
    parser.add_argument("--delay-ms", type=int, default=0, help="serve: hold each cover back this long")
    args = parser.parse_args()
    if args.action == "serve":
        SlowCoverHandler.delay = args.delay_ms / 1000
        ThreadingHTTPServer(("127.0.0.1", PORT), partial(SlowCoverHandler, directory=str(ROOT))).serve_forever()
    elif not args.simulator:
        parser.error("prepare/clean require --simulator")
    elif args.action == "prepare":
        prepare(args.simulator)
    else:
        update_records(support(args.simulator) / "book_sources.json", lambda r: r.get("id") != SOURCE_ID)


if __name__ == "__main__":
    main()
