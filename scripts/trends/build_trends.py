#!/usr/bin/env python3
"""Build 趨勢's lists from Wikipedia, Wikidata and Bangumi, once a day.

Plan: docs/superpowers/plans/2026-10-21-trends-module.md. No web-novel platform is ever asked
(maintainer, 2026-10-21): the works come from Wikipedia's categories, their popularity from
Wikipedia's pageviews, whether a web novel is finished from Bangumi, and the classics from
Wikidata. Each list is written as <output>/<region>/<list>.json, for the official module 趨勢.
"""
import argparse
import html
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sqlite3
import sys
import time
import unicodedata
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

USER_AGENT = 'Yuedu-trends/1 (+https://yuedureader.com/support)'
ATTRIBUTION = '資料：維基百科、維基數據（CC BY-SA 4.0）、Bangumi'
LICENSE = 'https://creativecommons.org/licenses/by-sa/4.0/'
SCHEMA_VERSION = 1
LIST_LENGTH = 50
# A list's works: Wikidata's classes for a written story. A page in a pool's categories whose
# item is something else (most often the TV series adapted from it) is left out.
WORK_CLASSES = {
    'Q8261',       # novel
    'Q1667921',    # novel series
    'Q277759',     # book series
    'Q7725634',    # literary work
    'Q47461344',   # written work
    'Q747381',     # light novel
    'Q104213567',  # light novel series
    'Q2552040',    # web novel
    'Q136441690',  # Chinese web novel
    'Q137169253',  # Japanese web novel
}
# 經典名著's works. Wikidata types most classics as a literary work whose form (P7937) is a novel
# (紅樓夢, Pride and Prejudice), so the class novel alone missed nearly all of them, while literary
# work alone brings in 毛主席語錄, 永樂大典, SCP and treaties (measured 2026-10-21). A classic is a
# novel or novel series by class, a novel, novella, short story or collection by form, or a
# monogatari or wuxia novel by genre (源氏物語, a 作り物語, and 射鵰英雄傳 have no form).
CLASSIC_CLASSES = ['Q8261', 'Q1667921']                     # novel, novel series
CLASSIC_FORMS = ['Q8261', 'Q149537', 'Q49084', 'Q1279564']  # novel, novella, short story, short story collection
CLASSIC_GENRES = ['Q1503147', 'Q11385322', 'Q9378888']      # monogatari, tsukuri monogatari, wuxia novel
# A classic's language (P407) is often a stage or a written form of the language: 紅樓夢 is in
# written vernacular Chinese, 西遊記 in written Chinese, 源氏物語 in Early Middle Japanese, The
# Canterbury Tales in Middle English, Harry Potter in British English.
CHINESE = ('Q7850', 'Q783605', 'Q3110592', 'Q37041', 'Q727694', 'Q9192')
JAPANESE = ('Q5287', 'Q182695', 'Q1816184', 'Q1332057', 'Q5736700', 'Q5326692')
ENGLISH = ('Q1860', 'Q7979', 'Q7976', 'Q36395', 'Q1472196')
# Both scripts read the same Chinese label and convert it (`convert_variant`): the zh-tw label is
# its own editor's choice and can be another name (羅本 for 三國演義's 羅貫中, measured 2026-10-21).
CHINESE_LABELS = ('zh', 'zh-hant', 'zh-hans', 'zh-tw', 'zh-cn', 'zh-hk', 'zh-sg')
REFRESH_POOL = timedelta(days=7)
REFRESH_TEXT = timedelta(days=7)
FIRST_DAYS = 366
WINDOWS = {'today': 1, 'month': 30, 'year': 365}


@dataclass(frozen=True)
class Pool:
    """The works one Wikipedia holds for a region: its categories, walked `depth` levels."""
    wiki: str
    categories: tuple
    depth: int

    @property
    def project(self):
        return self.wiki.removesuffix('.org')


@dataclass(frozen=True)
class Region:
    """A 地區 option: the pool it ranks, the script it is written in, Wikidata's label languages
    in the order they are taken, and the languages its classics are written in."""
    pool: str
    variant: str = None
    labels: tuple = ()
    classic_languages: tuple = ()
    lists: tuple = ('today', 'month', 'year', 'completed', 'classics')


def english_categories(today):
    return tuple(f'Category:{year} English-language novels' for year in range(2000, today.year + 1))


POOLS = {
    'zh': Pool('zh.wikipedia.org', ('Category:中华人民共和国网络小说',), 4),
    'ja': Pool('ja.wikipedia.org', ('Category:小説家になろうの小説', 'Category:カクヨムの小説'), 2),
    'en': Pool('en.wikipedia.org', english_categories(date.today()), 1),
}
REGIONS = {
    'zh-Hant': Region('zh', 'zh-tw', CHINESE_LABELS, CHINESE),
    'zh-Hans': Region('zh', 'zh-cn', CHINESE_LABELS, CHINESE),
    'ja': Region('ja', None, ('ja',), JAPANESE),
    # Published books are finished: 完結推薦 is a web-novel list (plan, "Calls of mine").
    'en': Region('en', None, ('en',), ENGLISH, ('today', 'month', 'year', 'classics')),
}


# MARK: - Pure parts


def keeps_work(classes):
    """Whether an item whose P31 values are `classes` is a written story."""
    return not WORK_CLASSES.isdisjoint(classes)


def strip_disambiguation(title):
    """`天官赐福 (小说)` → `天官赐福`: the work's name without the article's qualifier."""
    return re.sub(r'\s*[（(][^（）()]*[）)]\s*$', '', title)


_PUNCTUATION = re.compile(r'[\s\W_]+', re.UNICODE)


def normalize_title(text):
    """Titles compared across sites: width, case, spacing and punctuation (～ and 〜, ・) folded."""
    folded = unicodedata.normalize('NFKC', text or '').casefold()
    return _PUNCTUATION.sub('', folded)


def label(labels, languages):
    """A Wikidata `labels` value in the first of `languages` it has."""
    for language in languages:
        value = labels.get(language, {}).get('value')
        if value:
            return value
    return None


def window_total(daily, latest, days):
    """Views over the `days` days that end on `latest`, from `{YYYYMMDD: views}`."""
    first = latest - timedelta(days=days - 1)
    return sum(views for day, views in daily.items() if first <= parse_day(day) <= latest)


def ranked(totals, limit=LIST_LENGTH):
    """Keys by their total, most first, ties by key; nothing without views."""
    return [key for key, total in sorted(totals.items(), key=lambda pair: (-pair[1], pair[0])) if total > 0][:limit]


def parse_day(text):
    return datetime.strptime(text[:8], '%Y%m%d').date()


def format_day(day):
    return day.strftime('%Y%m%d')


def bangumi_ended(subject):
    """Whether a Bangumi book subject says its serialization ended: 连载结束 or 结束 given."""
    for item in subject.get('infobox') or []:
        if item.get('key') in ('连载结束', '结束') and isinstance(item.get('value'), str) and item['value'].strip():
            return True
    return False


def bangumi_authors(subject):
    for item in subject.get('infobox') or []:
        if item.get('key') == '作者':
            value = item.get('value')
            if isinstance(value, str):
                return [value]
            if isinstance(value, list):
                return [entry.get('v', '') for entry in value if isinstance(entry, dict)]
    return []


def same_author(ours, theirs):
    """Whether two sets of folded names share a person. A pen name is written longer or shorter
    on one side (Wikidata 唐七, Bangumi 唐七公子; 平鳥コウ and 平鳥コウ (XPJbox), 2026-10-21), so
    one name containing the other is the same person; the titles already matched exactly."""
    return any(mine in other or other in mine for mine in ours for other in theirs)


def bangumi_match(subjects, titles, authors):
    """The novel among a Bangumi search's `subjects` that is this work: its name or Chinese
    name equal to one of `titles`, and, where both sides name an author, the same author."""
    wanted = {normalize_title(title) for title in titles if title}
    by_author = {normalize_title(author) for author in authors if author} - {''}
    for subject in subjects:
        if subject.get('platform') != '小说':
            continue
        names = {normalize_title(subject.get('name')), normalize_title(subject.get('name_cn'))}
        if wanted.isdisjoint(names):
            continue
        theirs = {normalize_title(author) for author in bangumi_authors(subject)} - {''}
        if by_author and theirs and not same_author(by_author, theirs):
            continue
        return subject
    return None


def list_document(region, name, works, generated):
    """A list's file: what the module reads, `works` in order."""
    document = {
        'schemaVersion': SCHEMA_VERSION, 'region': region, 'list': name,
        'generatedAt': generated.isoformat().replace('+00:00', 'Z'),
        'attribution': ATTRIBUTION, 'license': LICENSE, 'works': works,
    }
    return (json.dumps(document, ensure_ascii=False, indent=1) + '\n').encode('utf-8')


def article_url(wiki, title, variant=None):
    """The article, in `variant`'s script where the wiki converts (zh: `/zh-tw/…`)."""
    return f'https://{wiki}/{variant or "wiki"}/{quote(title.replace(" ", "_"))}'


def one_per_series(order, found):
    """`order` with a series kept once, at its best place: Harry Potter's seven volumes and the
    series itself, 三體 and 地球往事, are one entry. A work's series is its P179, else itself."""
    seen, kept = set(), []
    for qid in order:
        series = (claim_ids(found.get(qid, {}), 'P179') or [qid])[0]
        if series in seen or qid in seen:
            continue
        seen.update((series, qid))
        kept.append(qid)
    return kept


def work_authors(entity):
    """A work's people: its creator (P170) before its authors (P50). The Hitchhiker's Guide's
    series names Douglas Adams as creator and only Eoin Colfer as author (2026-10-21)."""
    return list(dict.fromkeys(claim_ids(entity, 'P170') + claim_ids(entity, 'P50')))


# MARK: - Requests


class Client:
    """JSON over HTTPS as this app, each host no faster than its interval."""

    def __init__(self, intervals):
        self.intervals = intervals
        self.last = {}

    def _pace(self, host):
        interval = self.intervals.get(host, 0.1)
        wait = self.last.get(host, 0) + interval - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        self.last[host] = time.monotonic()

    def json(self, url, params=None, body=None, headers=None):
        host = url.split('/')[2]
        self._pace(host)
        data = None
        if params and body is None and len(urlencode(params)) > 1500:
            # Long title lists overflow a URL (HTTP 414 on ja.wikipedia, measured); the
            # MediaWiki API takes the same parameters as a form.
            data, params = urlencode(params).encode('utf-8'), None
        elif body is not None:
            data = json.dumps(body, ensure_ascii=False).encode('utf-8')
        full = url + ('?' + urlencode(params) if params else '')
        request = Request(full, data=data, headers={'User-Agent': USER_AGENT, 'Accept': 'application/json',
                                                    **(headers or {})})
        if body is not None:
            request.add_header('Content-Type', 'application/json')
        with urlopen(request, timeout=120) as response:
            return json.load(response)


def mediawiki(client, wiki, **params):
    return client.json(f'https://{wiki}/w/api.php', {**params, 'format': 'json', 'formatversion': '2'})


def category_pages(client, pool):
    """The pool's articles: its categories' pages, `depth` levels of subcategories down."""
    seen, pages, frontier = set(pool.categories), set(), list(pool.categories)
    for _ in range(pool.depth):
        following = []
        for category in frontier:
            cont = {}
            while True:
                answer = mediawiki(client, pool.wiki, action='query', list='categorymembers', cmtitle=category,
                                   cmlimit='500', cmnamespace='0|14', **cont)
                for member in answer['query']['categorymembers']:
                    if member['ns'] == 14 and member['title'] not in seen:
                        seen.add(member['title'])
                        following.append(member['title'])
                    elif member['ns'] == 0:
                        pages.add(member['title'])
                if 'continue' not in answer:
                    break
                cont = answer['continue']
        frontier = following
    return sorted(pages)


def page_items(client, wiki, titles, variants=False):
    """`{title: {'qid': …, 'variants': {…}}}` for articles, 20 at a time."""
    found = {}
    for start in range(0, len(titles), 20):
        params = dict(action='query', titles='|'.join(titles[start:start + 20]), prop='pageprops|info',
                      ppprop='wikibase_item')
        if variants:
            params['inprop'] = 'varianttitles'
        for page in mediawiki(client, wiki, **params)['query']['pages']:
            qid = page.get('pageprops', {}).get('wikibase_item')
            if qid:
                found[page['title']] = {'qid': qid, 'variants': page.get('varianttitles', {})}
    return found


def entities(client, qids, props='claims|labels|sitelinks'):
    found = {}
    qids = sorted(set(qids))
    for start in range(0, len(qids), 50):
        answer = client.json('https://www.wikidata.org/w/api.php', {
            'action': 'wbgetentities', 'ids': '|'.join(qids[start:start + 50]), 'props': props, 'format': 'json'})
        found.update(answer.get('entities', {}))
    return found


def claim_ids(entity, prop):
    values = []
    for claim in entity.get('claims', {}).get(prop, []):
        value = claim.get('mainsnak', {}).get('datavalue', {}).get('value')
        if isinstance(value, dict) and 'id' in value:
            values.append(value['id'])
    return values


def daily_views(client, project, title, first, last):
    """`{YYYYMMDD: views}` by people, `first` to `last`. Wikimedia answers 404 for an article
    with no views in the range (a new or renamed one): no views."""
    url = ('https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/'
           f'{project}/all-access/user/{quote(title.replace(" ", "_"), safe="")}/daily/'
           f'{format_day(first)}00/{format_day(last)}00')
    try:
        answer = client.json(url)
    except HTTPError as error:
        if error.code == 404:
            return {}
        raise
    return {item['timestamp'][:8]: item['views'] for item in answer.get('items', [])}


def extracts(client, wiki, titles, variant=None):
    """Each article's first sentences, in `variant`'s script, 20 at a time."""
    found = {}
    for start in range(0, len(titles), 20):
        params = dict(action='query', titles='|'.join(titles[start:start + 20]), prop='extracts', exintro='1',
                      explaintext='1', exsentences='3', exlimit='20')
        if variant:
            params['variant'] = variant
        for page in mediawiki(client, wiki, **params)['query']['pages']:
            text = (page.get('extract') or '').strip()
            if text:
                found[page['title']] = text
    return found


def wikitext_literal(text):
    """`text` as wikitext that renders as itself: ASCII punctuation as character references, so
    nothing in a name is markup. `<nowiki>` would do as much but also stops the conversion."""
    return ''.join(f'&#{ord(character)};' if character.isascii() and not character.isalnum() else character
                   for character in text)


def convert_variant(client, wiki, texts, variant):
    """`{text: text in variant's script}`, by the wiki's own converter, the one that gives its
    titles and extracts: Wikidata's `zh` label is in whichever script its editor wrote
    (墨香铜臭, 当年明月 on 華語（繁）, measured 2026-10-21)."""
    texts = sorted({text for text in texts if text})
    converted = {}
    for start in range(0, len(texts), 100):
        batch = texts[start:start + 100]
        answer = mediawiki(client, wiki, action='parse', contentmodel='wikitext', variant=variant, prop='text',
                           disablelimitreport='1', text='\n\n'.join(wikitext_literal(text) for text in batch))
        paragraphs = [html.unescape(paragraph).strip()
                      for paragraph in re.findall(r'<p>(.*?)</p>', answer['parse']['text'], re.S)]
        if len(paragraphs) != len(batch):
            raise ValueError(f'{wiki} gave {len(paragraphs)} paragraphs for {len(batch)} names')
        converted.update(zip(batch, paragraphs))
    return converted


def sparql(client, query):
    answer = client.json('https://query.wikidata.org/sparql', {'query': query},
                         headers={'Accept': 'application/sparql-results+json'})
    return answer['results']['bindings']


def bangumi_search(client, keyword):
    answer = client.json('https://api.bgm.tv/v0/search/subjects?limit=5',
                         body={'keyword': keyword, 'filter': {'type': [1]}})
    return answer.get('data') or []


# MARK: - The store


SCHEMA = '''
create table if not exists pool (project text, title text, qid text, variants text, refreshed text,
                                 primary key (project, title));
create table if not exists views (project text, title text, day text, views integer,
                                  primary key (project, title, day));
create table if not exists finished (qid text primary key, subject integer, ended integer, checked text);
create table if not exists intro (wiki text, title text, variant text, text text, refreshed text,
                                  primary key (wiki, title, variant));
create table if not exists meta (key text primary key, value text);
'''


class Store:
    """What the job keeps between days on the host: the pools, their views, Bangumi's answers."""

    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.executescript(SCHEMA)

    def meta(self, key):
        row = self.db.execute('select value from meta where key = ?', (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute('insert or replace into meta values (?, ?)', (key, value))
        self.db.commit()

    def pool(self, project):
        rows = self.db.execute('select title, qid, variants from pool where project = ?', (project,))
        return {title: {'qid': qid, 'variants': json.loads(variants or '{}')} for title, qid, variants in rows}

    def replace_pool(self, project, works, now):
        self.db.execute('delete from pool where project = ?', (project,))
        self.db.executemany('insert into pool values (?, ?, ?, ?, ?)', [
            (project, title, work['qid'], json.dumps(work['variants'], ensure_ascii=False), now)
            for title, work in works.items()])
        self.db.commit()

    def last_day(self, project, title):
        row = self.db.execute('select max(day) from views where project = ? and title = ?', (project, title)).fetchone()
        return parse_day(row[0]) if row and row[0] else None

    def add_views(self, project, title, daily):
        self.db.executemany('insert or replace into views values (?, ?, ?, ?)',
                            [(project, title, day, views) for day, views in daily.items()])
        self.db.commit()

    def views(self, project, since):
        daily = {}
        for title, day, views in self.db.execute(
                'select title, day, views from views where project = ? and day >= ?', (project, format_day(since))):
            daily.setdefault(title, {})[day] = views
        return daily

    def finished(self, qid):
        return self.db.execute('select subject, ended, checked from finished where qid = ?', (qid,)).fetchone()

    def set_finished(self, qid, subject, ended, now):
        self.db.execute('insert or replace into finished values (?, ?, ?, ?)', (qid, subject, int(ended), now))
        self.db.commit()

    def intro(self, wiki, title, variant):
        return self.db.execute('select text, refreshed from intro where wiki = ? and title = ? and variant = ?',
                               (wiki, title, variant or '')).fetchone()

    def set_intro(self, wiki, title, variant, text, now):
        self.db.execute('insert or replace into intro values (?, ?, ?, ?, ?)', (wiki, title, variant or '', text, now))
        self.db.commit()


# MARK: - The job


@dataclass
class Job:
    client: Client
    store: Store
    today: date
    limit: int = None
    asked_classics: dict = field(default_factory=dict)

    @property
    def now(self):
        return datetime.now(timezone.utc).isoformat()

    def say(self, message):
        print(message, file=sys.stderr, flush=True)

    def refresh_pool(self, name, pool):
        """The pool's works, from its categories once a week: pages whose item is a story."""
        stamp = self.store.meta(f'pool:{pool.project}')
        if stamp and datetime.fromisoformat(stamp) > datetime.now(timezone.utc) - REFRESH_POOL and self.store.pool(pool.project):
            return self.store.pool(pool.project)
        titles = category_pages(self.client, pool)
        items = page_items(self.client, pool.wiki, titles, variants=name == 'zh')
        found = entities(self.client, [item['qid'] for item in items.values()], props='claims')
        works = {title: item for title, item in items.items()
                 if keeps_work(claim_ids(found.get(item['qid'], {}), 'P31'))}
        self.say(f'pool {pool.project}: {len(titles)} pages, {len(items)} with an item, {len(works)} stories')
        self.store.replace_pool(pool.project, works, self.now)
        self.store.set_meta(f'pool:{pool.project}', self.now)
        return works

    def limited(self, works):
        """A local run's first `limit` stories. The store keeps the whole pool, so a later run
        without `--limit` on the same database sees all of it; stories, not pages, since most of
        the 華語 tree's first pages are TV series."""
        return dict(list(works.items())[:self.limit]) if self.limit else works

    def refresh_views(self, pool, titles):
        """Each work's daily views up to yesterday: a year on its first day, then the days since."""
        last = self.today - timedelta(days=1)
        for title in titles:
            known = self.store.last_day(pool.project, title)
            first = (known - timedelta(days=2)) if known else self.today - timedelta(days=FIRST_DAYS)
            if known and known >= last:
                continue
            self.store.add_views(pool.project, title, daily_views(self.client, pool.project, title, first, last))

    def popular(self, pool, titles):
        """`{window: {title: views}}` for today, month and year, ending on the last day
        Wikimedia has counted."""
        daily = self.store.views(pool.project, self.today - timedelta(days=FIRST_DAYS))
        days = [parse_day(day) for views in daily.values() for day in views]
        if not days:
            return {name: {} for name in WINDOWS}
        latest = max(days)
        return {name: {title: window_total(daily.get(title, {}), latest, span) for title in titles}
                for name, span in WINDOWS.items()}

    def refresh_finished(self, works, details, titles_for):
        """Whether each work is finished, by Bangumi, asked once a day for a work not yet known
        finished; a finished work stays so."""
        for title, work in works.items():
            qid = work['qid']
            known = self.store.finished(qid)
            if known and (known[1] or known[2][:10] == self.today.isoformat()):
                continue
            names = titles_for(title, work)
            subject = None
            for keyword in dict.fromkeys(names):
                subject = bangumi_match(bangumi_search(self.client, keyword), names, details.get(qid, {}).get('authors', []))
                if subject:
                    break
            self.store.set_finished(qid, subject['id'] if subject else None, bool(subject and bangumi_ended(subject)), self.now)

    def intros(self, wiki, titles, variant):
        """The articles' first sentences, kept a week."""
        stale = []
        for title in titles:
            known = self.store.intro(wiki, title, variant)
            if not known or datetime.fromisoformat(known[1]) < datetime.now(timezone.utc) - REFRESH_TEXT:
                stale.append(title)
        if stale:
            fetched = extracts(self.client, wiki, stale, variant)
            for title in stale:
                self.store.set_intro(wiki, title, variant, fetched.get(title, ''), self.now)
        return {title: (self.store.intro(wiki, title, variant) or ('',))[0] for title in titles}

    def classics(self, region):
        """經典名著's candidates: stories written in the region's language, by how many Wikipedias
        have them. More than a list's worth: a series' volumes are folded afterwards. 華語（繁）
        and 華語（簡） share one answer: the query is heavy (one 504 in two, measured 2026-10-21)."""
        if region.classic_languages in self.asked_classics:
            return self.asked_classics[region.classic_languages]

        def values(qids):
            return ' '.join(f'wd:{qid}' for qid in qids)
        rows = sparql(self.client, f'''SELECT DISTINCT ?item ?links WHERE {{
            VALUES ?language {{ {values(region.classic_languages)} }}
            ?item wdt:P407 ?language ; wikibase:sitelinks ?links .
            {{ VALUES ?class {{ {values(CLASSIC_CLASSES)} }} ?item wdt:P31 ?class }}
            UNION {{ VALUES ?form {{ {values(CLASSIC_FORMS)} }} ?item wdt:P7937 ?form }}
            UNION {{ VALUES ?genre {{ {values(CLASSIC_GENRES)} }} ?item wdt:P136 ?genre }}
            }} ORDER BY DESC(?links) LIMIT {LIST_LENGTH * 3}''')
        order = list(dict.fromkeys(row['item']['value'].rsplit('/', 1)[1] for row in rows))
        self.asked_classics[region.classic_languages] = order
        return order


def build_region(job, name, region, pool_works, details, finished, totals):
    """The region's lists: `{list: [work, …]}`, from each window's `totals`."""
    pool = POOLS[region.pool]
    wiki = pool.wiki
    variant_key = region.variant

    def title_of(title, work):
        return work['variants'].get(variant_key) or title if variant_key else title

    def entry(title, work, intro):
        detail = details.get(work['qid'], {})
        shown = strip_disambiguation(title_of(title, work))
        others = [strip_disambiguation(value) for value in work['variants'].values()] + detail.get('aliases', [])
        return {'title': shown, 'author': detail.get('authors', {}).get(name, [])[:5], 'intro': intro,
                'url': article_url(wiki, title, region.variant), 'aliases': [alias for alias in dict.fromkeys(others) if alias != shown],
                'wikidata': work['qid']}

    lists = {}
    for list_name in region.lists:
        if list_name in WINDOWS:
            titles = ranked(totals[list_name])
        elif list_name == 'completed':
            titles = ranked({title: total for title, total in totals['year'].items()
                             if finished.get(pool_works[title]['qid'])})
        else:
            continue
        intros = job.intros(wiki, titles, region.variant)
        lists[list_name] = [entry(title, pool_works[title], intros.get(title, '')) for title in titles]
    return lists


def author_names(job, found, regions):
    """`{qid: {'authors': {region: [name, …]}, 'aliases': […]}}` from the works' P50."""
    author_ids = {qid: work_authors(entity) for qid, entity in found.items()}
    people = entities(job.client, [author for authors in author_ids.values() for author in authors], props='labels')
    details = {}
    for qid, authors in author_ids.items():
        details[qid] = {'authors': {name: [label(people.get(author, {}).get('labels', {}), region.labels)
                                           for author in authors if people.get(author)]
                                    for name, region in regions.items()}}
        details[qid]['authors'] = {name: [value for value in values if value]
                                   for name, values in details[qid]['authors'].items()}
    for name, region in regions.items():
        if not region.variant:
            continue
        converted = convert_variant(job.client, POOLS[region.pool].wiki,
                                    [author for detail in details.values() for author in detail['authors'][name]],
                                    region.variant)
        for detail in details.values():
            detail['authors'][name] = list(dict.fromkeys(converted[author] for author in detail['authors'][name]))
    return details


def build_classics(job, name, region):
    """經典名著's works for a region: the title its Wikipedia gives (in its script), else a label."""
    candidates = job.classics(region)
    found = entities(job.client, candidates)
    order = one_per_series(candidates, found)[:LIST_LENGTH]
    details = author_names(job, found, {name: region})
    wiki_key = POOLS[region.pool].wiki.replace('.wikipedia.org', 'wiki')
    articles = {qid: found[qid].get('sitelinks', {}).get(wiki_key, {}).get('title') for qid in order if qid in found}
    linked = [title for title in articles.values() if title]
    variants = page_items(job.client, POOLS[region.pool].wiki, linked, variants=bool(region.variant)) if linked else {}
    intros = job.intros(POOLS[region.pool].wiki, linked, region.variant) if linked else {}
    # A work with no article here goes by its label, which is in its editor's script.
    labelled = {qid: label(found[qid].get('labels', {}), region.labels) for qid in order
                if qid in found and not articles.get(qid)}
    converted = convert_variant(job.client, POOLS[region.pool].wiki, labelled.values(), region.variant) \
        if region.variant and any(labelled.values()) else {}
    works = []
    for qid in order:
        entity = found.get(qid)
        if not entity:
            continue
        article = articles.get(qid)
        if article:
            shown = (variants.get(article, {}).get('variants', {}).get(region.variant) if region.variant else None) or article
        else:
            shown = converted.get(labelled.get(qid), labelled.get(qid))
        if not shown:
            continue
        shown = strip_disambiguation(shown)
        works.append({'title': shown, 'author': details.get(qid, {}).get('authors', {}).get(name, [])[:5],
                      'intro': intros.get(article, '') if article else '',
                      'url': article_url(POOLS[region.pool].wiki, article, region.variant) if article else f'https://www.wikidata.org/wiki/{qid}',
                      'aliases': [], 'wikidata': qid})
    return works


def write(output, region, list_name, works, generated):
    folder = output / region
    folder.mkdir(parents=True, exist_ok=True)
    temporary = folder / (list_name + '.json.tmp')
    temporary.write_bytes(list_document(region, list_name, works, generated))
    temporary.replace(folder / (list_name + '.json'))


def run(job, output, regions):
    """Every list of `regions`. A list whose requests failed keeps its last file and is named
    in the log; the others are written."""
    generated = datetime.now(timezone.utc).replace(microsecond=0)
    failed = []
    by_pool = {}
    for name in regions:
        by_pool.setdefault(REGIONS[name].pool, []).append(name)
    for pool_name, names in by_pool.items():
        pool = POOLS[pool_name]
        written = set()
        try:
            works = job.limited(job.refresh_pool(pool_name, pool))
            job.refresh_views(pool, list(works))
            totals = job.popular(pool, list(works))
            found = entities(job.client, [work['qid'] for work in works.values()], props='claims')
            details = author_names(job, found, {name: REGIONS[name] for name in names})
            finished = {}
            if any('completed' in REGIONS[name].lists for name in names):
                def titles_for(title, work):
                    base = strip_disambiguation(title)
                    return [strip_disambiguation(work['variants'].get('zh-cn', base)), base]
                job.refresh_finished(works, {qid: {'authors': [a for values in detail['authors'].values() for a in values]}
                                             for qid, detail in details.items()}, titles_for)
                finished = {work['qid']: bool((job.store.finished(work['qid']) or (None, 0))[1]) for work in works.values()}
            for name in names:
                for list_name, entries in build_region(job, name, REGIONS[name], works, details, finished, totals).items():
                    write(output, name, list_name, entries, generated)
                    written.add(f'{name}/{list_name}')
                    job.say(f'{name}/{list_name}: {len(entries)} works')
        except Exception as error:  # noqa: BLE001 — any failure keeps yesterday's files
            failed += [f'{name}/{list_name}' for name in names for list_name in REGIONS[name].lists
                       if list_name != 'classics' and f'{name}/{list_name}' not in written]
            job.say(f'pool {pool_name} failed, last files kept: {error!r}')
        for name in names:
            if 'classics' not in REGIONS[name].lists:
                continue
            try:
                entries = build_classics(job, name, REGIONS[name])
                write(output, name, 'classics', entries, generated)
                job.say(f'{name}/classics: {len(entries)} works')
            except Exception as error:  # noqa: BLE001
                failed.append(f'{name}/classics')
                job.say(f'{name}/classics failed, last file kept: {error!r}')
    return failed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=Path('trends.sqlite'))
    parser.add_argument('--output', type=Path, default=Path('out'))
    parser.add_argument('--region', action='append', choices=sorted(REGIONS), help='Only these regions')
    parser.add_argument('--limit', type=int, help='At most this many stories a pool (local runs); the store keeps them all')
    arguments = parser.parse_args(argv)
    # Pageviews at most 5 a second (plan, step 2): 英語's ~9 600 works take ~32 minutes a day.
    client = Client({'wikimedia.org': 0.2, 'api.bgm.tv': 1.0, 'query.wikidata.org': 1.0})
    job = Job(client, Store(arguments.db), datetime.now(timezone.utc).date(), arguments.limit)
    failed = run(job, arguments.output, arguments.region or list(REGIONS))
    if failed:
        print('failed: ' + ', '.join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
