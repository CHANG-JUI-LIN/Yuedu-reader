#!/usr/bin/env python3
"""Decode a diagnostic report a user sent from 設定 → 診斷與回報.

Reports live in Firestore `diagnosticReports/<report number>` (e.g. YD-7K3M-Q9TB) and
are readable only with admin access. The log is the `payload` bytes field: raw DEFLATE of
UTF-8 text (Apple's `NSData.compressed(using: .zlib)` writes raw deflate, no zlib header).

Get the payload one of these ways, then decode it:
  - Firebase console → Firestore → diagnosticReports → the report → copy `payload`
    (the console shows bytes as base64);
  - the Firebase MCP `firestore_get_document` tool (an agent session can do this);
  - a JSON export of the document.

Usage:
  python3 scripts/decode_diagnostic_report.py payload.b64          # file with base64
  python3 scripts/decode_diagnostic_report.py report.json          # document JSON with "payload"
  pbpaste | python3 scripts/decode_diagnostic_report.py -          # base64 on stdin
Writes the log text to stdout.
"""
import base64
import json
import sys
import zlib


def payload_from(text: str) -> bytes:
    text = text.strip()
    if text.startswith("{"):
        document = json.loads(text)
        fields = document.get("fields", document)
        value = fields["payload"]
        if isinstance(value, dict):  # Firestore REST shape: {"bytesValue": "..."}
            value = value.get("bytesValue") or value.get("_byteString") or next(iter(value.values()))
        text = value
    return base64.b64decode(text)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    source = sys.stdin.read() if sys.argv[1] == "-" else open(sys.argv[1], encoding="utf-8").read()
    raw = payload_from(source)
    sys.stdout.write(zlib.decompress(raw, -15).decode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
