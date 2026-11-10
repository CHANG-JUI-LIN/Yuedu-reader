"""Reachability of book-source origins: DNS, TCP, TLS, then GET / once.

Usage: python3 -I probe.py ORIGINS.json [OUT.json]
ORIGINS.json is a JSON list of origins ("https://host[:port]"). Writes a JSON list of rows to
OUT.json, or to stdout. Standard library only, Python 3.8+, so it runs unchanged on the
remote probe host (`lc.py probe` copies it there).

It is a probe, not a client: it sends one plain GET with a user agent that says what it is,
never impersonates a browser, never retries, and never executes anything from a response.
System certificate validation stays on. A certificate the system rejects still proves the
server is up, so it counts as reachable: the app accepts every certificate, as Legado does
(`ServerTrustPolicy`).

Verdicts. Only the first five count as "dead" in `lc.py score`, and only when both regions
agree:
  dns_fail          no address for the host
  tcp_fail          no TCP connection within 12 s
  http_fail         connected, but no HTTP answer (timeout, reset)
  http_5xx          the server answered 5xx
  parked_or_closed  a parking, for-sale or site-closed page
  tls_error         a TLS failure other than the certificate (not counted as dead)
  reachable         an HTTP answer below 500, or a certificate the system rejects
"""
import concurrent.futures
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "YueduCompatProbe/1.0 (+reachability check; one GET per origin)"
PARKED = re.compile(
    r"域名(?:出售|转让|停放|过期)|domain (?:is )?for sale|parked|该域名|此域名|buy this domain"
    r"|网站(?:已|暂停|关闭)|站点已(?:关闭|停止)|已暂停|account suspended|suspended",
    re.I,
)
DEAD = {"dns_fail", "tcp_fail", "http_fail", "http_5xx", "parked_or_closed"}


def tls_context():
    # python.org builds ship no CA bundle; macOS keeps the system roots in /etc/ssl/cert.pem.
    cafile = "/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None
    return ssl.create_default_context(cafile=cafile)


def probe(origin):
    parts = urllib.parse.urlsplit(origin)
    host = parts.hostname
    port = parts.port or (443 if parts.scheme == "https" else 80)
    row = {"origin": origin, "host": host}
    started = time.time()

    def finish(verdict, **fields):
        row.update(fields)
        row["verdict"] = verdict
        row["ms"] = int((time.time() - started) * 1000)
        return row

    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        row["dns"] = sorted({info[4][0] for info in infos})[:4]
    except socket.gaierror as error:
        return finish("dns_fail", error=f"gaierror {error.errno}: {error.strerror}")
    try:
        with socket.create_connection((host, port), timeout=12):
            row["tcp"] = "ok"
    except OSError as error:
        return finish("tcp_fail", error=f"{type(error).__name__}: {error}")
    context = tls_context()
    if parts.scheme == "https":
        try:
            with socket.create_connection((host, port), timeout=12) as raw:
                with context.wrap_socket(raw, server_hostname=host):
                    row["tls"] = "ok"
        except ssl.SSLCertVerificationError as error:
            return finish("reachable", tls=f"certificate: {error.verify_message}")
        except (ssl.SSLError, OSError) as error:
            return finish("tls_error", tls=f"{type(error).__name__}: {error}")
    request = urllib.request.Request(
        origin + "/", headers={"User-Agent": USER_AGENT, "Accept": "text/html,*/*"}
    )
    try:
        with urllib.request.urlopen(request, timeout=20, context=context) as response:
            body = response.read(200_000)
            row["status"] = response.status
            row["finalURL"] = response.geturl()
    except urllib.error.HTTPError as error:
        row["status"] = error.code
        body = error.read(200_000) if hasattr(error, "read") else b""
    except ssl.SSLCertVerificationError as error:
        # A redirect to another host whose certificate the system rejects: still an answer.
        return finish("reachable", tls=f"redirect certificate: {error.verify_message}")
    except Exception as error:  # timeouts, resets, protocol errors: no HTTP answer
        return finish("http_fail", http=f"{type(error).__name__}: {error}")
    text = body.decode("utf-8", "replace")
    match = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    row["title"] = match.group(1).strip()[:80] if match else ""
    row["bytes"] = len(body)
    if PARKED.search(row["title"]) or (len(body) < 2000 and PARKED.search(text)):
        return finish("parked_or_closed")
    if row["status"] >= 500:
        return finish("http_5xx")
    return finish("reachable")


def main():
    origins = json.load(open(sys.argv[1]))
    rows = []
    with concurrent.futures.ThreadPoolExecutor(24) as pool:
        for row in pool.map(probe, origins):
            rows.append(row)
    text = json.dumps(rows, ensure_ascii=False, indent=1)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as out:
            out.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
