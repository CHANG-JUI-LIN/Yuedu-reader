#!/usr/bin/env python3
"""Book sources for the search acceptance UI tests (search 9e), served on localhost:18768.

Run from the repo root before `SearchEmbyAcceptanceUITests`:

    python3 -I scripts/search_paging_fixture.py

- /text/search?q=…&page=N — a text source: pages 1 to 3 have 20 books each,
  「Paging N-01」 to 「Paging N-20」; page 4 on is empty, which ends its paging.
- /audio/search?q=…&page=N — an audio source: page 1 has two books, 「Paging Audio 01」 and 「02」.
- /heavy/<n>/search?q=…&page=N — for measuring: a source that never runs dry, twenty books a
  page, 「Paging H<n>-<page>-<i>」 by 作者<n>. Twenty of them stopped at page 10 are 4,000 books.
- /log — the text source's pages asked for so far, one per line.
- /reset — forgets them; each test asks it first.

Search for 「Paging」: the aggregator leaves out a result whose title and author lack the query.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 18768
PAGES = 3
PER_PAGE = 20
asked = []


def page_html(books):
    items = "".join(
        f'<li class="book"><a href="{href}"><h3>{name}</h3></a><span class="author">{author}</span></li>'
        for name, author, href in books
    )
    return f"<html><body><ul>{items}</ul></body></html>"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        page = int(parse_qs(url.query).get("page", ["1"])[0] or 1)
        if url.path == "/log":
            self.reply("\n".join(asked), "text/plain")
        elif url.path == "/reset":
            asked.clear()
            self.reply("", "text/plain")
        elif url.path == "/text/search":
            asked.append(str(page))
            books = []
            if page <= PAGES:
                books = [(f"Paging {page}-{i:02d}", "作者甲", f"/text/book/{page}-{i}") for i in range(1, PER_PAGE + 1)]
            self.reply(page_html(books))
        elif url.path.startswith("/heavy/") and url.path.endswith("/search"):
            n = url.path.split("/")[2]
            books = [(f"Paging H{n}-{page}-{i:02d}", f"作者{n}", f"/heavy/{n}/book/{page}-{i}")
                     for i in range(1, PER_PAGE + 1)]
            self.reply(page_html(books))
        elif url.path == "/audio/search":
            books = [(f"Paging Audio {i:02d}", "作者乙", f"/audio/book/{i}") for i in (1, 2)] if page == 1 else []
            self.reply(page_html(books))
        else:
            self.send_error(404)

    def reply(self, body, content_type="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        print("fixture:", format % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
