#!/usr/bin/env python3
"""なろう's saved pages for the module reading UI test (module ecosystem M5c), on localhost:18770.

Run from the repo root before `NarouReadingUITests`:

    python3 -I scripts/narou_reading_fixture.py

The test reads the bundled なろう module with its two sites moved here, so it searches, lists
the chapters and reads one exactly as the app does against syosetu.com:

- /novelapi/api/ — the search: one work, N9669BK's record under the run's ncode, titled
  「Mushoku Tensei <ncode>」 (XCUITest types Latin letters only, and the aggregator keeps a result
  whose title has the query).
- /<ncode>/ — its table of contents, the saved first page, whose next page is /n9669bk/?p=2.
- /n9669bk/?p=2 — the saved last page: no next page.
- /n9669bk/<n>/ — the saved episode, whatever n.
- /log — the paths asked for so far, one per line; /reset?ncode=N… forgets them and takes the
  run's ncode: a work no earlier run left a copy of on the simulator.
"""

import json
import pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 18770
FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "Tests" / "iOS" / "yuedu appTests" / "Fixtures" / "Narou"
asked = []
ncode = "N9669BK"


def search_reply():
    saved = json.loads((FIXTURES / "narou-api-ncode.json").read_text())
    work = saved[1]
    work["ncode"] = ncode
    work["title"] = f"Mushoku Tensei {ncode}"
    return json.dumps([{"allcount": 1}, work], ensure_ascii=False)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/log":
            return self.reply("\n".join(asked), "text/plain")
        if url.path == "/reset":
            global ncode
            asked.clear()
            ncode = parse_qs(url.query).get("ncode", ["N9669BK"])[0]
            return self.reply("", "text/plain")
        asked.append(url.path + ("?" + url.query if url.query else ""))
        parts = [p for p in url.path.split("/") if p]
        if url.path == "/novelapi/api/":
            self.reply(search_reply(), "application/json")
        elif parts == [ncode]:
            self.reply((FIXTURES / "narou-toc-p1.html").read_text())
        elif parts == ["n9669bk"] and url.query == "p=2":
            self.reply((FIXTURES / "narou-toc-p3.html").read_text())
        elif len(parts) == 2 and parts[0] == "n9669bk" and parts[1].isdigit():
            self.reply((FIXTURES / "narou-episode.html").read_text())
        else:
            self.send_error(404)

    def reply(self, text, kind="text/html"):
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", f"{kind}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"なろう fixture on http://localhost:{PORT}")
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
