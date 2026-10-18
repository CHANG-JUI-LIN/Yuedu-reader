#!/usr/bin/env python3
"""One online book for `ReaderChromeAccessibilityUITests`, on localhost:18771.

Run from the repo root before the tests:

    python3 -I scripts/reader_chrome_fixture.py

The test writes a book source pointing here into a scratch `-book-source-store-dir`, then opens
the book from 資源庫 (the source's discover page), from 搜尋, and from 書架, and checks that the
reader's bottom bar reaches VoiceOver on each (feedback #15).

- /reset?token=NNNN — the run's book: 「Chrome Fixture NNNN」, a book no earlier run read, so
  its detail page offers 立即閱讀 rather than 繼續閱讀.
- /explore?page=N, /search?q=…&page=N — page 1 lists the run's book; later pages are empty.
- /book/<token> — its detail page and table of contents: three chapters.
- /book/<token>/<n> — chapter n's text.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 18771
token = "0000"
PARAGRAPH = "這是一段用來測試閱讀器工具列的正文。" * 6


def book_list():
    return (f'<html><body><ul><li class="book"><a href="/book/{token}"><h3>Chrome Fixture {token}</h3></a>'
            f'<span class="author">測試作者</span></li></ul></body></html>')


def toc():
    chapters = "".join(f'<li class="chapter"><a href="/book/{token}/{n}">第{n}章</a></li>' for n in (1, 2, 3))
    return f"<html><body><h1>Chrome Fixture {token}</h1><ul>{chapters}</ul></body></html>"


def chapter(n):
    paragraphs = "".join(f"<p>{PARAGRAPH}（{n}-{i}）</p>" for i in range(1, 40))
    return f'<html><body><div id="content">{paragraphs}</div></body></html>'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global token
        url = urlparse(self.path)
        query = parse_qs(url.query)
        parts = [p for p in url.path.split("/") if p]
        page = int(query.get("page", ["1"])[0] or 1)
        if url.path == "/reset":
            token = query.get("token", ["0000"])[0]
            self.reply("")
        elif url.path in ("/explore", "/search"):
            self.reply(book_list() if page == 1 else "<html><body><ul></ul></body></html>")
        elif len(parts) == 2 and parts[0] == "book":
            self.reply(toc())
        elif len(parts) == 3 and parts[0] == "book" and parts[2].isdigit():
            self.reply(chapter(int(parts[2])))
        else:
            self.send_error(404)

    def reply(self, text):
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print("fixture:", format % args, flush=True)


if __name__ == "__main__":
    print(f"reader chrome fixture on http://localhost:{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
