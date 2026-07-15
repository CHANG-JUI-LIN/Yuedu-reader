import copy
import hashlib
import io
import json
import socket
import tempfile
import threading
import unittest
import urllib.request
import zipfile
from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import FrozenInstanceError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import get_type_hints
from unittest import mock

import scripts.epub3_samples as epub3_samples
from scripts.epub3_samples import (
    DEFAULT_MANIFEST,
    ManifestError,
    Sample,
    SmokeTarget,
    load_manifest,
)


def _epub_bytes(label):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr("EPUB/content.xhtml", label)
    return output.getvalue()


class LocalHTTPServer:
    def __init__(self, routes):
        self.routes = routes
        self.requests = Counter()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests[self.path] += 1
                route = owner.routes[self.path]
                body = route["body"]
                self.send_response(route.get("status", 200))
                if route.get("malformed_chunked"):
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    declared_size = len(body) + 100
                    self.wfile.write(f"{declared_size:x}\r\n".encode("ascii"))
                    self.wfile.write(body)
                    self.wfile.flush()
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                self.send_header(
                    "Content-Length", str(route.get("content_length", len(body)))
                )
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                if route.get("interrupt"):
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def url(self, path):
        host, port = self.server.server_address
        return f"http://{host}:{port}{path}"


def _sample(server, path, payload, *, sample_id="sample-book", filename=None):
    return Sample(
        id=sample_id,
        title="Sample Book",
        source_url=server.url(path),
        catalog_url="https://example.com/catalog",
        filename=filename or f"{sample_id}.epub",
        sha256=hashlib.sha256(payload).hexdigest(),
        license="Test fixture",
        features=("reflowable",),
        smoke_targets=(
            SmokeTarget(
                chapter_index=0,
                spine_href=None,
                text_probes=("Sample text",),
                expects_image_page=False,
                expects_fallback=False,
            ),
        ),
        manual=False,
        manual_checkpoints=(),
    )


class EPUB3SamplesManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schema_version": 1,
            "samples": [
                {
                    "id": "sample-book",
                    "title": "Sample Book",
                    "source_url": "https://example.com/sample-book.epub",
                    "catalog_url": "https://example.com/catalog",
                    "filename": "sample-book.epub",
                    "sha256": "a" * 64,
                    "license": "Public-domain sample; metadata supplied by the publisher.",
                    "features": ["reflowable", "xhtml"],
                    "smoke_targets": [
                        {
                            "chapter_index": 0,
                            "text_probes": ["Sample text"],
                            "expects_image_page": False,
                            "expects_fallback": False,
                        }
                    ],
                    "manual": False,
                    "manual_checkpoints": [],
                }
            ]
        }

    def _load(self, manifest):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            return load_manifest(path)

    def test_loads_complete_entry(self):
        manifest = self._load(self.manifest)

        self.assertEqual(len(manifest.samples), 1)
        self.assertEqual(manifest.schema_version, 1)
        self.assertEqual(manifest.samples[0].id, "sample-book")
        self.assertEqual(manifest.samples[0].smoke_targets[0].chapter_index, 0)

    def test_rejects_missing_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["schema_version"]

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*required"):
            self._load(manifest)

    def test_rejects_unsupported_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["schema_version"] = 2

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*unsupported"):
            self._load(manifest)

    def test_rejects_boolean_schema_version(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["schema_version"] = True

        with self.assertRaisesRegex(ManifestError, "root.*schema_version.*integer"):
            self._load(manifest)

    def test_rejects_duplicate_ids(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"].append(copy.deepcopy(manifest["samples"][0]))
        manifest["samples"][1]["filename"] = "other.epub"

        with self.assertRaisesRegex(ManifestError, "sample-book.*id"):
            self._load(manifest)

    def test_rejects_duplicate_filenames(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"].append(copy.deepcopy(manifest["samples"][0]))
        manifest["samples"][1]["id"] = "other-book"

        with self.assertRaisesRegex(ManifestError, "other-book.*filename"):
            self._load(manifest)

    def test_rejects_non_https_source_url(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["source_url"] = "http://example.com/sample-book.epub"

        with self.assertRaisesRegex(ManifestError, "sample-book.*source_url"):
            self._load(manifest)

    def test_rejects_invalid_sha256(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["sha256"] = "ABC123"

        with self.assertRaisesRegex(ManifestError, "sample-book.*sha256"):
            self._load(manifest)

    def test_rejects_unsafe_filenames(self):
        for filename in (
            "/tmp/outside.epub",
            "../outside.epub",
            "nested/book.epub",
            "nested\\book.epub",
            ".",
            "..",
        ):
            with self.subTest(filename=filename):
                manifest = copy.deepcopy(self.manifest)
                manifest["samples"][0]["filename"] = filename

                with self.assertRaisesRegex(
                    ManifestError, "sample-book.*filename"
                ):
                    self._load(manifest)

    def test_rejects_missing_license_notes(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["samples"][0]["license"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*license"):
            self._load(manifest)

    def test_rejects_empty_feature_list(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["features"] = []

        with self.assertRaisesRegex(ManifestError, "sample-book.*features"):
            self._load(manifest)

    def test_rejects_manual_entry_without_checkpoints(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["manual"] = True

        with self.assertRaisesRegex(ManifestError, "sample-book.*manual_checkpoints"):
            self._load(manifest)

    def test_rejects_smoke_target_with_both_selectors(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["spine_href"] = "chapter.xhtml"

        with self.assertRaisesRegex(ManifestError, r"sample-book.*smoke_targets\[0\]"):
            self._load(manifest)

    def test_rejects_smoke_target_without_selector(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["samples"][0]["smoke_targets"][0]["chapter_index"]

        with self.assertRaisesRegex(ManifestError, r"sample-book.*smoke_targets\[0\]"):
            self._load(manifest)

    def test_rejects_negative_chapter_index(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["chapter_index"] = -1

        with self.assertRaisesRegex(ManifestError, "sample-book.*chapter_index"):
            self._load(manifest)

    def test_rejects_boolean_chapter_index(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["chapter_index"] = True

        with self.assertRaisesRegex(ManifestError, "sample-book.*chapter_index"):
            self._load(manifest)

    def test_rejects_whitespace_only_top_level_string(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["title"] = "   "

        with self.assertRaisesRegex(ManifestError, "sample-book.*title"):
            self._load(manifest)

    def test_rejects_whitespace_only_feature(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["features"] = ["  "]

        with self.assertRaisesRegex(ManifestError, "sample-book.*features"):
            self._load(manifest)

    def test_rejects_whitespace_only_text_probe(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["smoke_targets"][0]["text_probes"] = ["\t"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*text_probes"):
            self._load(manifest)

    def test_rejects_whitespace_only_manual_checkpoint(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["samples"][0]["manual"] = True
        manifest["samples"][0]["manual_checkpoints"] = ["\n"]

        with self.assertRaisesRegex(ManifestError, "sample-book.*manual_checkpoints"):
            self._load(manifest)

    def test_committed_manifest_contract(self):
        manifest = load_manifest(DEFAULT_MANIFEST)
        manual_samples = {sample.id: sample.title for sample in manifest.samples if sample.manual}

        self.assertEqual(manifest.schema_version, 1)
        self.assertEqual(len(manifest.samples), 42)
        self.assertEqual(
            manual_samples,
            {
                "accessible-epub3": "Accessible EPUB 3",
                "childrens-literature": "Children's Literature",
                "israelsailing": "Israel Sailing",
                "kusamakura": "Kusamakura",
                "linear-algebra": "Linear Algebra",
                "moby-dick": "Moby Dick",
                "page-blanche": "Page Blanche",
                "wasteland-otf": "The Waste Land with OTF fonts",
            },
        )

        samples = {sample.id: sample for sample in manifest.samples}
        self.assertEqual(
            samples["cc-shared-culture"].license,
            "CC BY-NC-SA 3.0 Unported (official catalog sample-specific license).",
        )

        linear_target = samples["linear-algebra"].smoke_targets[0]
        self.assertEqual(linear_target.spine_href, "xhtml/fcla-xml-2.30li17.xhtml")
        self.assertNotEqual(linear_target.spine_href, "xhtml/titlepage.xhtml")
        self.assertTrue(linear_target.text_probes)
        self.assertTrue(all(probe.strip() for probe in linear_target.text_probes))

        moby_checkpoints = " ".join(samples["moby-dick"].manual_checkpoints)
        self.assertIn("English justified body rhythm", moby_checkpoints)
        self.assertIn("long-word hyphenation", moby_checkpoints)

        wasteland_checkpoints = " ".join(samples["wasteland-otf"].manual_checkpoints)
        for expected_coverage in (
            "single-spine English layout",
            "body rhythm",
            "missing-glyph or tofu boxes",
            "embedded font unavailable",
            "readable sans-serif/static fallback",
            "semantic sections",
            "remain distinguishable",
            "embedded-font behavior",
            "baseline-supported",
        ):
            with self.subTest(wasteland_coverage=expected_coverage):
                self.assertIn(expected_coverage, wasteland_checkpoints)


class EPUB3SampleDownloadTests(unittest.TestCase):
    def assert_no_part_files(self, books_dir):
        self.assertEqual(list(books_dir.glob("*.part")), [])

    def test_successful_download_is_verified_and_atomically_moved(self):
        payload = _epub_bytes("successful download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                timeouts = []

                def recording_opener(url, *, timeout):
                    timeouts.append(timeout)
                    return urllib.request.urlopen(url, timeout=timeout)

                result = epub3_samples.fetch_sample(
                    sample, books_dir, opener=recording_opener
                )

                destination = books_dir / sample.filename
                self.assertTrue(result.ok)
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(result.path, destination.resolve(strict=True))
                self.assertEqual(destination.read_bytes(), payload)
                self.assertEqual(epub3_samples.sha256_file(destination), sample.sha256)
                self.assert_no_part_files(books_dir)
                self.assertEqual(timeouts, [60])

    def test_books_directory_symlink_switch_keeps_download_in_resolved_directory(self):
        payload = _epub_bytes("fixed resolved directory")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                directory_a = root / "A"
                directory_b = root / "B"
                directory_a.mkdir()
                directory_b.mkdir()
                books_link = root / "books"
                books_link.symlink_to(directory_a, target_is_directory=True)

                def switching_opener(url, *, timeout):
                    response = urllib.request.urlopen(url, timeout=timeout)
                    books_link.unlink()
                    books_link.symlink_to(directory_b, target_is_directory=True)
                    return response

                result = epub3_samples.fetch_sample(
                    sample, books_link, opener=switching_opener
                )

                destination_a = directory_a / sample.filename
                destination_b = directory_b / sample.filename
                part_files_a = list(directory_a.glob("*.part"))
                part_files_b = list(directory_b.glob("*.part"))
                self.assertTrue(
                    result.ok,
                    f"{result.message}; A parts={part_files_a}; B parts={part_files_b}",
                )
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(
                    result.path, directory_a.resolve(strict=True) / sample.filename
                )
                self.assertEqual(destination_a.read_bytes(), payload)
                self.assertFalse(destination_b.exists())
                self.assertTrue(epub3_samples.has_zip_signature(destination_a))
                self.assertEqual(
                    epub3_samples.sha256_file(destination_a), sample.sha256
                )
                self.assertEqual(part_files_a, [])
                self.assertEqual(part_files_b, [])
                self.assertEqual(server.requests["/book.epub"], 1)

    def test_unsafe_direct_sample_cannot_escape_books_directory(self):
        sentinel_payload = _epub_bytes("outside sentinel")
        with LocalHTTPServer({"/book.epub": {"body": sentinel_payload}}) as server:
            sample = _sample(
                server,
                "/book.epub",
                sentinel_payload,
                filename="../outside.epub",
            )
            with tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                books_dir = root / "books"
                books_dir.mkdir()
                sentinel = root / "outside.epub"
                sentinel.write_bytes(sentinel_payload)
                original_inode = sentinel.stat().st_ino

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("sample-book", result.message)
                self.assertIn("filename", result.message)
                self.assertEqual(sentinel.read_bytes(), sentinel_payload)
                self.assertEqual(sentinel.stat().st_ino, original_inode)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 0)

    def test_symlink_destination_cannot_escape_books_directory(self):
        sentinel_payload = _epub_bytes("symlink sentinel")
        with LocalHTTPServer({"/book.epub": {"body": sentinel_payload}}) as server:
            sample = _sample(server, "/book.epub", sentinel_payload)
            with tempfile.TemporaryDirectory(dir="/tmp") as directory:
                root = Path(directory)
                books_dir = root / "books"
                books_dir.mkdir()
                sentinel = root / "outside.epub"
                sentinel.write_bytes(sentinel_payload)
                original_inode = sentinel.stat().st_ino
                destination = books_dir / sample.filename
                destination.symlink_to(sentinel)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("sample-book", result.message)
                self.assertIn("filename", result.message)
                self.assertTrue(destination.is_symlink())
                self.assertEqual(sentinel.read_bytes(), sentinel_payload)
                self.assertEqual(sentinel.stat().st_ino, original_inode)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 0)

    def test_valid_cache_is_reused_without_request(self):
        payload = _epub_bytes("cached download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertTrue(result.ok)
                self.assertEqual(result.status, "cached")
                self.assertEqual(server.requests["/book.epub"], 0)
                self.assertEqual(destination.read_bytes(), payload)

    def test_checksum_mismatch_preserves_existing_book_and_cleans_part(self):
        expected_payload = _epub_bytes("expected")
        wrong_payload = _epub_bytes("wrong")
        existing_payload = _epub_bytes("existing")
        with LocalHTTPServer({"/book.epub": {"body": wrong_payload}}) as server:
            sample = _sample(server, "/book.epub", expected_payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(existing_payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("checksum", result.message.lower())
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)

    def test_non_zip_response_is_rejected_even_when_checksum_matches(self):
        payload = b"not a zip file"
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("ZIP", result.message)
                self.assertFalse((books_dir / sample.filename).exists())
                self.assert_no_part_files(books_dir)

    def test_interrupted_download_cleans_part(self):
        payload = _epub_bytes("interrupted")[:20]
        route = {
            "body": payload,
            "malformed_chunked": True,
        }
        with LocalHTTPServer({"/book.epub": route}) as server:
            sample = _sample(server, "/book.epub", _epub_bytes("complete"))
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                existing_payload = _epub_bytes("existing")
                destination.write_bytes(existing_payload)

                result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("IncompleteRead", result.message)
                self.assertNotIn("checksum", result.message.lower())
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 1)

    def test_fetch_all_continues_after_failure_and_aggregates_failure(self):
        invalid_payload = b"not a zip"
        valid_payload = _epub_bytes("valid second sample")
        routes = {
            "/invalid.epub": {"body": invalid_payload},
            "/valid.epub": {"body": valid_payload},
        }
        with LocalHTTPServer(routes) as server:
            samples = (
                _sample(
                    server,
                    "/invalid.epub",
                    invalid_payload,
                    sample_id="invalid",
                ),
                _sample(
                    server,
                    "/valid.epub",
                    valid_payload,
                    sample_id="valid",
                ),
            )
            with tempfile.TemporaryDirectory() as directory:
                results = epub3_samples.fetch_all(samples, Path(directory) / "books")

                self.assertEqual(
                    [result.status for result in results], ["failed", "downloaded"]
                )
                self.assertFalse(all(result.ok for result in results))
                self.assertEqual(server.requests["/invalid.epub"], 1)
                self.assertEqual(server.requests["/valid.epub"], 1)

    def test_force_redownloads_and_replaces_valid_cache(self):
        payload = _epub_bytes("force download")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(payload)
                original_inode = destination.stat().st_ino

                result = epub3_samples.fetch_sample(sample, books_dir, force=True)

                self.assertTrue(result.ok)
                self.assertEqual(result.status, "downloaded")
                self.assertEqual(server.requests["/book.epub"], 1)
                self.assertNotEqual(destination.stat().st_ino, original_inode)
                self.assertEqual(destination.read_bytes(), payload)
                self.assert_no_part_files(books_dir)

    def test_replace_failure_preserves_existing_book_and_cleans_part(self):
        payload = _epub_bytes("valid replacement")
        existing_payload = _epub_bytes("existing book")
        with LocalHTTPServer({"/book.epub": {"body": payload}}) as server:
            sample = _sample(server, "/book.epub", payload)
            with tempfile.TemporaryDirectory() as directory:
                books_dir = Path(directory) / "books"
                books_dir.mkdir()
                destination = books_dir / sample.filename
                destination.write_bytes(existing_payload)

                with mock.patch.object(
                    epub3_samples.os,
                    "replace",
                    side_effect=OSError("injected replace failure"),
                ) as replace:
                    result = epub3_samples.fetch_sample(sample, books_dir)

                self.assertFalse(result.ok)
                self.assertEqual(result.status, "failed")
                self.assertIn("injected replace failure", result.message)
                replace.assert_called_once()
                self.assertEqual(destination.read_bytes(), existing_payload)
                self.assert_no_part_files(books_dir)
                self.assertEqual(server.requests["/book.epub"], 1)


class FetchResultTests(unittest.TestCase):
    def test_ok_is_derived_from_status_and_read_only(self):
        path = Path("sample.epub")
        for status, expected_ok in (
            ("downloaded", True),
            ("cached", True),
            ("failed", False),
        ):
            with self.subTest(status=status):
                result = epub3_samples.FetchResult(
                    sample_id="sample-book",
                    status=status,
                    message="result",
                    path=path,
                )

                self.assertEqual(result.ok, expected_ok)
                with self.assertRaises((AttributeError, FrozenInstanceError)):
                    result.ok = not expected_ok

    def test_path_is_nonoptional(self):
        self.assertIs(get_type_hints(epub3_samples.FetchResult)["path"], Path)


class EPUB3SamplesCLITests(unittest.TestCase):
    def _run_main(self, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = epub3_samples.main(arguments)
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def test_duplicate_sample_with_force_is_fetched_once(self):
        captured = []

        def capture_fetch(samples, books_dir, *, force):
            captured.append((tuple(sample.id for sample in samples), force))
            return (
                epub3_samples.FetchResult(
                    sample_id="linear-algebra",
                    status="downloaded",
                    message="downloaded and verified",
                    path=Path(books_dir) / "linear-algebra.epub",
                ),
            )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            epub3_samples, "fetch_all", side_effect=capture_fetch
        ):
            exit_code, stdout, stderr = self._run_main(
                [
                    "fetch",
                    "--sample",
                    "linear-algebra",
                    "--sample",
                    "linear-algebra",
                    "--force",
                    "--books-dir",
                    directory,
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured, [(("linear-algebra",), True)])
        self.assertIn("downloaded: linear-algebra:", stdout)
        self.assertEqual(stderr, "")

    def test_repeatable_samples_preserve_first_order(self):
        captured_ids = []

        def capture_fetch(samples, books_dir, *, force):
            captured_ids.extend(sample.id for sample in samples)
            return tuple(
                epub3_samples.FetchResult(
                    sample_id=sample.id,
                    status="cached",
                    message="verified cache",
                    path=Path(books_dir) / sample.filename,
                )
                for sample in samples
            )

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            epub3_samples, "fetch_all", side_effect=capture_fetch
        ):
            exit_code, stdout, stderr = self._run_main(
                [
                    "fetch",
                    "--sample",
                    "moby-dick",
                    "--sample",
                    "linear-algebra",
                    "--sample",
                    "moby-dick",
                    "--books-dir",
                    directory,
                ]
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured_ids, ["moby-dick", "linear-algebra"])
        self.assertIn("cached: moby-dick:", stdout)
        self.assertIn("cached: linear-algebra:", stdout)
        self.assertEqual(stderr, "")

    def test_unknown_sample_reports_failure_only_on_stderr(self):
        exit_code, stdout, stderr = self._run_main(
            ["fetch", "--sample", "unknown-sample"]
        )

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("unknown sample ID(s): unknown-sample", stderr)

    def test_failed_fetch_reports_failure_only_on_stderr(self):
        failed_result = epub3_samples.FetchResult(
            sample_id="linear-algebra",
            status="failed",
            message="injected download failure",
            path=Path("linear-algebra.epub"),
        )
        with mock.patch.object(
            epub3_samples, "fetch_all", return_value=(failed_result,)
        ):
            exit_code, stdout, stderr = self._run_main(
                ["fetch", "--sample", "linear-algebra"]
            )

        self.assertEqual(exit_code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("failed: linear-algebra: injected download failure", stderr)


if __name__ == "__main__":
    unittest.main()
