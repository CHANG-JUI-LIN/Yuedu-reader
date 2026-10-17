#!/usr/bin/env python3
"""A book source's search for WorkFillUITests, on http://localhost:18771.

A search for a title starting with 斗罗大陆 answers two books of that title, both by 唐家三少
(the second as 「唐家三少 著」), each with a description, a category and a cover; any other
title has no book, so the simulator's other shelf copies are not filled from here.
`/cover.png?t=<title>` is a cover image, at an address of each title's own, so the app's
cover cache never answers for a run's. `/log` lists the paths asked for since the server started.

    python3 -I scripts/work_fill_fixture.py
"""

import html
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

PORT = 18771
INTRO = "唐門外門弟子唐三，因偷學內門絕學為唐門所不容，跳崖明志時卻發現沒有死。"
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


COVER = png(120, 160, (200, 40, 40))


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
            self.send(200, COVER, "image/png")
        elif url.path == "/search":
            query = parse_qs(url.query).get("q", [""])[0]
            title = html.escape(query)
            books = "" if not query.startswith("斗罗大陆") else "".join(
                f'<li class="book"><a href="/book/{n}"><h3 class="name">{title}</h3></a>'
                f'<span class="author">{author}</span><p class="intro">{INTRO}</p>'
                f'<span class="kind">玄幻</span><img src="/cover.png?t={quote(query)}"/></li>'
                for n, author in ((1, "唐家三少"), (2, "唐家三少 著")))
            self.send(200, f"<html><body><ul>{books}</ul></body></html>".encode(), "text/html; charset=utf-8")
        else:
            self.send(404, b"not found", "text/plain")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
