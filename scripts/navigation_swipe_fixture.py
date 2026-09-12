#!/usr/bin/env python3
"""Prepare/serve/clean the deterministic source for DetailReaderBackSwipeUITests.

The app must be installed on the selected, booted simulator. Stop the app before
prepare/clean. Only records belonging to this fixture's source UUID are changed.
"""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess

SOURCE_ID = "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4"
ROOT = Path("/tmp/yuedu-back-swipe-fixture")
BASE = "http://localhost:18765"


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


def prepare(simulator):
    ROOT.mkdir(exist_ok=True)
    (ROOT / "catalog.html").write_text(
        f'<div class="book"><h2>Navigation Swipe Fixture</h2>'
        f'<a href="{BASE}/book.html">Read</a><span class="author">Regression</span></div>')
    (ROOT / "book.html").write_text(
        '<h1>Navigation Swipe Fixture</h1><div class="author">Regression</div>'
        f'<div class="intro">Edge swipe regression</div><a class="toc" href="{BASE}/toc.html">Contents</a>')
    (ROOT / "toc.html").write_text(''.join(
        f'<a class="chapter" href="{BASE}/chapter{i}.html">Chapter {i+1}</a>' for i in range(3)))
    for i in range(3):
        (ROOT / f"chapter{i}.html").write_text('<div id="content">' + ''.join(
            f'<p>Chapter {i+1} paragraph {j}. Reserved edge navigation must return to the original detail. '
            'Regular page turning remains available inside the reading surface.</p>' for j in range(60)) + '</div>')
    source = {
        "id": SOURCE_ID, "bookSourceName": "Navigation Swipe Fixture", "bookSourceUrl": BASE,
        "enabled": True, "enabledExplore": True,
        "exploreUrl": json.dumps([{"title": "Navigation Test", "url": BASE + "/catalog.html"}]),
        "ruleExplore": {"bookList": ".book", "name": "h2@text", "author": ".author@text", "bookUrl": "a@href"},
        "ruleBookInfo": {"name": "h1@text", "author": ".author@text", "intro": ".intro@text", "tocUrl": ".toc@href"},
        "ruleToc": {"chapterList": "a.chapter", "chapterName": "text", "chapterUrl": "href"},
        "ruleContent": {"content": "#content@html"},
    }
    update_records(support(simulator) / "book_sources.json", lambda r: r.get("id") != SOURCE_ID, [source])


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
        update_records(directory / "book_sources.json", lambda r: r.get("id") != SOURCE_ID)
        update_records(directory / "books_meta.json", lambda r: r.get("bookSourceId") != SOURCE_ID)


if __name__ == "__main__":
    main()
