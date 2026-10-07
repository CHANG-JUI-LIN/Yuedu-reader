#!/usr/bin/env python3
"""Build schema v1 from the official CSV. No mirrors, retries or catalog commits."""
import argparse
import csv
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import hashlib
import io
import json
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zipfile

SOURCE = 'https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip'
USER_AGENT = 'Yuedu-catalog/1 (+https://yuedureader.com/support)'
ATTRIBUTION = '書誌データ：青空文庫（CC BY 4.0）'
LICENSE = 'https://creativecommons.org/licenses/by/4.0/'
WORK_FIELDS = {
    'id': '作品ID', 'title': '作品名', 'yomi': '作品名読み', 'sortYomi': 'ソート用読み',
    'subtitle': '副題', 'kanaStyle': '文字遣い種別', 'ndc': '分類番号',
    'published': '公開日', 'updated': '最終更新日', 'card': '図書カードURL',
    'text': 'テキストファイルURL', 'textUpdated': 'テキストファイル最終更新日',
    'source': '底本名1', 'sourcePublisher': '底本出版社名1',
}
PERSON_FIELDS = ['人物ID', '姓', '名', '姓読み', '名読み', '姓読みソート用', '名読みソート用', '生年月日', '没年月日']


def is_official_zip(url):
    parsed = urlsplit(url)
    return (parsed.scheme == 'https' and parsed.netloc == 'www.aozora.gr.jp'
            and parsed.path.endswith('.zip') and not parsed.query and not parsed.fragment)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')


def build(zip_data, last_modified=None):
    with zipfile.ZipFile(io.BytesIO(zip_data)) as archive:
        files = [name for name in archive.namelist() if name.endswith('.csv')]
        if len(files) != 1:
            raise ValueError('Expected exactly one catalog CSV')
        source = archive.read(files[0]).decode('utf-8-sig')
    reader = csv.DictReader(io.StringIO(source, newline=''))
    required = set(WORK_FIELDS.values()) | set(PERSON_FIELDS) | {'役割フラグ', '作品著作権フラグ'}
    if not required.issubset(reader.fieldnames or []):
        raise ValueError('Catalog CSV is missing required columns')
    rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise ValueError('Catalog CSV contains a malformed row')
    # Sort first so duplicate metadata and person records are stable even if the
    # upstream generator changes row order. Credits retain the official role text.
    rows.sort(key=lambda row: tuple(row[name] for name in sorted(required)))
    excluded = {row['作品ID'] for row in rows if row['作品著作権フラグ'] != 'なし'}
    works, persons = {}, {}
    for row in rows:
        work_id, person_id = row['作品ID'], row['人物ID']
        if work_id in excluded or not is_official_zip(row['テキストファイルURL']):
            continue
        if not work_id or not person_id:
            raise ValueError('Public work or credited person has no ID')
        work = works.setdefault(work_id, {key: row[column] for key, column in WORK_FIELDS.items()} | {'credits': []})
        credit = {'person': person_id, 'role': row['役割フラグ']}
        if credit not in work['credits']:
            work['credits'].append(credit)
        persons.setdefault(person_id, {
            'id': person_id, 'name': ' '.join(filter(None, [row['姓'], row['名']])),
            'yomi': ' '.join(filter(None, [row['姓読み'], row['名読み']])),
            'sortYomi': row['姓読みソート用'] + row['名読みソート用'],
            'born': row['生年月日'], 'died': row['没年月日'],
        })
    for work in works.values():
        work['credits'].sort(key=lambda credit: (credit['person'], credit['role']))
    catalog = {'schemaVersion': 1, 'persons': [persons[key] for key in sorted(persons)],
               'works': [works[key] for key in sorted(works)]}
    data = canonical(catalog)
    # generatedAt describes this source revision, not the job's wall clock. That
    # makes identical input byte-identical and avoids uploading unchanged catalogs.
    if last_modified:
        generated = parsedate_to_datetime(last_modified).astimezone(timezone.utc)
    else:
        dates = [row[column] for row in rows for column in ['公開日', '最終更新日'] if row[column]]
        if not dates:
            raise ValueError('Catalog CSV has no source revision date')
        generated = datetime.fromisoformat(max(dates)).replace(tzinfo=timezone.utc)
    manifest = canonical({
        'schemaVersion': 1, 'generatedAt': generated.isoformat().replace('+00:00', 'Z'),
        'sourceLastModified': last_modified, 'workCount': len(works),
        'sha256': hashlib.sha256(data).hexdigest(), 'attribution': ATTRIBUTION, 'license': LICENSE,
    })
    return data, manifest


def fetch_catalog():
    with urlopen(Request(SOURCE, headers={'User-Agent': USER_AGENT}), timeout=60) as response:
        return response.read(), response.headers.get('Last-Modified')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path, help='Use a local CSV zip (fixture/testing)')
    parser.add_argument('--output', type=Path, default=Path('out'))
    arguments = parser.parse_args(argv)
    if arguments.zip:
        archive, modified = arguments.zip.read_bytes(), None
    else:
        try:
            archive, modified = fetch_catalog()
        except (URLError, TimeoutError, OSError) as error:
            # Aozora's official site is unavailable as of 2026-10-07. Leave the
            # last published revision intact; remove this skip policy if the
            # publishing contract later requires outages to fail the workflow.
            print(f'::notice::Official Aozora catalog unavailable; publishing nothing: {error}')
            return 0
    data, manifest = build(archive, modified)
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name, content in [('works.json', data), ('manifest.json', manifest)]:
        temporary = arguments.output / (name + '.tmp')
        temporary.write_bytes(content)
        temporary.replace(arguments.output / name)
    print(f'Built {json.loads(manifest)["workCount"]} public-domain works')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
