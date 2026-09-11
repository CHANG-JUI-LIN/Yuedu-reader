# Calibre write, position sync and desktop transfers

## Acceptance gate

The installed Calibre 9.14 desktop app was opened with Computer Use. Its Content
server was started from Preferences → Sharing over the net, limited to
127.0.0.1:8080 with interface fallback and Bonjour advertising disabled. The
existing Quick Start Guide was opened and paged in its browser reader.

`LiveCalibreIntegrationTests` then used the actual Yuedu OPDS client,
RemoteLibraryService, Readium package resources and CoreText paginator against
that desktop server. Navigation, search, empty search, opening, unshelved position
and bookmark persistence, shelf promotion and offline opening passed before
implementation of this second phase began.

Evidence: `/tmp/yuedu-calibre-live-reading2.log` and corresponding `.xcresult`.
This is an actual desktop server + iOS Simulator integration run, not a physical
iPhone or Calibre-Web run.

## Explicit remote writes

- Native Calibre Content Server: upload new EPUB/PDF/TXT/Markdown books and edit
  title/authors. Upload uses `POST /cdb/add-book/{job}/n/{filename}/{library}` with
  the file body. `n` refuses duplicate books. Metadata uses `/cdb/set-fields`.
- WebDAV: PUT with `If-None-Match: *`, MKCOL, same-folder rename with MOVE and
  `Overwrite: F`. Successful renames preserve the local book identity, bookmarks,
  reading data and offline copy. Extension changes are rejected.
- Ordinary OPDS and Calibre-Web remain readable. They do not expose the native
  Calibre write API; the management page explicitly reports unsupported writes.
- Current library selection and reverse-proxy prefix are preserved. A missing or
  inaccessible selected library must not silently become the default library.
- Feature detection does not imply write permission. The server's 401/403 remain
  visible; no trial upload is used to discover privileges.
- Write requests reject redirects. A timed-out or cancelled upload is not
  automatically repeated: Calibre's job ID is not an idempotency key. Refreshing
  the library is necessary to determine whether the server committed it.

## Reading position back to Calibre

A persisted per-connection switch enables native Calibre EPUB position sync.
It requires a Content Server user account. Each installation has its own device
identifier; the native API stores positions per user/device.

This supports the Content Server web reader. It does not claim automatic resume
in the standalone desktop viewer: Calibre 9.14's database deliberately drops
`last-read` annotations, even when the annotation POST returns HTTP 200, and the
desktop viewer merges web annotations with `merge_last_read=False`. A live
readback test detected this; the ineffective annotation write was removed.
Existing bookmarks and highlights remain untouched. The connection editor
explains this capability boundary explicitly.

The service reads Calibre's prepared manifest and chapter JSON DOM, matches a
bounded text context from the current CoreText position and produces Calibre's
own CFI. This is necessary because Calibre can rewrite the original EPUB's DOM
and add a cover. Standard OPF-based EPUB CFI cannot be substituted.
Vertical text uses the same existing, length-preserving punctuation normalization
as CoreText on both sides of the comparison, while CFI offsets still address the
original server DOM. Unique one-sided text contexts cover a paragraph beside a
rasterized table without confusing renderer attachment offsets with DOM offsets.

Only a precisely matched nonempty CFI is sent with `device` and `pos_frac` to
`/book-set-last-read-position/{library}/{book}/{format}`. An empty CFI would delete
the server's position and is never sent. Pending snapshots are stored separately
from shelf backups, bounded to 1024 UTF-16 units of surrounding text. Failures
preserve local reading state and allow explicit retry from book details.

Precise non-success conditions: server conversion still in progress; missing or
ambiguous matching text; synthetic text with no source text anchor;
changed/missing chapter; missing credentials or unsupported server. No fake CFI,
chapter-start substitution, fixed-delay retry or polling loop masks these states.
Image-only covers and blank positions are skipped before queuing, so the next
text page remains eligible for normal synchronization. Newer page positions
supersede obsolete snapshots before external writes.

Calibre-Web's web-session bookmark and Kobo state endpoints use different data
models and are not treated as the native Calibre position API.

## Computer-initiated transfers

Open Calibre library → Receive from computer in Yuedu. Start Wireless device
connection in desktop Calibre's Connect/share menu, discover it via
`_calibresmartdeviceapp._tcp` or enter its address/port. Yuedu opens the socket;
Calibre then initiates commands and Send to device file transfers.

The receiver uses decimal UTF-8 byte-length JSON frames, bounded buffering and
streamed files. Completed files enter the shared local import use case. Partial
files are discarded and never become shelf records. A registry associates
Calibre UUID/format with the local book ID; identical retransfers preserve
progress and bookmarks. A changed file is rejected explicitly instead of
silently replacing existing reading data.

The page must stay open and foregrounded during transfers. The device password
is session-scoped. Removal commands are limited to imported records owned by
this registry and refuse books held by an active reader presentation.

The handshake always sends the raw iOS device name. Calibre's separately
persisted drive display name can already include a localized "Wireless device"
prefix; feeding that value back into the handshake would add another prefix on
every reconnect. The drive metadata and user-assigned drive names still roundtrip
unchanged, including their stable device-store UUID.

## Reproducing live Content Server tests

Use a separate temporary Calibre library for write and progress acceptance. Keep
its server bound to loopback and use an authenticated test user; do not run a
standalone database writer alongside the GUI because Calibre uses a process lock.

Set `YUEDU_LIVE_CALIBRE_URL`, `YUEDU_LIVE_CALIBRE_USER` and
`YUEDU_LIVE_CALIBRE_PASSWORD`, then execute:

```sh
scripts/run_live_calibre_tests.sh LiveCalibreIntegrationTests LiveCalibreWritingTests LiveCalibreProgressTests
```

Optional `YUEDU_LIVE_CALIBRE_READONLY_USER` / `..._PASSWORD` enable the real 403
acceptance case. Credentials are placed in a temporary private test-run
configuration, never printed, and the configuration is removed at exit. Normal
unit test runs leave live-server suites disabled.

## Reproducing the desktop wireless test

Start the installed desktop application's wireless service, then set
`YUEDU_LIVE_CALIBRE_WIRELESS_HOST`, `..._PORT` and optionally `..._PASSWORD` and
`..._EXPECTED_TITLE`. Run `scripts/run_live_calibre_tests.sh LiveCalibreWirelessTests`
with `YUEDU_LIVE_CALIBRE_URL` also set for the shared runner.

The harness prints `READY_FOR_SEND`: select an existing EPUB in desktop Calibre
and choose Send to device. At `READY_FOR_EJECT`, choose Device → Eject device.
The harness observes the real eject command, the production receiver's ACK and
desktop TCP closure. At `READY_FOR_RECONNECT_CONFIRMATION`, confirm that the
desktop no longer displays a connected device, then send the printed token plus
newline to the printed test-only loopback TCP port. This operator gate carries
no Calibre protocol frames. The subsequent connection verifies the real desktop's
book-list scan and the persisted local ID, progress and bookmark.
At `READY_FOR_FINAL_EJECT`, eject once more from the desktop. The test keeps the
second connection alive until the real eject ACK and TCP closure, so its cleanup
does not interrupt Calibre's remaining device scan.

Calibre 9.14 clears its global connected-device state on a later device-manager
scan than the socket close. The original immediate-reconnect test encountered
the server's busy response. The test now follows actual desktop ejection and
observed disconnection; production retains the explicit busy error, with no
fixed delay or automatic retry.

## Primary protocol references

- [Calibre Content server](https://manual.calibre-ebook.com/server.html)
- [Calibre 9.14 mutation endpoints](https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/calibre/srv/cdb.py)
- [Calibre 9.14 prepared books and positions](https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/calibre/srv/books.py)
- [Calibre 9.14 desktop annotation merge excludes last-read](https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/calibre/gui2/actions/view.py#L133-L144)
- [Calibre 9.14 annotation persistence filtering](https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/calibre/db/backend.py#L345-L364)
- [Calibre 9.14 smart-device driver](https://github.com/kovidgoyal/calibre/blob/v9.14.0/src/calibre/devices/smart_device_app/driver.py)

## Verification results

Executed on 2026-09-11, with classes run individually and parallel testing off.

| Verification | Result | Evidence |
| --- | --- | --- |
| 12 directly relevant unit suites | 85 tests passed | `/tmp/yuedu-calibre-phase2-run3-*.log`, CFI/progress superseded by `run4`; wireless receiver/protocol by `wireless-live4` |
| Real native Content Server with Digest | Reading, writes and position readback passed | `run3-LiveCalibreIntegrationTests`, `run3-LiveCalibreWritingTests`, `run4-LiveCalibreProgressTests` logs/xcresults |
| Real native Content Server with Basic | Same three live suites passed | `/tmp/yuedu-calibre-basic-*.log` and xcresults |
| Actual desktop Send to device, reconnect and normal ejection | Readable EPUB, stable book ID/progress/bookmark and real desktop book list passed | `/tmp/yuedu-calibre-wireless-live4-LiveCalibreWirelessTests.log` and xcresult |
| Book-library entrance and receiver UI | 1 XCTest passed, all three entrances and the receiver without a configured server | `/tmp/yuedu-remote-library-ui1.log` and xcresult |
| Final application build | `BUILD SUCCEEDED`, exit 0 | `/tmp/yuedu-calibre-phase2-final-build2.log` |
| Localization and resource validation | 3 languages, 2,488 matching keys and format placeholders; plist lint and diff whitespace checks passed | Local validation; built app also contains the new local-network purpose string and Bonjour service |

The unit suites cover CFI mapping (5), progress service (9), remote writes (8),
HTTP/authentication/redirect policy (10), wireless framing (6), wireless receiver
(3), shared local import (3), active-resource ownership (1), PDF archive (13),
reading-record persistence (7), remote-library service (12), and connections (8).

Authenticated live writes used an isolated temporary library and test accounts.
Both Basic and Digest runs verified EPUB and TXT upload, metadata edit and
readback, wrong credentials and a read-only user's 403 rejection. Progress
readback verified the exact custom CFI `epubcfi(/4/2/4/4/1:7)` and fraction 0.23
against Calibre's real prepared DOM; the server's complete annotation map remained
unchanged. This is API readback evidence, not a claim that the authenticated
browser resume UI was manually exercised.

Computer Use selected the installed desktop Calibre's Send to device and Device
→ Eject device actions. The receiver imported the original Quick Start Guide's
53,661 bytes and Readium opened all 14 chapters. After restarting the isolated
BookStore and receiver service, the desktop scanned the same Calibre UUID/lpath,
and local book ID `62C30C3D-7679-446A-8FF4-073570D97A06`, fraction 0.375 and one
bookmark remained unchanged. The real desktop device table showed Quick Start
Guide, John Schember and 52.4 KB. Both ejections were acknowledged and completed
before teardown; no disconnect error dialog appeared in this completed run.
The desktop reconnect label retained a single localized device prefix. The
receiver suite also checked persisted Chinese, English and custom drive names
across two TCP sessions each without changing the device-store UUID.

After acceptance, Computer Use restored the original Content Server interface,
fallback and Bonjour preferences while leaving that server stopped. It also
restored wireless auto-start off, fixed-port off and an empty forced IP, then
quit the desktop application. The temporary authenticated servers were stopped;
ports 8080, 9090 and 19827 had no listeners. The original library still contained
its one unchanged Quick Start Guide; write acceptance used only the isolated
temporary library, and imported receiver fixtures were removed by test teardown.

Physical iPhone, physical-device VoiceOver, Calibre-Web, and a non-loopback LAN
Bonjour discovery/transfer require separate completed runs. WebDAV mutations have
targeted request/response regression coverage; external WebDAV write acceptance
has not been performed.
