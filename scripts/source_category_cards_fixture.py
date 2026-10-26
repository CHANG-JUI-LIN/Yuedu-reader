#!/usr/bin/env python3
"""A book source's discover categories for SourceCategoryCardsUITests, on http://localhost:18773.

`/cat/<n>` (n = 1…4) is a category's first page: four books, each with a cover of its own
colour at `/cover.png?c=<n>&b=<i>`, so a card's fan shows three distinct covers. `/log` lists
the paths asked for since the server started, which the test reads to count the requests.

    python3 -I scripts/source_category_cards_fixture.py
"""

import colorsys
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 18773
CATEGORIES = {"1": "玄幻", "2": "都市", "3": "仙俠", "4": "歷史"}
LOG = []


def png(width, height, rgb):
    """A plain-colour PNG, so the cover has real image bytes to decode."""
    row = b"\x00" + bytes(rgb) * width
    raw = row * height

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def cover(category, book):
    hue = ((int(category) - 1) * 4 + int(book)) / 16
    r, g, b = colorsys.hsv_to_rgb(hue % 1, 0.6, 0.85)
    return png(120, 180, (int(r * 255), int(g * 255), int(b * 255)))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/log":
            self.send(200, "\n".join(LOG).encode(), "text/plain; charset=utf-8")
            return
        LOG.append(self.path)
        if url.path == "/cover.png":
            query = parse_qs(url.query)
            self.send(200, cover(query.get("c", ["1"])[0], query.get("b", ["1"])[0]), "image/png")
        elif url.path.startswith("/cat/") and url.path[5:] in CATEGORIES:
            number = url.path[5:]
            title = CATEGORIES[number]
            books = "".join(
                f'<li class="book"><a href="/book/{number}-{i}"><h3 class="name">{title}之書{i}</h3></a>'
                f'<span class="author">作者{i}</span><img src="/cover.png?c={number}&amp;b={i}"/></li>'
                for i in range(1, 5))
            self.send(200, f"<html><body><ul>{books}</ul></body></html>".encode(), "text/html; charset=utf-8")
        else:
            self.send(404, b"not found", "text/plain")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
