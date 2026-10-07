import csv
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
from urllib.error import URLError

from scripts.aozora_catalog import build_catalog as builder

FIXTURE = Path(__file__).with_name('fixtures') / 'catalog.csv'


def zip_csv(csv_data=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('list_person_all_extended_utf8.csv', csv_data or FIXTURE.read_bytes().replace(b'\n', b'\r\n'))
    return output.getvalue()


class CatalogBuilderTests(unittest.TestCase):
    def test_merges_credits_and_filters_restricted_or_nonofficial_downloads(self):
        data, manifest = builder.build(zip_csv(), 'Wed, 07 Oct 2026 00:00:00 GMT')
        catalog = json.loads(data)
        self.assertEqual(catalog['schemaVersion'], 1)
        self.assertEqual([work['id'] for work in catalog['works']], ['1', '2'])
        self.assertEqual(catalog['works'][0]['credits'], [
            {'person': '001', 'role': '著者'}, {'person': '002', 'role': '翻訳者'}])
        self.assertEqual(catalog['works'][0]['title'], '架空の物語')
        self.assertEqual(catalog['works'][0]['sourcePublisher'], '架空書房')
        self.assertEqual([person['id'] for person in catalog['persons']], ['001', '002'])
        self.assertEqual(catalog['persons'][0]['name'], '架空 一郎')
        metadata = json.loads(manifest)
        self.assertEqual(metadata['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(metadata['workCount'], 2)
        self.assertEqual(metadata['sourceLastModified'], 'Wed, 07 Oct 2026 00:00:00 GMT')
        self.assertEqual(metadata['generatedAt'], '2026-10-07T00:00:00Z')
        self.assertEqual(metadata['license'], 'https://creativecommons.org/licenses/by/4.0/')
        self.assertIn('青空文庫', metadata['attribution'])

    def test_deterministic_bytes(self):
        self.assertEqual(builder.build(zip_csv()), builder.build(zip_csv()))
        csv_data = FIXTURE.read_text(encoding='utf-8-sig')
        reader = csv.DictReader(io.StringIO(csv_data))
        rows = list(reader)
        output = io.StringIO(newline='')
        writer = csv.DictWriter(output, fieldnames=reader.fieldnames, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(reversed(rows))
        self.assertEqual(builder.build(zip_csv()), builder.build(zip_csv(output.getvalue().encode('utf-8-sig'))))

    def test_network_outage_leaves_published_files_untouched(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'manifest.json').write_bytes(b'previous manifest')
            (root / 'works.json').write_bytes(b'previous catalog')
            with patch.object(builder, 'fetch_catalog', side_effect=URLError('DNS unavailable')):
                with patch('sys.stdout', new_callable=io.StringIO) as log:
                    self.assertEqual(builder.main(['--output', folder]), 0)
            self.assertIn('::notice::', log.getvalue())
            self.assertEqual((root / 'manifest.json').read_bytes(), b'previous manifest')
            self.assertEqual((root / 'works.json').read_bytes(), b'previous catalog')

    def test_fresh_outage_writes_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'new'
            with patch.object(builder, 'fetch_catalog', side_effect=URLError('offline')):
                self.assertEqual(builder.main(['--output', str(output)]), 0)
            self.assertFalse(output.exists())

    def test_cli_fixture_writes_exact_build_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'input.zip'
            source.write_bytes(zip_csv())
            self.assertEqual(builder.main(['--zip', str(source), '--output', str(root / 'out')]), 0)
            data, manifest = builder.build(zip_csv())
            self.assertEqual((root / 'out/works.json').read_bytes(), data)
            self.assertEqual((root / 'out/manifest.json').read_bytes(), manifest)

    def test_invalid_csv_is_an_error_not_an_empty_catalog(self):
        with self.assertRaises(ValueError):
            builder.build(zip_csv(b'wrong,columns\n1,2\n'))

    def test_official_zip_rule(self):
        for url in ['https://mirror.example/a.zip', 'http://www.aozora.gr.jp/a.zip',
                    'https://www.aozora.gr.jp.evil.example/a.zip',
                    'https://user@www.aozora.gr.jp/a.zip', 'https://www.aozora.gr.jp/a.html']:
            self.assertFalse(builder.is_official_zip(url))
        self.assertTrue(builder.is_official_zip('https://www.aozora.gr.jp/cards/001/files/1.zip'))


if __name__ == '__main__':
    unittest.main()
