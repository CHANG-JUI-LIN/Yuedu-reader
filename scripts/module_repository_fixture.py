#!/usr/bin/env python3
"""A module repository for ModuleRepositoryUITests, on http://localhost:18772.

`/index.json` lists two modules, 甲模組 (`repo.alpha`) and 乙模組 (`repo.beta`), each at an
address relative to the index; each module has one list, 新書, read from `/new.html`.
`/log` lists the paths asked for since the server started.

    python3 -I scripts/module_repository_fixture.py
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = 18772
LOG = []
BASE = f"http://localhost:{PORT}"

INDEX = {
    "name": "測試倉庫",
    "modules": [
        {"id": "repo.alpha", "title": "甲模組", "description": "倉庫裡的第一個模組", "author": "測試作者",
         "version": "1.0", "url": "alpha.json"},
        {"id": "repo.beta", "title": "乙模組", "description": "倉庫裡的第二個模組", "author": "測試作者",
         "version": "1.0", "url": "beta.json"},
    ],
}


def module(module_id, title):
    return {
        "id": module_id, "title": title, "version": "1.0", "requiredVersion": "2.0", "author": "測試作者",
        "hosts": ["localhost"],
        "modules": [{"id": "new", "title": "新書", "request": {"url": f"{BASE}/new.html"},
                     "list": {"items": "li", "title": "h3@text"}}],
    }


FILES = {
    "/index.json": INDEX,
    "/alpha.json": module("repo.alpha", "甲模組"),
    "/beta.json": module("repo.beta", "乙模組"),
}


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
        path = urlparse(self.path).path
        if path == "/log":
            self.send(200, "\n".join(LOG).encode(), "text/plain; charset=utf-8")
            return
        LOG.append(self.path)
        if path in FILES:
            self.send(200, json.dumps(FILES[path], ensure_ascii=False).encode(), "application/json; charset=utf-8")
        elif path == "/new.html":
            self.send(200, "<ul><li><h3>倉庫第一本</h3></li></ul>".encode(), "text/html; charset=utf-8")
        else:
            self.send(404, b"not found", "text/plain")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
