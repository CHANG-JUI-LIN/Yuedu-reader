#!/usr/bin/env python3
"""Build 趨勢's lists from Wikipedia, Wikidata and Bangumi, once a day.

Plan: docs/superpowers/plans/2026-10-21-trends-module.md. No web-novel platform is ever asked
(maintainer, 2026-10-21): the works come from Wikipedia's categories, their popularity from
Wikipedia's pageviews, whether a web novel is finished from Bangumi (and 小説家になろう's
API), whether an English novel is from its Wikipedia infobox, and the classics from Wikidata.
A series' books are one entry, under its first book (maintainer, 2026-10-22). Each list is
written as <output>/<region>/<list>.json, for the official module 趨勢.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import html
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sqlite3
import sys
import threading
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

USER_AGENT = 'Yuedu-trends/1 (+https://yuedureader.com/support)'
ATTRIBUTION = '資料：維基百科、維基數據（CC BY-SA 4.0）、Bangumi'
LICENSE = 'https://creativecommons.org/licenses/by-sa/4.0/'
SCHEMA_VERSION = 1
LIST_LENGTH = 50
# A series' entry carries its other books' covers for 作品詳情's fan, two a side (app, 2026-10-26).
SERIES_COVERS = 4
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
# 華語's and 日本's articles are each a whole series (346 of 日本's 381 works are a light novel
# series, and no work of either pool has a P179, measured 2026-10-27), so none folds: the fan's
# volumes are the matched Bangumi subject's 单行本 (maintainer, 2026-10-27), read once a week.
REFRESH_VOLUMES = timedelta(days=7)
FIRST_DAYS = 366
WINDOWS = {'today': 1, 'month': 30, 'year': 365}
# 英語's 完結推薦 reads the infoboxes of the year's most viewed entries, enough of them to fill a
# list: about half are a book alone, finished; a series says so or not (measured 2026-10-22).
INFOBOX_CANDIDATES = LIST_LENGTH * 4
# Wikimedia's limit for a bot whose User-Agent names it: 200 requests a minute, one budget across
# every Wikimedia site and API (Action and REST alike), at most 3 requests at once
# (mediawiki.org, Wikimedia APIs/Rate limits, read 2026-10-22). 5 a second with 8 at once was
# answered 429 after four minutes (2026-10-22). One request every 0.35 s is 171 a minute.
WIKIMEDIA_INTERVAL = 0.35
# Pageview requests in flight at once, together no faster than WIKIMEDIA_INTERVAL: one at a time,
# each waits on its answer (0.81 s from the host), so 英語's 9 604 works took 2 h 10 min.
VIEW_WORKERS = 3
# A request is asked again once (maintainer, 2026-10-22) when it went unanswered for 120 s (one in
# ~13 000 pageview requests from this Mac on 2026-10-22), or was answered 429 or 503, which
# Wikimedia's rate-limit page says to retry after Retry-After, else after 5 s. A day asks ~24 000
# requests and one failure keeps a region's lists at yesterday's. A wait longer than
# MAX_RETRY_WAIT is not waited for. Delete when a month of runs never logs a retry.
RETRY_STATUSES = (429, 503)
MAX_RETRY_WAIT = 300


@dataclass(frozen=True)
class Pool:
    """The works one Wikipedia holds for a region: its categories, walked `depth` levels, what
    tells which ended: Bangumi, the 小説家になろう pages its articles link (whose API says),
    or the articles' infoboxes; and whether its articles' page images are book covers."""
    wiki: str
    categories: tuple
    depth: int
    finished_by: tuple = ('bangumi',)
    article_covers: bool = True

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
    """Every year's novels: the year categories begin at 1890 (checked 2026-10-22), and Harry
    Potter's first three books, A Game of Thrones and The Eye of the World are before 2000."""
    return tuple(f'Category:{year} English-language novels' for year in range(1890, today.year + 1))


POOLS = {
    'zh': Pool('zh.wikipedia.org', ('Category:中华人民共和国网络小说',), 4),
    # ja.wikipedia keeps no non-free file, so no cover: its listed works' page images are title
    # logos, anime stills and photos (46 of 151, measured on the host 2026-10-22; はたらく魔王さま!
    # is a Shibuya street, 吾輩は猫である a cat).
    'ja': Pool('ja.wikipedia.org', ('Category:小説家になろうの小説', 'Category:カクヨムの小説'), 2, ('bangumi', 'narou'),
               article_covers=False),
    # Not Bangumi: English novels are not there, and 9 604 searches a day would take 2.7 hours.
    'en': Pool('en.wikipedia.org', english_categories(date.today()), 1, ('infobox',)),
}
REGIONS = {
    'zh-Hant': Region('zh', 'zh-tw', CHINESE_LABELS, CHINESE),
    'zh-Hans': Region('zh', 'zh-cn', CHINESE_LABELS, CHINESE),
    'ja': Region('ja', None, ('ja',), JAPANESE),
    'en': Region('en', None, ('en',), ENGLISH),
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
    """A Wikidata `labels` value in the first of `languages` it has, then `mul`: since 2024 a name
    written the same in every language is kept only there (Rudyard Kipling, Salman Rushdie and
    the Harry Potter series have no `en` label, checked 2026-10-22)."""
    for language in (*languages, 'mul'):
        value = labels.get(language, {}).get('value')
        if value:
            return value
    return None


def ranked(totals, limit=LIST_LENGTH):
    """Keys by their total, most first, ties by key; nothing without views."""
    return [key for key, total in sorted(totals.items(), key=lambda pair: (-pair[1], pair[0])) if total > 0][:limit]


def parse_day(text):
    return datetime.strptime(text[:8], '%Y%m%d').date()


def format_day(day):
    return day.strftime('%Y%m%d')


_INFOBOX = re.compile(r'\{\{\s*infobox\b', re.IGNORECASE)


def infoboxes(wikitext):
    """An article's infoboxes in order: `(kind, {param: value})`, the kind lowercased (`book`,
    `book series`, `animanga/novel`), each value as written. ja.wikipedia's light novels have
    several: Header, Novel, Manga."""
    text = re.sub(r'<!--.*?-->', '', wikitext, flags=re.S)
    boxes, index = [], 0
    while start := _INFOBOX.search(text, index):
        box, index = _template(text, start.start())
        boxes.append(box)
    return boxes


def infobox(wikitext):
    """An article's first infobox; None for an article with none."""
    boxes = infoboxes(wikitext)
    return boxes[0] if boxes else None


def _template(text, index):
    """The template opening at `index` as `(kind, params)`, and where it ends."""
    parts, current, depth, links = [], [], 0, 0
    while index < len(text):
        pair = text[index:index + 2]
        if pair in ('{{', '}}', '[[', ']]'):
            depth += {'{{': 1, '}}': -1}.get(pair, 0)
            links += {'[[': 1, ']]': -1}.get(pair, 0)
            index += 2
            if depth == 0:
                break
            current.append(pair)
            continue
        if text[index] == '|' and depth == 1 and links == 0:
            parts.append(''.join(current))
            current = []
        else:
            current.append(text[index])
        index += 1
    parts.append(''.join(current))
    kind = re.sub(r'^\{\{\s*infobox\s*', '', parts[0], flags=re.IGNORECASE).strip().lower()
    params = {}
    for part in parts[1:]:
        name, equals, value = part.partition('=')
        if equals:
            params[name.strip().lower()] = value.strip()
    return (kind, params), index


SERIES_DATES = ('pub_date', 'published', 'first_pub', 'release_date')


def series_ended(params):
    """A series infobox's run: True when its dates end in a year, False when they run to the
    present or a book is still to come, None when it gives no dates (The Hunger Games lists its
    books instead)."""
    dates = ' '.join(params.get(name, '') for name in SERIES_DATES)
    if re.search(r'\b(present|ongoing|planned|forthcoming|upcoming)\b', f"{dates} {params.get('books', '')}",
                 re.IGNORECASE):
        return False
    dates = re.sub(r'<ref[^>]*/>|<ref[^>]*>.*?</ref>', '', dates, flags=re.S | re.IGNORECASE)
    ends = re.split(r'\s*[–—]\s*|\s+-\s+|(?<=\d)-(?=\d{4}\b)', dates)
    if len(ends) >= 2 and re.search(r'\b\d{4}\b', ends[0]) and re.search(r'\b\d{4}\b', ends[-1]):
        return True
    return None


def series_link(value):
    """The article a `series` value links; None when it names the series without a link."""
    match = re.search(r'\[\[([^\]|#]+)', value)
    return match[1].strip() if match else None


def infobox_finished(article, page):
    """英語's 完結 (maintainer, 2026-10-22): a book outside any series is finished, and a book of
    a series is when the series' infobox says it ended. True, False, or None when the infoboxes
    cannot tell (no infobox, a series named without a link, a series giving no dates).
    `page(title)` reads a linked article; a series' own article, or a character's linking the
    series (Jack Reacher), is followed at most twice."""
    box = infobox(article)
    for _ in range(3):
        if box is None:
            return None
        kind, params = box
        if re.search(r'\b(book|novel|literary) series\b', kind):
            return series_ended(params)
        series = params.get('series', '')
        if not series:
            return True if kind in ('book', 'novel') else None
        target = series_link(series)
        if not target:
            return None
        box = infobox(page(target))
    return None


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


def bangumi_cover(subject):
    """A Bangumi subject's own cover, as its search answer gives it; empty there when it has none."""
    return (subject.get('images') or {}).get('common') or None


def bangumi_volumes(related):
    """A series subject's volumes' covers, from its related subjects: each 单行本 with a cover, in
    the order Bangumi's editors keep them, the series' own (はたらく魔王さま!'s (0) and 0-II before
    its (1); 11 of the 81 listed series are not in id order, measured 2026-10-27)."""
    return [cover for item in related if item.get('relation') == '单行本' and (cover := bangumi_cover(item))]


def narou_pick(title, codes, novels):
    """The なろう work an article is about, among the `codes` it links (`novels`: what the API
    knows of them). One known code is the work; of several (Re:Monster links its 設定集 too),
    the one whose title holds the article's. None when the API knows none, as for a work
    taken down (JKハル).
    """
    known = [code for code in codes if code in novels]
    if len(known) == 1:
        return known[0]
    wanted = normalize_title(strip_disambiguation(title))
    for code in known:
        if wanted and wanted in normalize_title(novels[code]['title']):
            return code
    return None


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


# A work's authors as its article's book infobox names them: ja's Infobox animanga/Novel as 著者
# (its Manga box's 作者 adds the artist, as 片田舎のおっさん、剣聖になる's does), zh's and en's
# Infobox book as `author` or `作者`.
AUTHOR_PARAMS = ('author', 'authors', '著者', '作者')
_BOOK_BOX = re.compile(r'^(animanga/)?(book|novel)\b|\b(book|novel|literary) series\b')


def infobox_authors(wikitext):
    """The names the article's first book infobox gives as its authors; [] for none."""
    for kind, params in infoboxes(wikitext):
        if _BOOK_BOX.search(kind):
            return plain_names(next((params[name] for name in AUTHOR_PARAMS if params.get(name)), ''))
    return []


def plain_names(value):
    """A value's names as text: `[[忘語|忘语]]` → 忘语, `{{nowrap|X}}` → X, one name to a line,
    `<br />`, 、, comma or `and`; refs and a trailing note (`國王陛下（小說）`) left out."""
    text = re.sub(r'<ref[^>]*/>|<ref[^>]*>.*?</ref>', '', value, flags=re.S | re.IGNORECASE)
    text = re.sub(r'\[\[(?:[^\]|]*\|)?([^\]|]*)\]\]', r'\1', text)
    while True:
        unwrapped = re.sub(r'\{\{[^{}|]*\|([^{}|]*)[^{}]*\}\}|\{\{[^{}]*\}\}', r'\1', text)
        if unwrapped == text:
            break
        text = unwrapped
    text = re.sub(r"'{2,}", '', text)
    names = (strip_disambiguation(part.strip(' *\t')) for part in
             re.split(r'<br\s*/?>|\n|[、，,;；]|\band\b', text, flags=re.IGNORECASE))
    return [name for name in names if name][:5]


def first_published(entity):
    """A work's earliest publication date (P577) as Wikidata writes it, `2006-07-17T00:00:00Z`."""
    times = [claim['mainsnak']['datavalue']['value'].get('time', '')
             for claim in entity.get('claims', {}).get('P577', []) if 'datavalue' in claim.get('mainsnak', {})]
    times = [value[1:] for value in times if value.startswith('+')]
    return min(times) if times else None


def series_groups(works):
    """`{head: (series, titles)}` for each series a list shows once (maintainer, 2026-10-22): one
    with two or more books in the pool, their views summed with those of the series' own
    article when it is in the pool too, under its first book — the earliest published, as
    Mistborn: The Final Empire; a prequel comes out later, and Wikidata gives no volume number
    for 6 of the 22 series on 英語's year list. A book alone in the pool keeps its own entry."""
    members = {}
    for title, work in works.items():
        members.setdefault(work.get('series') or work['qid'], []).append(title)
    groups = {}
    for series, titles in members.items():
        books = [title for title in titles if works[title]['qid'] != series]
        if len(books) < 2:
            continue
        head = min(books, key=lambda title: (works[title].get('published') or '~', title))
        groups[head] = (series, titles)
    return groups


def series_volumes(head, groups, works):
    """The other books of the series `head` stands for, in the order they came out (as
    `series_groups` picks the head); the series' own article is no book."""
    series, titles = groups[head]
    books = [title for title in titles if title != head and works[title]['qid'] != series]
    return sorted(books, key=lambda title: (works[title].get('published') or '~', title))


def folded(totals, groups):
    """Each window's views with a series' summed under its head."""
    under = {title: head for head, (_, titles) in groups.items() for title in titles}
    result = {}
    for window, views in totals.items():
        summed = {}
        for title, count in views.items():
            summed[under.get(title, title)] = summed.get(under.get(title, title), 0) + count
        result[window] = summed
    return result


def shown_entries(totals, done):
    """The entries some list shows: each window's most viewed, and the year's finished ones."""
    shown = {title for window in totals.values() for title in ranked(window)}
    return shown | set(ranked({title: total for title, total in totals['year'].items() if title in done}))


def ended_entries(entries, groups, works, finished, by_series):
    """Which `entries` (titles, a series' by its head) are finished. A book alone goes by its own
    answer; a series by the series' own (`by_series`: 英語's infoboxes, whose series article says
    whether it ended), else when every book of it has ended (Bangumi and なろう answer for books)."""
    done = set()
    for title in entries:
        if title not in groups:
            ended = finished.get(works[title]['qid'], False)
        elif by_series:
            ended = finished.get(groups[title][0], False)
        else:
            series, titles = groups[title]
            ended = all(finished.get(works[other]['qid'], False) for other in titles if works[other]['qid'] != series)
        if ended:
            done.add(title)
    return done


# MARK: - Requests


def retry_wait(error):
    """The seconds to wait before asking again once (RETRY_STATUSES), or None for no retry."""
    if isinstance(error, HTTPError):
        if error.code not in RETRY_STATUSES:
            return None
        after = (error.headers or {}).get('Retry-After') or ''
        wait = max(int(after), 5) if after.strip().isdigit() else 5
        return wait if wait <= MAX_RETRY_WAIT else None
    if isinstance(error, TimeoutError) or isinstance(getattr(error, 'reason', None), TimeoutError):
        return 5
    return None


def budget(host):
    """The budget a request to `host` takes its turn in: Wikimedia's sites and APIs share one, the
    query service (its limits are its own: queries' running time) and every other host their own."""
    if host != 'query.wikidata.org' and (host == 'wikimedia.org' or host.endswith(('.wikipedia.org', '.wikidata.org'))):
        return 'wikimedia'
    return host


class Client:
    """JSON over HTTPS as this app, each budget (`budget`) no faster than its interval, from any
    number of threads: each request takes its budget's next turn, an interval after the last one."""

    def __init__(self, intervals):
        self.intervals = intervals
        self.last = {}
        self.lock = threading.Lock()

    def _pace(self, host):
        key = budget(host)
        interval = self.intervals.get(key, 0.1)
        with self.lock:
            turn = max(time.monotonic(), self.last.get(key, 0) + interval)
            self.last[key] = turn
        wait = turn - time.monotonic()
        if wait > 0:
            time.sleep(wait)

    def json(self, url, params=None, body=None, headers=None):
        try:
            return self._json(url, params, body, headers)
        except (URLError, TimeoutError) as error:
            wait = retry_wait(error)
            if wait is None:
                raise
            print(f'retrying in {wait} s, once: {url} ({error!r})', file=sys.stderr, flush=True)
            time.sleep(wait)
            return self._json(url, params, body, headers)

    def _json(self, url, params, body, headers):
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


def entities(client, qids, props='claims|labels|sitelinks', keep=None, site=None):
    """Wikidata items, 50 a request, holding only the claims in `keep` when given: a novel's
    whole claims take ~38 KB in memory, 英語's 9 800 works ~370 MB (measured 2026-10-22), on a
    host with 1.3 GB free. `site` (`enwiki`) keeps the one article link asked for."""
    found = {}
    qids = sorted(set(qids))
    for start in range(0, len(qids), 50):
        params = {'action': 'wbgetentities', 'ids': '|'.join(qids[start:start + 50]), 'props': props, 'format': 'json'}
        if site:
            params['sitefilter'] = site
        answer = client.json('https://www.wikidata.org/w/api.php', params)
        for qid, entity in answer.get('entities', {}).items():
            if keep is not None and 'claims' in entity:
                entity = {**entity, 'claims': {prop: entity['claims'][prop] for prop in keep if prop in entity['claims']}}
            found[qid] = entity
    return found


def claim_strings(entity, prop):
    return [value for claim in entity.get('claims', {}).get(prop, [])
            if isinstance(value := claim.get('mainsnak', {}).get('datavalue', {}).get('value'), str)]


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


def page_images(client, wiki, titles):
    """`{title: url}`: each article's page image, which for a novel is its infobox's cover, 50 at
    a time. Non-free ones too: en and zh Wikipedia keep book covers as such. A cover stands
    taller than it is wide; a wider image is a photo, a still or a logo, and an SVG a logo or a
    diagram (measured on the host 2026-10-22: 英語 117 of 120 page images stand, 華語 35 of 46,
    the rest a café, a TV still, an open old book). The address is kept without Wikipedia's
    tracking query."""
    found = {}
    for start in range(0, len(titles), 50):
        answer = mediawiki(client, wiki, action='query', prop='pageimages', piprop='thumbnail|name', pithumbsize='400',
                           pilimit='50', pilicense='any', redirects='1', titles='|'.join(titles[start:start + 50]))['query']
        asked = {}
        for key in ('normalized', 'redirects'):
            for item in answer.get(key, []):
                asked[item['to']] = asked.get(item['from'], item['from'])
        for page in answer.get('pages', []):
            thumbnail = page.get('thumbnail') or {}
            if thumbnail.get('source') and thumbnail.get('height', 0) > thumbnail.get('width', 0) \
                    and not page.get('pageimage', '').lower().endswith('.svg'):
                found[asked.get(page['title'], page['title'])] = thumbnail['source'].split('?')[0]
    return found


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


def lead_wikitext(client, wiki, title):
    """An article's lead section as written; '' for a link to an article that is not there."""
    answer = mediawiki(client, wiki, action='parse', page=title, prop='wikitext', section='0', redirects='1')
    if 'error' in answer:
        if answer['error'].get('code') in ('missingtitle', 'invalidtitle'):
            return ''
        raise RuntimeError(f"{wiki} parse {title!r}: {answer['error']}")
    return answer['parse']['wikitext']


def sparql(client, query):
    answer = client.json('https://query.wikidata.org/sparql', {'query': query},
                         headers={'Accept': 'application/sparql-results+json'})
    return answer['results']['bindings']


def narou_codes(client, wiki, titles):
    """`{title: [ncode, …]}`: the 小説家になろう works each article links, 20 articles a request."""
    found = {}
    for start in range(0, len(titles), 20):
        cont = {}
        while True:
            answer = mediawiki(client, wiki, action='query', titles='|'.join(titles[start:start + 20]),
                               prop='extlinks', ellimit='max', elquery='ncode.syosetu.com', elprotocol='', **cont)
            for page in answer['query']['pages']:
                for link in page.get('extlinks', []):
                    match = re.search(r'ncode\.syosetu\.com/(n\w+)', link['url'], re.IGNORECASE)
                    if match and match[1].lower() not in found.setdefault(page['title'], []):
                        found[page['title']].append(match[1].lower())
            if 'continue' not in answer:
                break
            cont = answer['continue']
    return {title: codes for title, codes in found.items() if codes}


def narou_novels(client, codes):
    """`{ncode: {'title': …, 'end': …}}` from 小説家になろう's API, 100 codes a request; `end` 0
    is a finished serial or a short story, 1 still running. A code the API leaves out has been
    taken down."""
    found = {}
    for start in range(0, len(codes), 100):
        answer = client.json('https://api.syosetu.com/novelapi/api/', {
            'out': 'json', 'of': 'n-t-e', 'lim': '500', 'ncode': '-'.join(codes[start:start + 100])})
        for novel in answer[1:]:
            found[novel['ncode'].lower()] = {'title': novel['title'], 'end': novel['end']}
    return found


def bangumi_search(client, keyword):
    answer = client.json('https://api.bgm.tv/v0/search/subjects?limit=5',
                         body={'keyword': keyword, 'filter': {'type': [1]}})
    return answer.get('data') or []


def bangumi_related(client, subject):
    """A Bangumi subject's related subjects. Bangumi answers 404 for a subject it has since
    removed (`resource can't be found in the database or has been removed`): none."""
    try:
        return client.json(f'https://api.bgm.tv/v0/subjects/{subject}/subjects')
    except HTTPError as error:
        if error.code == 404:
            return []
        raise


# MARK: - The store


SCHEMA = '''
create table if not exists pool (project text, title text, qid text, variants text, refreshed text,
                                 series text, published text, primary key (project, title));
create table if not exists views (project text, title text, day text, views integer,
                                  primary key (project, title, day)) without rowid;
create table if not exists finished (qid text primary key, subject integer, ended integer, checked text, cover text);
create table if not exists intro (wiki text, title text, variant text, text text, refreshed text,
                                  primary key (wiki, title, variant));
create table if not exists meta (key text primary key, value text);
create table if not exists volumes (subject integer primary key, covers text, checked text);
'''


class Store:
    """What the job keeps between days on the host: the pools, their views, Bangumi's answers."""

    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.executescript(SCHEMA)
        if 'series' not in {row[1] for row in self.db.execute('pragma table_info(pool)')}:
            # A store from before series were folded (2026-10-22): the pools are read again, with them.
            self.db.executescript('alter table pool add column series text; '
                                  'alter table pool add column published text; '
                                  "delete from meta where key like 'pool:%';")
        if 'cover' not in {row[1] for row in self.db.execute('pragma table_info(finished)')}:
            # A store from before covers (2026-10-22): the works matched on Bangumi are asked again, for it.
            self.db.executescript('alter table finished add column cover text; '
                                  'delete from finished where subject is not null;')

    def meta(self, key):
        row = self.db.execute('select value from meta where key = ?', (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute('insert or replace into meta values (?, ?)', (key, value))
        self.db.commit()

    def pool(self, project):
        rows = self.db.execute('select title, qid, variants, series, published from pool where project = ?', (project,))
        return {title: {'qid': qid, 'variants': json.loads(variants or '{}'), 'series': series, 'published': published}
                for title, qid, variants, series, published in rows}

    def replace_pool(self, project, works, now):
        self.db.execute('delete from pool where project = ?', (project,))
        self.db.executemany('insert into pool (project, title, qid, variants, refreshed, series, published) '
                            'values (?, ?, ?, ?, ?, ?, ?)', [
                                (project, title, work['qid'], json.dumps(work['variants'], ensure_ascii=False), now,
                                 work.get('series'), work.get('published'))
                                for title, work in works.items()])
        self.db.commit()

    def last_day(self, project, title):
        row = self.db.execute('select max(day) from views where project = ? and title = ?', (project, title)).fetchone()
        return parse_day(row[0]) if row and row[0] else None

    def add_views(self, project, title, daily):
        self.db.executemany('insert or replace into views values (?, ?, ?, ?)',
                            [(project, title, day, views) for day, views in daily.items()])
        self.db.commit()

    def window_totals(self, project, spans):
        """`(latest day, {title: (views over each of spans, …)})`: each span the days that end on
        the last day counted, summed here — 英語's year of daily views held in Python took 531 MB
        and 40 s (9 604 works, measured 2026-10-22), more than the host can spare."""
        row = self.db.execute('select max(day) from views where project = ?', (project,)).fetchone()
        if not row or not row[0]:
            return None, {}
        latest = parse_day(row[0])
        firsts = [format_day(latest - timedelta(days=span - 1)) for span in spans]
        columns = ', '.join('sum(case when day >= ? then views else 0 end)' for _ in spans)
        rows = self.db.execute(f'select title, {columns} from views where project = ? and day >= ? group by title',
                               (*firsts, project, min(firsts)))
        return latest, {title: tuple(sums) for title, *sums in rows}

    def forget_views(self, before):
        """Days no window reaches any more."""
        self.db.execute('delete from views where day < ?', (format_day(before),))
        self.db.commit()

    def finished(self, qid):
        return self.db.execute('select subject, ended, checked from finished where qid = ?', (qid,)).fetchone()

    def set_finished(self, qid, subject, ended, now, cover=None):
        self.db.execute('insert or replace into finished values (?, ?, ?, ?, ?)', (qid, subject, int(ended), now, cover))
        self.db.commit()

    def bangumi_cover(self, qid):
        row = self.db.execute('select cover from finished where qid = ?', (qid,)).fetchone()
        return row[0] if row else None

    def volumes(self, subject):
        row = self.db.execute('select covers, checked from volumes where subject = ?', (subject,)).fetchone()
        return (json.loads(row[0]), row[1]) if row else None

    def set_volumes(self, subject, covers, now):
        self.db.execute('insert or replace into volumes values (?, ?, ?)', (subject, json.dumps(covers), now))
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
    leads: dict = field(default_factory=dict)
    images: dict = field(default_factory=dict)

    @property
    def now(self):
        return datetime.now(timezone.utc).isoformat()

    def say(self, message):
        print(message, file=sys.stderr, flush=True)

    def lead(self, wiki, title):
        """An article's lead section, read once a run: a series' article is read for each of its
        books, a work's for its authors and whether it ended."""
        if (wiki, title) not in self.leads:
            self.leads[wiki, title] = lead_wikitext(self.client, wiki, title)
        return self.leads[wiki, title]

    def covers(self, pool, articles):
        """`{qid: cover}` for `articles` (`{qid: article title or None}`): the work's own book
        cover on Bangumi where it was matched there and has one (華語, 日本), else its article's
        page image where the pool's are covers. A page image is asked once a run: 華語's two
        scripts share it."""
        wiki = pool.wiki
        asked = [title for title in dict.fromkeys(articles.values())
                 if title and pool.article_covers and (wiki, title) not in self.images]
        found = page_images(self.client, wiki, asked) if asked else {}
        self.images.update({(wiki, title): found.get(title) for title in asked})
        covers = {}
        for qid, title in articles.items():
            cover = self.store.bangumi_cover(qid) or self.images.get((wiki, title))
            if cover:
                covers[qid] = cover
        return covers

    def refresh_pool(self, name, pool):
        """The pool's works, from its categories once a week: pages whose item is a story, each
        with its series and when it was first published."""
        stamp = self.store.meta(f'pool:{pool.project}')
        if stamp and datetime.fromisoformat(stamp) > datetime.now(timezone.utc) - REFRESH_POOL and self.store.pool(pool.project):
            return self.store.pool(pool.project)
        titles = category_pages(self.client, pool)
        items = page_items(self.client, pool.wiki, titles, variants=name == 'zh')
        found = entities(self.client, [item['qid'] for item in items.values()], props='claims', keep=('P31', 'P179', 'P577'))
        works = {title: {**item, 'series': (claim_ids(found.get(item['qid'], {}), 'P179') or [None])[0],
                         'published': first_published(found.get(item['qid'], {}))}
                 for title, item in items.items() if keeps_work(claim_ids(found.get(item['qid'], {}), 'P31'))}
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
        """Each work's daily views up to yesterday: a year on its first day, then the days since,
        `VIEW_WORKERS` asked at once. A failed request stops the rest: the pool keeps its files."""
        last = self.today - timedelta(days=1)
        due = []
        for title in titles:
            known = self.store.last_day(pool.project, title)
            if not (known and known >= last):
                due.append((title, (known - timedelta(days=2)) if known else self.today - timedelta(days=FIRST_DAYS)))
        workers = ThreadPoolExecutor(VIEW_WORKERS)
        try:
            answers = workers.map(lambda item: daily_views(self.client, pool.project, item[0], item[1], last), due)
            for (title, _), daily in zip(due, answers):
                self.store.add_views(pool.project, title, daily)
        finally:
            workers.shutdown(cancel_futures=True)

    def popular(self, pool, titles):
        """`{window: {title: views}}` for today, month and year, ending on the last day
        Wikimedia has counted."""
        self.store.forget_views(self.today - timedelta(days=FIRST_DAYS))
        latest, sums = self.store.window_totals(pool.project, list(WINDOWS.values()))
        if not latest:
            return {name: {} for name in WINDOWS}
        empty = (0,) * len(WINDOWS)
        return {name: {title: sums.get(title, empty)[index] for title in titles}
                for index, name in enumerate(WINDOWS)}

    def refresh_finished(self, works, details, titles_for):
        """Bangumi's answer for each work — whether it is finished, its cover — asked once a day
        for a work not yet known finished; a finished work stays so."""
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
            self.store.set_finished(qid, subject['id'] if subject else None, bool(subject and bangumi_ended(subject)), self.now,
                                    bangumi_cover(subject) if subject else None)

    def volume_covers(self, qids):
        """`{qid: [cover, …]}` for works that are a whole series and were matched on Bangumi: its
        volumes' covers after the first, which the work's own cover stands for. Each subject's
        volumes are asked once a week."""
        covers, asked = {}, 0
        for qid in qids:
            subject = (self.store.finished(qid) or (None,))[0]
            if not subject:
                continue
            known = self.store.volumes(subject)
            if not known or datetime.fromisoformat(known[1]) < datetime.now(timezone.utc) - REFRESH_VOLUMES:
                self.store.set_volumes(subject, bangumi_volumes(bangumi_related(self.client, subject)), self.now)
                asked += 1
            later = self.store.volumes(subject)[0][1:]
            if later:
                covers[qid] = later
        self.say(f'volumes: {len(qids)} entries, {asked} subjects asked, {len(covers)} with other volumes')
        return covers

    def narou_finished(self, pool, works):
        """`{qid: finished}` for the works whose article links their 小説家になろう page, asked
        every day (one request for the pool)."""
        codes = narou_codes(self.client, pool.wiki, list(works))
        novels = narou_novels(self.client, sorted({code for linked in codes.values() for code in linked}))
        finished = {}
        for title, linked in codes.items():
            code = narou_pick(title, linked, novels)
            if code:
                finished[works[title]['qid']] = novels[code]['end'] == 0
        self.say(f'なろう: {len(codes)} of {len(works)} articles link a work, {len(finished)} known, '
                 f'{sum(finished.values())} finished')
        return finished

    def infobox_finished(self, pool, articles):
        """`{key: finished}` for the `articles` (`{key: title}`, a book's or a series' own) their
        infoboxes can tell, asked every day."""
        finished = {}
        for key, title in articles.items():
            ended = infobox_finished(self.lead(pool.wiki, title), lambda linked: self.lead(pool.wiki, linked))
            if ended is not None:
                finished[key] = ended
        self.say(f'infobox: {len(articles)} articles, {len(finished)} known, {sum(finished.values())} finished, '
                 f'{len(self.leads)} pages read')
        return finished

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


def build_region(job, name, region, pool_works, details, done, totals, groups, series_names, volumes):
    """The region's lists: `{list: [work, …]}`, from each window's `totals`, where a series is
    one entry under its head (`groups`), and `done` the entries finished. A work that is a whole
    series (`volumes`: `{qid: its other volumes' covers}`) fans them and names no series: its
    title is the series'."""
    pool = POOLS[region.pool]
    wiki = pool.wiki
    variant_key = region.variant

    def title_of(title, work):
        return work['variants'].get(variant_key) or title if variant_key else title

    def entry(title, work, intro, covers):
        detail = details.get(work['qid'], {})
        shown = strip_disambiguation(title_of(title, work))
        others = [strip_disambiguation(value) for value in work['variants'].values()] + detail.get('aliases', [])
        listed = {'title': shown, 'author': detail.get('authors', {}).get(name, [])[:5], 'intro': intro,
                  'url': article_url(wiki, title, region.variant), 'aliases': [alias for alias in dict.fromkeys(others) if alias != shown],
                  'wikidata': work['qid']}
        series = series_names.get(groups[title][0], {}).get(name) if title in groups else None
        if series:
            listed['series'] = series
            others = [covers[pool_works[other]['qid']] for other in series_volumes(title, groups, pool_works)
                      if pool_works[other]['qid'] in covers]
            if others:
                listed['seriesCovers'] = others[:SERIES_COVERS]
        elif work['qid'] in volumes:
            listed['seriesCovers'] = volumes[work['qid']][:SERIES_COVERS]
        if work['qid'] in covers:
            listed['cover'] = covers[work['qid']]
        return listed

    lists = {}
    for list_name in region.lists:
        if list_name in WINDOWS:
            titles = ranked(totals[list_name])
        elif list_name == 'completed':
            titles = ranked({title: total for title, total in totals['year'].items() if title in done})
        else:
            continue
        intros = job.intros(wiki, titles, region.variant)
        books = titles + [other for title in titles if title in groups for other in series_volumes(title, groups, pool_works)]
        covers = job.covers(pool, {pool_works[title]['qid']: title for title in books})
        lists[list_name] = [entry(title, pool_works[title], intros.get(title, ''), covers) for title in titles]
    return lists


def in_scripts(job, wiki, names, regions):
    """`{region: {name: name in its script}}`: as written for a region without a variant."""
    converted = {}
    for region_name, region in regions.items():
        if region.variant:
            converted[region_name] = convert_variant(job.client, wiki, names, region.variant) if any(names) else {}
        else:
            converted[region_name] = {name: name for name in names}
    return converted


def author_names(job, found, regions, wiki, articles):
    """`{qid: {'authors': {region: [name, …]}}}`: a work's people from Wikidata (P170, P50).
    For a work Wikidata names no one for (異世界のんびり農家, 新宋, 2026-10-22), its author
    name strings (P2093), else the names its article's book infobox gives (`articles`: `{qid:
    title}` on `wiki`), so the card is not left without one; when Wikidata has the people, these
    are never read."""
    author_ids = {qid: work_authors(entity) for qid, entity in found.items()}
    people = entities(job.client, [author for authors in author_ids.values() for author in authors], props='labels')
    written = {}
    for qid, entity in found.items():
        if not author_ids[qid]:
            written[qid] = claim_strings(entity, 'P2093') or \
                (infobox_authors(job.lead(wiki, articles[qid])) if articles.get(qid) else [])
    details = {}
    for qid, authors in author_ids.items():
        details[qid] = {'authors': {name: [value for value in
                                           ([label(people.get(author, {}).get('labels', {}), region.labels)
                                             for author in authors if people.get(author)] or written.get(qid, []))
                                           if value]
                                    for name, region in regions.items()}}
    converted = in_scripts(job, wiki, sorted({author for detail in details.values()
                                              for values in detail['authors'].values() for author in values}), regions)
    for detail in details.values():
        detail['authors'] = {name: list(dict.fromkeys(converted[name][author] for author in values))
                             for name, values in detail['authors'].items()}
    return details


def series_titles(job, found, wiki, regions):
    """`{series: {region: name}}`: the series' article title without its qualifier (Jack Reacher
    (novel series) → Jack Reacher), else its label, in each region's script."""
    key = wiki.replace('.wikipedia.org', 'wiki')
    languages = next(iter(regions.values())).labels
    raw = {}
    for qid, entity in found.items():
        article = entity.get('sitelinks', {}).get(key, {}).get('title')
        raw[qid] = strip_disambiguation(article) if article else label(entity.get('labels', {}), languages)
    converted = in_scripts(job, wiki, sorted({name for name in raw.values() if name}), regions)
    return {qid: {region: converted[region][name] for region in regions} for qid, name in raw.items() if name}


def classic_names(article, variants, label):
    """The names a classic is searched by on Bangumi, which writes Chinese in simplified script:
    its article's zh-cn title, its article, else its label."""
    names = [variants.get(article, {}).get('variants', {}).get('zh-cn') if article else None, article, label]
    return list(dict.fromkeys(strip_disambiguation(name) for name in names if name))


def build_classics(job, name, region):
    """經典名著's works for a region: the title its Wikipedia gives (in its script), else a label."""
    candidates = job.classics(region)
    found = entities(job.client, candidates, keep=('P179', 'P170', 'P50', 'P2093'))
    order = one_per_series(candidates, found)[:LIST_LENGTH]
    wiki_key = POOLS[region.pool].wiki.replace('.wikipedia.org', 'wiki')
    articles = {qid: found[qid].get('sitelinks', {}).get(wiki_key, {}).get('title') for qid in order if qid in found}
    details = author_names(job, {qid: found[qid] for qid in order if qid in found}, {name: region},
                           POOLS[region.pool].wiki, articles)
    linked = [title for title in articles.values() if title]
    variants = page_items(job.client, POOLS[region.pool].wiki, linked, variants=bool(region.variant)) if linked else {}
    intros = job.intros(POOLS[region.pool].wiki, linked, region.variant) if linked else {}
    # A work with no article here goes by its label, which is in its editor's script.
    labelled = {qid: label(found[qid].get('labels', {}), region.labels) for qid in order
                if qid in found and not articles.get(qid)}
    converted = convert_variant(job.client, POOLS[region.pool].wiki, labelled.values(), region.variant) \
        if region.variant and any(labelled.values()) else {}
    if 'bangumi' in POOLS[region.pool].finished_by:
        # Asked of Bangumi too, for their covers: ja.wikipedia keeps none, and Bangumi has 39 of
        # 日本's 50 classics and 9 more of 華語's (measured on the host, 2026-10-22).
        job.refresh_finished({qid: {'qid': qid} for qid in order if qid in found},
                             {qid: {'authors': [a for values in detail['authors'].values() for a in values]}
                              for qid, detail in details.items()},
                             lambda qid, _: classic_names(articles.get(qid), variants, labelled.get(qid)))
    covers = job.covers(POOLS[region.pool], articles)
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
                      'aliases': [], 'wikidata': qid, **({'cover': covers[qid]} if qid in covers else {})})
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
            groups = series_groups(works)
            totals = folded(job.popular(pool, list(works)), groups)
            asked = {name: REGIONS[name] for name in names}
            site = pool.wiki.replace('.wikipedia.org', 'wiki')
            series_items = entities(job.client, [series for series, _ in groups.values()], props='labels|sitelinks', site=site)
            completes = any('completed' in REGIONS[name].lists for name in names)
            by_series = 'infobox' in pool.finished_by
            finished = {}
            if completes and by_series:
                # A book alone is asked by its own article, a series by the series' article.
                articles = {}
                for title in ranked(totals['year'], limit=INFOBOX_CANDIDATES):
                    if title in groups:
                        key = groups[title][0]
                        article = series_items.get(key, {}).get('sitelinks', {}).get(site, {}).get('title')
                    else:
                        key, article = works[title]['qid'], title
                    if article:
                        articles[key] = article
                finished = job.infobox_finished(pool, articles)
            asks_bangumi = completes and 'bangumi' in pool.finished_by
            # Authors of every work where Bangumi needs them to tell works apart (華語 42, 日本 381);
            # of the listed ones alone for 英語, whose pool is 24 600.
            named = works if asks_bangumi else \
                {title: works[title] for title in shown_entries(totals, ended_entries(totals['year'], groups, works,
                                                                                      finished, by_series))}
            found = entities(job.client, [work['qid'] for work in named.values()], props='claims',
                             keep=('P170', 'P50', 'P2093'))
            details = author_names(job, found, asked, pool.wiki, {work['qid']: title for title, work in named.items()})
            if asks_bangumi:
                def titles_for(title, work):
                    base = strip_disambiguation(title)
                    return [strip_disambiguation(work['variants'].get('zh-cn', base)), base]
                job.refresh_finished(works, {qid: {'authors': [a for values in detail['authors'].values() for a in values]}
                                             for qid, detail in details.items()}, titles_for)
                finished = {work['qid']: bool((job.store.finished(work['qid']) or (None, 0))[1]) for work in works.values()}
            if completes and 'narou' in pool.finished_by:
                # Bangumi's light-novel series mostly give only 发售日 (この素晴らしい世界に祝福を！
                # has no 连载结束): either source saying it ended is enough.
                for qid, ended in job.narou_finished(pool, works).items():
                    finished[qid] = finished.get(qid, False) or ended
            done = ended_entries(totals['year'], groups, works, finished, by_series)
            shown = shown_entries(totals, done)
            names_of = series_titles(job, {groups[title][0]: series_items[groups[title][0]]
                                           for title in shown
                                           if title in groups and groups[title][0] in series_items}, pool.wiki, asked)
            # Where works were matched on Bangumi (華語, 日本), a work is a whole series.
            volumes = job.volume_covers([works[title]['qid'] for title in shown if title not in groups]) \
                if asks_bangumi else {}
            for name in names:
                for list_name, entries in build_region(job, name, REGIONS[name], works, details, done, totals,
                                                       groups, names_of, volumes).items():
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
    client = Client({'wikimedia': WIKIMEDIA_INTERVAL, 'api.bgm.tv': 1.0, 'query.wikidata.org': 1.0})
    job = Job(client, Store(arguments.db), datetime.now(timezone.utc).date(), arguments.limit)
    failed = run(job, arguments.output, arguments.region or list(REGIONS))
    if failed:
        print('failed: ' + ', '.join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
