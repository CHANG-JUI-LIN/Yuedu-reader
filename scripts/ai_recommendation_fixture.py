#!/usr/bin/env python3
"""AI 推薦 8f: a canned OpenAI-compatible service for `AIRecommendationUITests`.

The app is launched with `-debug-ai-endpoint http://localhost:18767` (DEBUG builds only), so
its AI service is this script instead of the reader's. Every `POST /v1/chat/completions`
answers with a strict `{"works": [...]}` list, as the real prompt asks. The answers alternate
between two lists, so 重新產生 visibly replaces the first one.

Run it before the UI test, from the repo root:

    python3 -I scripts/ai_recommendation_fixture.py

It binds 127.0.0.1 only and reads nothing from the request but its length.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 18767

LISTS = [
    [
        {"title": "十二國記", "author": "小野不由美", "reason": "你最近讀了不少架空奇幻，這部群像小說節奏紮實。"},
        {"title": "鬼吹燈", "author": "天下霸唱", "reason": "和你書架上的探險小說同一類。"},
    ],
    [
        {"title": "球狀閃電", "author": "劉慈欣", "reason": "同一位作者的另一部長篇。"},
        {"title": "銀河英雄傳說", "author": "田中芳樹", "reason": "喜歡宏大敘事的讀者常讀。"},
    ],
]


class Handler(BaseHTTPRequestHandler):
    served = 0

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        if not self.path.endswith("/chat/completions"):
            self.send_error(404)
            return
        works = LISTS[Handler.served % len(LISTS)]
        Handler.served += 1
        body = json.dumps({
            "id": f"fixture-{Handler.served}",
            "object": "chat.completion",
            "model": "fixture-model",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": json.dumps({"works": works}, ensure_ascii=False)},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write("fixture: " + (format % args) + "\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
