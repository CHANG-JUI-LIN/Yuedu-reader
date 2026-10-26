from datetime import date, datetime, timedelta, timezone
import html
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError
from pathlib import Path

from scripts.trends import build_trends as builder

FIXTURES = Path(__file__).with_name('fixtures')


def subjects(name):
    return json.loads((FIXTURES / f'bangumi-{name}.json').read_text(encoding='utf-8'))['data']


class PureTests(unittest.TestCase):
    def test_a_story_is_kept_and_its_adaptation_is_not(self):
        self.assertTrue(builder.keeps_work(['Q1667921', 'Q277759']))   # 凡人修仙传: novel series
        self.assertTrue(builder.keeps_work(['Q104213567']))            # a light novel series
        self.assertFalse(builder.keeps_work(['Q5398426']))             # 香蜜沉沉燼如霜: television series
        self.assertFalse(builder.keeps_work([]))

    def test_titles_lose_the_articles_qualifier_and_compare_folded(self):
        self.assertEqual(builder.strip_disambiguation('天官赐福 (小说)'), '天官赐福')
        self.assertEqual(builder.strip_disambiguation('魔道祖師（小說）'), '魔道祖師')
        self.assertEqual(builder.strip_disambiguation('Re:ゼロから始める異世界生活'), 'Re:ゼロから始める異世界生活')
        self.assertEqual(builder.normalize_title('無職転生 〜異世界行ったら本気だす〜'),
                         builder.normalize_title('無職転生 ～異世界行ったら本気だす～'))
        self.assertEqual(builder.normalize_title('ＡＢＣ・def'), builder.normalize_title('abc def'))

    def test_both_scripts_read_one_chinese_label_then_convert_it(self):
        labels = {'zh': {'value': '罗贯中'}, 'zh-tw': {'value': '羅本'}}
        self.assertEqual(builder.label(labels, builder.REGIONS['zh-Hant'].labels), '罗贯中')
        self.assertEqual(builder.label(labels, builder.REGIONS['zh-Hans'].labels), '罗贯中')
        self.assertEqual(builder.label({'zh-hant': {'value': '忘語'}}, builder.REGIONS['zh-Hans'].labels), '忘語')
        self.assertIsNone(builder.label({}, ('ja',)))

    def test_a_name_kept_only_as_mul_is_every_languages_name(self):
        kipling = {'mul': {'value': 'Rudyard Kipling'}}
        self.assertEqual(builder.label(kipling, builder.REGIONS['en'].labels), 'Rudyard Kipling')
        self.assertEqual(builder.label({**kipling, 'en': {'value': 'Kipling'}}, ('en',)), 'Kipling')

    def test_ranked_by_views_ties_by_title_and_none_without_views(self):
        self.assertEqual(builder.ranked({'b': 5, 'a': 5, 'c': 9, 'd': 0}), ['c', 'a', 'b'])
        self.assertEqual(builder.ranked({str(n): n + 1 for n in range(80)}, limit=3), ['79', '78', '77'])


class BangumiTests(unittest.TestCase):
    def test_a_finished_novel_is_told_apart_from_its_manga(self):
        found = builder.bangumi_match(subjects('fanren'), ['凡人修仙传'], ['忘语'])
        self.assertEqual(found['id'], 260829)
        self.assertTrue(builder.bangumi_ended(found), '结束 2013-09-23')

    def test_a_novel_with_only_a_start_is_not_finished(self):
        found = builder.bangumi_match(subjects('daomu'), ['盗墓笔记', '盜墓筆記'], ['南派三叔'])
        self.assertEqual(found['id'], 10786)
        self.assertFalse(builder.bangumi_ended(found))

    def test_连载结束_counts_and_a_japanese_name_matches(self):
        found = builder.bangumi_match(subjects('slime'), ['転生したらスライムだった件'], ['伏瀬'])
        self.assertEqual(found['id'], 124785)
        self.assertTrue(builder.bangumi_ended(found))

    def test_a_pen_name_written_longer_is_the_same_author(self):
        # Bangumi 304497, as searched on 2026-10-21; Wikidata names the author 唐七.
        found = builder.bangumi_match([{'id': 304497, 'name': '三生三世十里桃花', 'name_cn': '三生三世十里桃花',
                                        'platform': '小说', 'infobox': [{'key': '作者', 'value': '唐七公子'}]}],
                                      ['三生三世十里桃花'], ['唐七'])
        self.assertEqual(found['id'], 304497)
        self.assertTrue(builder.same_author({'平鳥コウ'}, {builder.normalize_title('平鳥コウ (XPJbox)')}))

    def test_another_author_is_another_work(self):
        self.assertIsNone(builder.bangumi_match(subjects('fanren'), ['凡人修仙传'], ['南派三叔']))
        self.assertIsNone(builder.bangumi_match(subjects('fanren'), ['诡秘之主'], []))


class NarouClient:
    """ja.wikipedia's extlinks and 小説家になろう's API, shaped as they answered on 2026-10-22."""
    def json(self, url, params=None, body=None, headers=None):
        if 'syosetu' in url:
            asked = params['ncode'].split('-')
            novels = [{'title': 'Ｒｅ：ゼロから始める異世界生活', 'ncode': 'N2267BE', 'end': 1},
                      {'title': 'Re：Monster（リモンスター）――刺殺から始まる怪物転生記――', 'ncode': 'N1782T', 'end': 0},
                      {'title': '解体新書――刺殺から始まる怪物転生記――【装】の設定集', 'ncode': 'N5909V', 'end': 1}]
            shown = [novel for novel in novels if novel['ncode'].lower() in asked]
            return [{'allcount': len(shown)}] + shown
        links = {'Re:ゼロから始める異世界生活': ['https://ncode.syosetu.com/n2267be/'],
                 'Re:Monster': ['https://ncode.syosetu.com/n1782t/', 'https://ncode.syosetu.com/N5909V/'],
                 'JKハルは異世界で娼婦になった': ['https://ncode.syosetu.com/n4381dp/'],
                 'カクヨムの作品': []}
        return {'query': {'pages': [{'title': title, 'extlinks': [{'url': url} for url in links[title]]}
                                    for title in params['titles'].split('|')]}}


class NarouTests(unittest.TestCase):
    WORKS = {'Re:ゼロから始める異世界生活': {'qid': 'Q1'}, 'Re:Monster': {'qid': 'Q2'},
             'JKハルは異世界で娼婦になった': {'qid': 'Q3'}, 'カクヨムの作品': {'qid': 'Q4'}}

    def test_each_linked_work_is_asked_once_and_a_taken_down_one_is_unknown(self):
        job = builder.Job(NarouClient(), builder.Store(':memory:'), date(2026, 10, 22))
        self.assertEqual(job.narou_finished(builder.POOLS['ja'], self.WORKS), {'Q1': False, 'Q2': True})

    def test_of_several_links_the_work_is_the_one_titled_as_the_article(self):
        novels = {'n1782t': {'title': 'Re：Monster（リモンスター）――刺殺から始まる怪物転生記――'},
                  'n5909v': {'title': '解体新書――刺殺から始まる怪物転生記――【装】の設定集'}}
        self.assertEqual(builder.narou_pick('Re:Monster', ['n1782t', 'n5909v'], novels), 'n1782t')
        self.assertEqual(builder.narou_pick('Re:Monster', ['n5909v'], novels), 'n5909v')
        self.assertIsNone(builder.narou_pick('別の作品', ['n1782t', 'n5909v'], novels))
        self.assertIsNone(builder.narou_pick('JKハル', ['n4381dp'], novels))
        self.assertIn('narou', builder.POOLS['ja'].finished_by)
        self.assertNotIn('narou', builder.POOLS['zh'].finished_by)


class StoreTests(unittest.TestCase):
    def test_views_are_kept_per_day_and_ranked_by_window(self):
        store = builder.Store(':memory:')
        job = builder.Job(client=None, store=store, today=date(2026, 10, 21))
        pool = builder.POOLS['zh']
        yesterday = date(2026, 10, 20)
        store.add_views(pool.project, '甲', {builder.format_day(yesterday - timedelta(days=d)): 1 for d in range(100)})
        store.add_views(pool.project, '乙', {builder.format_day(yesterday): 50})
        totals = job.popular(pool, ['甲', '乙', '丙'])
        self.assertEqual(builder.ranked(totals['today']), ['乙', '甲'])
        self.assertEqual(builder.ranked(totals['year']), ['甲', '乙'])
        self.assertEqual(store.last_day(pool.project, '甲'), yesterday)
        self.assertIsNone(store.last_day(pool.project, '丙'))

    def test_windows_end_on_the_last_counted_day_and_older_days_go(self):
        store = builder.Store(':memory:')
        latest = date(2026, 10, 19)   # Wikimedia has not counted the 20th yet
        store.add_views('ja.wikipedia', '甲', {builder.format_day(latest - timedelta(days=d)): 10 for d in range(400)})
        job = builder.Job(client=None, store=store, today=date(2026, 10, 21))
        totals = job.popular(builder.POOLS['ja'], ['甲', '乙'])
        self.assertEqual({name: totals[name]['甲'] for name in totals}, {'today': 10, 'month': 300, 'year': 3650})
        self.assertEqual(totals['year']['乙'], 0)
        oldest = store.db.execute('select min(day) from views').fetchone()[0]
        self.assertEqual(oldest, builder.format_day(date(2026, 10, 21) - timedelta(days=builder.FIRST_DAYS)))


class OutputTests(unittest.TestCase):
    def test_a_list_file_names_its_region_list_and_source(self):
        works = [{'title': '詭秘之主', 'author': ['愛潛水的烏賊'], 'intro': '', 'url': 'u', 'aliases': [], 'wikidata': 'Q1'}]
        document = json.loads(builder.list_document('zh-Hant', 'today', works,
                                                    datetime(2026, 10, 21, tzinfo=timezone.utc)))
        self.assertEqual(document['schemaVersion'], 1)
        self.assertEqual((document['region'], document['list']), ('zh-Hant', 'today'))
        self.assertEqual(document['generatedAt'], '2026-10-21T00:00:00Z')
        self.assertIn('CC BY-SA', document['attribution'])
        self.assertEqual(document['works'], works)

    def test_articles_link_in_the_regions_script(self):
        self.assertEqual(builder.article_url('zh.wikipedia.org', '诡秘之主', 'zh-tw'),
                         'https://zh.wikipedia.org/zh-tw/%E8%AF%A1%E7%A7%98%E4%B9%8B%E4%B8%BB')
        self.assertEqual(builder.article_url('en.wikipedia.org', 'Fourth Wing'), 'https://en.wikipedia.org/wiki/Fourth_Wing')

    def test_a_series_is_one_classic_at_its_best_place(self):
        def entity(*series):
            return {'claims': {'P179': [{'mainsnak': {'datavalue': {'value': {'id': qid}}}} for qid in series]}}
        found = {'Q43361': entity('Q8337'), 'Q47209': entity('Q8337'), 'Q170583': entity(),
                 'Q607511': entity('Q1')}
        order = ['Q8337', 'Q170583', 'Q43361', 'Q47209', 'Q1', 'Q607511']
        self.assertEqual(builder.one_per_series(order, found), ['Q8337', 'Q170583', 'Q1'])
        self.assertEqual(builder.one_per_series(['Q43361', 'Q8337'], found), ['Q43361'])

    def test_a_creator_comes_before_the_authors(self):
        def claims(prop, *qids):
            return [{'mainsnak': {'datavalue': {'value': {'id': qid}}}} for qid in qids]
        entity = {'claims': {'P50': claims('P50', 'Q-colfer', 'Q-adams'), 'P170': claims('P170', 'Q-adams')}}
        self.assertEqual(builder.work_authors(entity), ['Q-adams', 'Q-colfer'])
        self.assertEqual(builder.work_authors({}), [])

    def test_only_the_claims_asked_for_are_held(self):
        class Client:
            def json(self, url, params=None, body=None, headers=None):
                claim = [{'mainsnak': {'datavalue': {'value': {'id': 'Q8261'}}}}]
                return {'entities': {qid: {'claims': {'P31': claim, 'P50': claim, 'P1476': claim}, 'labels': {}}
                                     for qid in params['ids'].split('|')}}
        found = builder.entities(Client(), ['Q1', 'Q2'], keep=('P31',))
        self.assertEqual(set(found['Q1']['claims']), {'P31'})
        self.assertIn('labels', found['Q1'])
        self.assertEqual(set(builder.entities(Client(), ['Q1'])['Q1']['claims']), {'P31', 'P50', 'P1476'})

    def test_classics_are_asked_in_every_written_form_of_the_language(self):
        self.assertIn('Q783605', builder.REGIONS['zh-Hant'].classic_languages)  # 紅樓夢: written vernacular Chinese
        self.assertIn('Q182695', builder.REGIONS['ja'].classic_languages)       # 源氏物語: Early Middle Japanese
        self.assertIn('Q36395', builder.REGIONS['en'].classic_languages)        # The Canterbury Tales: Middle English

    def test_english_novels_are_every_year_from_1890(self):
        categories = builder.english_categories(date(2026, 10, 22))
        self.assertEqual((categories[0], categories[-1]),
                         ('Category:1890 English-language novels', 'Category:2026 English-language novels'))

    def test_english_completion_comes_from_infoboxes_not_bangumi(self):
        self.assertIn('completed', builder.REGIONS['en'].lists)
        self.assertEqual(builder.POOLS['en'].finished_by, ('infobox',))
        self.assertEqual(set(builder.REGIONS), {'zh-Hant', 'zh-Hans', 'ja', 'en'})


def wikipedia(name):
    """An en.wikipedia lead section as the parse API answered on 2026-10-22."""
    return json.loads((FIXTURES / f'wikipedia-{name}.json').read_text(encoding='utf-8'))['parse']['wikitext']


class InfoboxTests(unittest.TestCase):
    # Fifty Shades of Grey links the redirect Fifty Shades trilogy; the API follows it.
    PAGES = {'Harry Potter': 'harry-potter', 'A Song of Ice and Fire': 'song-of-ice-and-fire',
             'Fifty Shades trilogy': 'fifty-shades-series', 'Jack Reacher': 'jack-reacher'}

    def page(self, title):
        return wikipedia(self.PAGES[title]) if title in self.PAGES else ''

    def test_values_keep_their_templates_and_links_whole(self):
        kind, params = builder.infobox(wikipedia('cormoran-strike'))
        self.assertEqual(kind, 'novel series')
        self.assertEqual(params['pub_date'], '4 April 2013–present')
        self.assertIn("''[[The Hallmarked Man]]'' (2025)", params['books'])
        self.assertEqual(params['number_of_books'], '8')
        self.assertIsNone(builder.infobox('No infobox here.'))

    def test_a_series_ended_when_its_dates_end_in_a_year(self):
        def ended(name):
            return builder.series_ended(builder.infobox(wikipedia(name))[1])
        self.assertTrue(ended('harry-potter'))          # 26 June 1997 – 21 July 2007
        self.assertTrue(ended('fifty-shades-series'))   # 2011–2021
        self.assertFalse(ended('song-of-ice-and-fire'))  # 1996 – present, two books planned
        self.assertFalse(ended('cormoran-strike'))       # 2013–present
        self.assertIsNone(builder.series_ended({'books': "''A'' (2008)<br />''B'' (2020)"}))

    def test_a_book_alone_is_finished_and_a_series_book_goes_by_its_series(self):
        def finished(name):
            return builder.infobox_finished(wikipedia(name), self.page)
        self.assertTrue(finished('project-hail-mary'))      # no series
        self.assertTrue(finished('deathly-hallows'))        # Harry Potter ended
        self.assertTrue(finished('fifty-shades-of-grey'))   # Fifty Shades ended
        self.assertFalse(finished('dance-with-dragons'))    # A Song of Ice and Fire goes on
        self.assertFalse(finished('cormoran-strike'))       # the series' own article
        self.assertIsNone(finished('fourth-wing'))          # ''The Empyrean'', no link
        # Gone Tomorrow → Jack Reacher (a character) → Jack Reacher (novel series), not saved.
        self.assertIsNone(finished('gone-tomorrow'))


class InfoboxClient:
    """en.wikipedia's parse API over the saved lead sections; a missing page as it answers."""
    def __init__(self):
        self.asked = []

    def json(self, url, params=None, body=None, headers=None):
        self.asked.append(params['page'])
        names = {'Project Hail Mary': 'project-hail-mary', 'A Dance with Dragons': 'dance-with-dragons',
                 'Harry Potter and the Deathly Hallows': 'deathly-hallows', 'Fourth Wing': 'fourth-wing',
                 **InfoboxTests.PAGES}
        if params['page'] not in names:
            return {'error': {'code': 'missingtitle', 'info': "The page you specified doesn't exist."}}
        return {'parse': {'title': params['page'], 'wikitext': wikipedia(names[params['page']])}}


class InfoboxJobTests(unittest.TestCase):
    def test_each_page_is_read_once_and_unknown_works_are_left_out(self):
        client = InfoboxClient()
        job = builder.Job(client, builder.Store(':memory:'), date(2026, 10, 22))
        works = {'Project Hail Mary': {'qid': 'Q1'}, 'A Dance with Dragons': {'qid': 'Q2'},
                 'Harry Potter and the Deathly Hallows': {'qid': 'Q3'}, 'Fourth Wing': {'qid': 'Q4'},
                 'Gone Missing': {'qid': 'Q5'}}
        finished = job.infobox_finished(builder.POOLS['en'], {work['qid']: title for title, work in works.items()})
        self.assertEqual(finished, {'Q1': True, 'Q2': False, 'Q3': True})
        self.assertEqual(sorted(client.asked), sorted(set(client.asked)))

    def test_a_series_is_asked_by_its_own_article(self):
        job = builder.Job(InfoboxClient(), builder.Store(':memory:'), date(2026, 10, 22))
        self.assertEqual(job.infobox_finished(builder.POOLS['en'], {'Q-hp': 'Harry Potter', 'Q-asoiaf': 'A Song of Ice and Fire'}),
                         {'Q-hp': True, 'Q-asoiaf': False})


class AuthorTests(unittest.TestCase):
    def test_the_book_infobox_names_the_author(self):
        self.assertEqual(builder.infobox_authors(wikipedia('project-hail-mary')), ['Andy Weir'])
        # 著者 of the Novel box, not the Manga box's 作者, which adds the artist.
        self.assertEqual(builder.infobox_authors(wikipedia('ja-katainaka')), ['佐賀崎しげる'])
        self.assertEqual(builder.infobox_authors(wikipedia('zh-xinsong')), ['阿越'])         # author = [[阿越]]
        self.assertEqual(builder.infobox_authors(wikipedia('zh-qieming')), ['灰熊猫'])       # 作者
        self.assertEqual(builder.infobox_authors(wikipedia('zh-lingjianshan')), ['國王陛下'])
        self.assertEqual(builder.infobox_authors(wikipedia('harry-potter')), ['J. K. Rowling'])
        self.assertEqual(builder.infobox_authors('{{Infobox television | writer = X}}'), [])
        self.assertEqual([kind for kind, _ in builder.infoboxes(wikipedia('ja-katainaka'))][:3],
                         ['animanga/header', 'animanga/novel', 'animanga/manga'])

    def test_a_value_is_read_as_plain_names(self):
        self.assertEqual(builder.plain_names('[[忘語|忘语]]<br />[[乙]]'), ['忘语', '乙'])
        self.assertEqual(builder.plain_names('{{plainlist|\n* [[A B]]\n* [[C D]]}}'), ['A B', 'C D'])
        self.assertEqual(builder.plain_names("'''A''' and [[B]]<ref name=x>{{cite web|title=t}}</ref>"), ['A', 'B'])
        self.assertEqual(builder.plain_names('國王陛下（小說）、{{nowrap|丙}}'), ['國王陛下', '丙'])
        self.assertEqual(builder.plain_names(''), [])

    def test_a_work_wikidata_names_no_one_for_reads_its_strings_then_its_infobox(self):
        class Client:
            def __init__(self):
                self.pages = []

            def json(self, url, params=None, body=None, headers=None):
                if 'wikidata' in url:
                    return {'entities': {qid: {'labels': {'mul': {'value': 'Andy Weir'}}} for qid in params['ids'].split('|')}}
                self.pages.append(params['page'])
                return {'parse': {'title': params['page'], 'wikitext': wikipedia('zh-xinsong')}}

        def strings(*values):
            return [{'mainsnak': {'datavalue': {'value': value}}} for value in values]
        client = Client()
        job = builder.Job(client, builder.Store(':memory:'), date(2026, 10, 22))
        found = {'Q-weir': {'claims': {'P50': [{'mainsnak': {'datavalue': {'value': {'id': 'Q-andy'}}}}]}},
                 'Q-lingao': {'claims': {'P2093': strings('萧峰')}},
                 'Q-xinsong': {'claims': {}}, 'Q-nothing': {'claims': {}}}
        details = builder.author_names(job, found, {'en': builder.REGIONS['en']}, 'zh.wikipedia.org',
                                       {'Q-weir': 'Project Hail Mary', 'Q-lingao': '临高启明', 'Q-xinsong': '新宋'})
        self.assertEqual({qid: detail['authors']['en'] for qid, detail in details.items()},
                         {'Q-weir': ['Andy Weir'], 'Q-lingao': ['萧峰'], 'Q-xinsong': ['阿越'], 'Q-nothing': []})
        self.assertEqual(client.pages, ['新宋'], 'an article is read only when Wikidata has no one')


def work(qid, series=None, published=None):
    return {'qid': qid, 'variants': {}, 'series': series, 'published': published}


class SeriesTests(unittest.TestCase):
    # Mistborn's books and its own article, The Way of Kings alone in its series, a book alone.
    WORKS = {'The Well of Ascension': work('Q-2', 'Q-mistborn', '2007-08-21T00:00:00Z'),
             'Mistborn: The Final Empire': work('Q-1', 'Q-mistborn', '2006-07-17T00:00:00Z'),
             'Mistborn: Secret History': work('Q-sh', 'Q-mistborn', '2016-01-26T00:00:00Z'),
             'Mistborn': work('Q-mistborn'),
             'The Way of Kings': work('Q-wok', 'Q-stormlight', '2010-08-31T00:00:00Z'),
             'Project Hail Mary': work('Q-phm', None, '2021-05-04T00:00:00Z')}

    def test_a_series_of_two_books_or_more_is_one_entry_under_its_first(self):
        groups = builder.series_groups(self.WORKS)
        self.assertEqual(list(groups), ['Mistborn: The Final Empire'])
        series, titles = groups['Mistborn: The Final Empire']
        self.assertEqual(series, 'Q-mistborn')
        self.assertEqual(sorted(titles), ['Mistborn', 'Mistborn: Secret History', 'Mistborn: The Final Empire',
                                          'The Well of Ascension'])

    def test_the_series_views_are_summed_under_its_head(self):
        groups = builder.series_groups(self.WORKS)
        totals = builder.folded({'year': {'The Well of Ascension': 5, 'Mistborn: The Final Empire': 7, 'Mistborn': 3,
                                          'Mistborn: Secret History': 1, 'The Way of Kings': 9, 'Project Hail Mary': 20}},
                                groups)
        self.assertEqual(totals['year'], {'Mistborn: The Final Empire': 16, 'The Way of Kings': 9, 'Project Hail Mary': 20})

    def test_a_series_ends_by_its_own_article_or_by_every_book(self):
        groups = builder.series_groups(self.WORKS)
        entries = ['Mistborn: The Final Empire', 'The Way of Kings', 'Project Hail Mary']
        by_article = {'Q-mistborn': True, 'Q-phm': True}
        self.assertEqual(builder.ended_entries(entries, groups, self.WORKS, by_article, by_series=True),
                         {'Mistborn: The Final Empire', 'Project Hail Mary'})
        by_book = {'Q-1': True, 'Q-2': True, 'Q-sh': False, 'Q-wok': True}
        self.assertEqual(builder.ended_entries(entries, groups, self.WORKS, by_book, by_series=False), {'The Way of Kings'})
        by_book['Q-sh'] = True
        self.assertIn('Mistborn: The Final Empire',
                      builder.ended_entries(entries, groups, self.WORKS, by_book, by_series=False))

    def test_a_series_entry_names_its_series(self):
        class Client:
            def json(self, url, params=None, body=None, headers=None):
                return {'query': {'pages': []}}
        job = builder.Job(Client(), builder.Store(':memory:'), date(2026, 10, 22))
        groups = builder.series_groups(self.WORKS)
        totals = builder.folded({window: {'Mistborn: The Final Empire': 3, 'Project Hail Mary': 2} for window in builder.WINDOWS},
                                groups)
        lists = builder.build_region(job, 'en', builder.REGIONS['en'], self.WORKS, {}, {'Project Hail Mary'}, totals,
                                     groups, {'Q-mistborn': {'en': 'Mistborn'}})
        self.assertEqual([(entry['title'], entry.get('series')) for entry in lists['year']],
                         [('Mistborn: The Final Empire', 'Mistborn'), ('Project Hail Mary', None)])
        self.assertEqual([entry['title'] for entry in lists['completed']], ['Project Hail Mary'])

    def test_a_series_entry_carries_its_other_books_covers_in_the_order_they_came_out(self):
        class Client:
            def json(self, url, params=None, body=None, headers=None):
                pages = [{'title': title, 'pageimage': f'{title}.jpg',
                          'thumbnail': {'source': f'https://upload.wikimedia.org/{title}.jpg?x=1', 'width': 260, 'height': 400}}
                         for title in params['titles'].split('|')]
                return {'query': {'pages': pages}}
        job = builder.Job(Client(), builder.Store(':memory:'), date(2026, 10, 26))
        groups = builder.series_groups(self.WORKS)
        self.assertEqual(builder.series_volumes('Mistborn: The Final Empire', groups, self.WORKS),
                         ['The Well of Ascension', 'Mistborn: Secret History'])
        totals = builder.folded({window: {'Mistborn: The Final Empire': 3, 'Project Hail Mary': 2} for window in builder.WINDOWS},
                                groups)
        lists = builder.build_region(job, 'en', builder.REGIONS['en'], self.WORKS, {}, set(), totals,
                                     groups, {'Q-mistborn': {'en': 'Mistborn'}})
        mistborn, alone = lists['year']
        self.assertEqual(mistborn['cover'], 'https://upload.wikimedia.org/Mistborn: The Final Empire.jpg')
        self.assertEqual(mistborn['seriesCovers'], ['https://upload.wikimedia.org/The Well of Ascension.jpg',
                                                    'https://upload.wikimedia.org/Mistborn: Secret History.jpg'])
        self.assertNotIn('seriesCovers', alone)

    def test_a_series_entry_carries_at_most_four_other_covers(self):
        works = {f'Book {number}': work(f'Q-{number}', 'Q-long', f'20{10 + number}-01-01T00:00:00Z') for number in range(1, 8)}
        groups = builder.series_groups(works)
        self.assertEqual(builder.series_volumes('Book 1', groups, works), [f'Book {number}' for number in range(2, 8)])

        class Client:
            def json(self, url, params=None, body=None, headers=None):
                return {'query': {'pages': [{'title': title, 'thumbnail': {'source': f'https://upload.wikimedia.org/{title}.jpg',
                                                                           'width': 2, 'height': 3}}
                                            for title in params['titles'].split('|')]}}
        job = builder.Job(Client(), builder.Store(':memory:'), date(2026, 10, 26))
        totals = builder.folded({window: {'Book 1': 1} for window in builder.WINDOWS}, groups)
        lists = builder.build_region(job, 'en', builder.REGIONS['en'], works, {}, set(), totals, groups,
                                     {'Q-long': {'en': 'Long'}})
        self.assertEqual(lists['year'][0]['seriesCovers'],
                         [f'https://upload.wikimedia.org/Book {number}.jpg' for number in range(2, 2 + builder.SERIES_COVERS)])

    def test_the_first_publication_is_the_earliest_date(self):
        def date_claim(value):
            return {'mainsnak': {'datavalue': {'value': {'time': value}}}}
        entity = {'claims': {'P577': [date_claim('+2008-01-01T00:00:00Z'), date_claim('+2006-07-17T00:00:00Z'),
                                      {'mainsnak': {'snaktype': 'somevalue'}}]}}
        self.assertEqual(builder.first_published(entity), '2006-07-17T00:00:00Z')
        self.assertIsNone(builder.first_published({}))


class ConvertingClient:
    """zh.wikipedia's parse, shaped as it answered on 2026-10-21: each sent paragraph as an HTML
    paragraph, converted by `mapping`; `drop` paragraphs left off the end."""
    def __init__(self, mapping, drop=0):
        self.mapping, self.drop, self.sent = mapping, drop, []

    def json(self, url, params=None, body=None, headers=None):
        self.sent.append(params)
        names = [html.unescape(name) for name in params['text'].split('\n\n')]
        names = names[:len(names) - self.drop]
        paragraphs = ''.join(f'<p>{html.escape(self.mapping.get(name, name), quote=False)}\n</p>' for name in names)
        return {'parse': {'text': f'<div class="mw-parser-output" lang="zh-Hant-TW">{paragraphs}</div>'}}


class ConversionTests(unittest.TestCase):
    MAPPING = {'墨香铜臭': '墨香銅臭', '当年明月': '當年明月', "O'Neil & 乱": "O'Neil & 亂"}

    def test_names_are_sent_as_plain_text_and_read_back_in_order(self):
        self.assertEqual(builder.wikitext_literal("O'Neil [x]"), 'O&#39;Neil&#32;&#91;x&#93;')
        client = ConvertingClient(self.MAPPING)
        converted = builder.convert_variant(client, 'zh.wikipedia.org', ['墨香铜臭', '当年明月', "O'Neil & 乱", ''], 'zh-tw')
        self.assertEqual(converted, self.MAPPING)
        self.assertEqual(client.sent[0]['variant'], 'zh-tw')
        self.assertNotIn("'", client.sent[0]['text'])

    def test_a_short_answer_is_an_error_not_a_guess(self):
        with self.assertRaises(ValueError):
            builder.convert_variant(ConvertingClient(self.MAPPING, drop=1), 'zh.wikipedia.org',
                                    ['墨香铜臭', '当年明月'], 'zh-tw')


class SparqlClient:
    def __init__(self):
        self.queries = 0

    def json(self, url, params=None, body=None, headers=None):
        self.queries += 1
        return {'results': {'bindings': [{'item': {'value': 'http://www.wikidata.org/entity/Q8265'}}]}}


class ClassicsTests(unittest.TestCase):
    def test_both_scripts_of_chinese_share_one_query(self):
        client = SparqlClient()
        job = builder.Job(client, builder.Store(':memory:'), date(2026, 10, 21))
        self.assertEqual(job.classics(builder.REGIONS['zh-Hant']), ['Q8265'])
        self.assertEqual(job.classics(builder.REGIONS['zh-Hans']), ['Q8265'])
        job.classics(builder.REGIONS['ja'])
        self.assertEqual(client.queries, 2)


class PoolClient:
    """A category of three novels, as zh.wikipedia and Wikidata answer."""
    TITLES = ['甲', '乙', '丙']

    def json(self, url, params=None, body=None, headers=None):
        if 'wikidata.org' in url:
            novel = [{'mainsnak': {'datavalue': {'value': {'id': 'Q8261'}}}}]
            return {'entities': {qid: {'claims': {'P31': novel}} for qid in params['ids'].split('|')}}
        if params.get('list') == 'categorymembers':
            return {'query': {'categorymembers': [{'ns': 0, 'title': title} for title in self.TITLES]}}
        return {'query': {'pages': [{'title': title, 'pageprops': {'wikibase_item': f'Q{index}'}}
                                    for index, title in enumerate(params['titles'].split('|'))]}}


class PoolTests(unittest.TestCase):
    def test_a_limited_run_stores_the_whole_pool(self):
        store = builder.Store(':memory:')
        limited = builder.Job(PoolClient(), store, date(2026, 10, 21), limit=2)
        works = limited.refresh_pool('zh', builder.POOLS['zh'])
        self.assertEqual(len(works), 3)
        self.assertEqual(len(limited.limited(works)), 2)
        whole = builder.Job(FailingClient(), store, date(2026, 10, 21))   # the week's pool, from the store
        self.assertEqual(sorted(whole.limited(whole.refresh_pool('zh', builder.POOLS['zh']))), ['丙', '乙', '甲'])


class StoreMigrationTests(unittest.TestCase):
    def test_a_store_without_series_reads_its_pools_again(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trends.sqlite'
            old = sqlite3.connect(path)
            old.executescript('''create table pool (project text, title text, qid text, variants text, refreshed text,
                                                    primary key (project, title));
                                 create table meta (key text primary key, value text);
                                 insert into pool values ('en.wikipedia', 'Fourth Wing', 'Q1', '{}', '2026-10-22');
                                 insert into meta values ('pool:en.wikipedia', '2026-10-22T00:00:00+00:00');
                                 insert into meta values ('other', 'kept');''')
            old.commit()
            old.close()
            store = builder.Store(path)
            self.assertIsNone(store.meta('pool:en.wikipedia'), 'the pool is read again, with its series')
            self.assertEqual(store.meta('other'), 'kept')
            self.assertIsNone(store.pool('en.wikipedia')['Fourth Wing']['series'])
            store.replace_pool('en.wikipedia', {'Fourth Wing': work('Q1', 'Q-empyrean', '2023-05-02T00:00:00Z')}, 'now')
            self.assertEqual(builder.Store(path).pool('en.wikipedia')['Fourth Wing']['series'], 'Q-empyrean')


class ImagesClient:
    """Wikipedia's pageimages answer, as it gives one: titles normalized and redirected, a
    logo kept as SVG, every thumbnail with its tracking query."""
    def __init__(self):
        self.asked = []

    def json(self, url, params=None, body=None, headers=None):
        self.asked.append(params['titles'].split('|'))
        def thumbnail(name, width=262, height=400):
            return {'pageimage': name, 'thumbnail': {
                'source': f'https://upload.wikimedia.org/wikipedia/en/thumb/a/ab/{name}/400px-{name}?utm_source=x',
                'width': width, 'height': height}}
        pages = {'Mistborn: The Final Empire': thumbnail('Mistborn.jpg'),
                 'Good Omens': thumbnail('Logo.svg'),
                 'Gulliver\'s Travels': thumbnail('Gullivers_travels.jpg', 400, 308),
                 'Gone Missing': {}}
        return {'query': {'normalized': [{'from': 'mistborn', 'to': 'Mistborn'}],
                          'redirects': [{'from': 'Mistborn', 'to': 'Mistborn: The Final Empire'}],
                          'pages': [{'title': title, **page} for title, page in pages.items()]}}


class CoverTests(unittest.TestCase):
    def test_a_standing_page_image_comes_back_under_the_title_asked_without_its_query(self):
        found = builder.page_images(ImagesClient(), 'en.wikipedia.org', ['mistborn', 'Good Omens', "Gulliver's Travels", 'Gone Missing'])
        self.assertEqual(found, {'mistborn': 'https://upload.wikimedia.org/wikipedia/en/thumb/a/ab/Mistborn.jpg/400px-Mistborn.jpg'},
                         'an SVG is a logo and a wide image a photo, not a cover')

    def test_fifty_titles_a_request(self):
        client = ImagesClient()
        builder.page_images(client, 'en.wikipedia.org', [f'Book {number}' for number in range(120)])
        self.assertEqual([len(titles) for titles in client.asked], [50, 50, 20])

    def test_bangumis_own_cover_first_then_the_page_image_asked_once_a_run(self):
        client = ImagesClient()
        store = builder.Store(':memory:')
        store.set_finished('Q-tasty', 260829, True, 'now', 'https://lain.bgm.tv/r/400/pic/cover/l/a7/52/260829_9oBCC.jpg')
        store.set_finished('Q-coverless', 1, False, 'now', None)
        job = builder.Job(client, store, date(2026, 10, 22))
        articles = {'Q-tasty': 'mistborn', 'Q-coverless': 'mistborn', 'Q-omens': 'Good Omens', 'Q-unlinked': None}
        covers = job.covers(builder.POOLS['en'], articles)
        self.assertEqual(covers, {'Q-tasty': 'https://lain.bgm.tv/r/400/pic/cover/l/a7/52/260829_9oBCC.jpg',
                                  'Q-coverless': 'https://upload.wikimedia.org/wikipedia/en/thumb/a/ab/Mistborn.jpg/400px-Mistborn.jpg'})
        self.assertEqual(job.covers(builder.POOLS['en'], articles), covers)
        self.assertEqual(client.asked, [['mistborn', 'Good Omens']], "華語's two scripts ask once")

    def test_japanese_page_images_are_not_asked_and_bangumis_cover_still_comes(self):
        client = ImagesClient()
        store = builder.Store(':memory:')
        store.set_finished('Q-slime', 1, True, 'now', 'https://lain.bgm.tv/r/400/pic/cover/l/slime.jpg')
        job = builder.Job(client, store, date(2026, 10, 22))
        self.assertEqual(job.covers(builder.POOLS['ja'], {'Q-slime': '転生したらスライムだった件', 'Q-other': 'mistborn'}),
                         {'Q-slime': 'https://lain.bgm.tv/r/400/pic/cover/l/slime.jpg'})
        self.assertEqual(client.asked, [], 'ja.wikipedia keeps no cover')

    def test_a_bangumi_subject_without_a_cover_has_none(self):
        self.assertEqual(builder.bangumi_cover({'images': {'common': 'https://lain.bgm.tv/r/400/pic/cover/l/x.jpg'}}),
                         'https://lain.bgm.tv/r/400/pic/cover/l/x.jpg')
        self.assertIsNone(builder.bangumi_cover({'images': {'common': ''}}))
        self.assertIsNone(builder.bangumi_cover({'images': None}))

    def test_bangumis_answer_keeps_the_matched_novels_cover(self):
        class BangumiClient:
            def json(self, url, params=None, body=None, headers=None):
                found = subjects('fanren')
                for subject in found:
                    subject['images'] = {'common': f"https://lain.bgm.tv/r/400/pic/cover/l/{subject['id']}.jpg"}
                return {'data': found}
        job = builder.Job(BangumiClient(), builder.Store(':memory:'), date(2026, 10, 22))
        job.refresh_finished({'凡人修仙傳': {'qid': 'Q-fanren'}}, {'Q-fanren': {'authors': ['忘语']}},
                             lambda title, work: ['凡人修仙传'])
        self.assertEqual(job.store.bangumi_cover('Q-fanren'), 'https://lain.bgm.tv/r/400/pic/cover/l/260829.jpg',
                         "the novel's, not its manga's")

    def test_a_classic_is_searched_in_simplified_script_then_by_its_article_or_label(self):
        variants = {'紅樓夢': {'qid': 'Q1', 'variants': {'zh-cn': '红楼梦', 'zh-tw': '紅樓夢'}}}
        self.assertEqual(builder.classic_names('紅樓夢', variants, None), ['红楼梦', '紅樓夢'])
        self.assertEqual(builder.classic_names('こころ (小説)', {}, None), ['こころ'])
        self.assertEqual(builder.classic_names(None, {}, '吶喊'), ['吶喊'])

    def test_a_store_without_covers_asks_bangumi_again_for_its_matches(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trends.sqlite'
            old = sqlite3.connect(path)
            old.executescript('''create table pool (project text, title text, qid text, variants text, refreshed text,
                                                    series text, published text, primary key (project, title));
                                 create table finished (qid text primary key, subject integer, ended integer, checked text);
                                 insert into finished values ('Q-matched', 260829, 1, '2026-10-22');
                                 insert into finished values ('Q-unmatched', null, 0, '2026-10-22');''')
            old.commit()
            old.close()
            store = builder.Store(path)
            self.assertIsNone(store.finished('Q-matched'), 'asked again, for its cover')
            self.assertEqual(store.finished('Q-unmatched'), (None, 0, '2026-10-22'))


class ParallelViewsTests(unittest.TestCase):
    def test_threads_together_wait_their_turns(self):
        client = builder.Client({'host.test': 0.02})
        start = time.monotonic()
        threads = [threading.Thread(target=lambda: [client._pace('host.test') for _ in range(3)]) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertGreaterEqual(time.monotonic() - start, 0.02 * 23)

    def test_wikimedias_hosts_share_one_budget(self):
        client = builder.Client({'wikimedia': 0.05})
        start = time.monotonic()
        for host in ('en.wikipedia.org', 'www.wikidata.org', 'wikimedia.org', 'ja.wikipedia.org'):
            client._pace(host)
        self.assertGreaterEqual(time.monotonic() - start, 0.05 * 3)
        self.assertEqual(builder.budget('query.wikidata.org'), 'query.wikidata.org')
        self.assertEqual(builder.budget('api.bgm.tv'), 'api.bgm.tv')

    def test_within_wikimedias_limit(self):
        # 200 requests a minute and 3 at once, for a bot whose User-Agent names it.
        self.assertLessEqual(60 / builder.WIKIMEDIA_INTERVAL, 200 * 0.9)
        self.assertLessEqual(builder.VIEW_WORKERS, 3)

    def test_a_request_unanswered_or_told_to_wait_is_asked_once_more(self):
        class Answer:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'{"ok": 1}'

        def asking(*failures):
            calls = []

            def urlopen(request, timeout):
                calls.append(request.full_url)
                if len(calls) <= len(failures):
                    raise failures[len(calls) - 1]
                return Answer()
            return calls, urlopen

        def busy(after=None):
            return HTTPError('https://wikimedia.org/x', 429, 'Too Many Requests',
                             {'Retry-After': after} if after else {}, None)

        cases = [
            ((TimeoutError('The read operation timed out'),), 2, [5]),
            ((URLError(TimeoutError('timed out')),), 2, [5]),
            ((busy('12'),), 2, [12]),
            ((busy('0'),), 2, [5]),
            ((busy(),), 2, [5]),
        ]
        for failures, asked, waits in cases:
            calls, urlopen = asking(*failures)
            with mock.patch.object(builder, 'urlopen', urlopen), mock.patch.object(builder.time, 'sleep') as sleep:
                self.assertEqual(builder.Client({}).json('https://wikimedia.org/x'), {'ok': 1})
            self.assertEqual(len(calls), asked)
            self.assertEqual([call.args[0] for call in sleep.call_args_list if call.args[0] >= 1], waits)

        # Not again: a 404, a second failure, a wait longer than MAX_RETRY_WAIT.
        for failures, asked in [((HTTPError('u', 404, 'Not Found', {}, None),), 1),
                                ((TimeoutError('t'), TimeoutError('t')), 2),
                                ((busy('600'),), 1)]:
            calls, urlopen = asking(*failures)
            with mock.patch.object(builder, 'urlopen', urlopen), mock.patch.object(builder.time, 'sleep'):
                with self.assertRaises((URLError, TimeoutError)):
                    builder.Client({}).json('https://wikimedia.org/x')
            self.assertEqual(len(calls), asked)

    def test_a_failed_request_stops_the_others(self):
        class Client:
            def __init__(self):
                self.calls = 0
                self.lock = threading.Lock()

            def json(self, url, params=None, body=None, headers=None):
                with self.lock:
                    self.calls += 1
                time.sleep(0.01)
                raise HTTPError(url, 500, 'Internal Server Error', {}, None)
        client = Client()
        job = builder.Job(client, builder.Store(':memory:'), date(2026, 10, 22))
        with self.assertRaises(HTTPError):
            job.refresh_views(builder.POOLS['en'], [f'Book {index}' for index in range(400)])
        self.assertLess(client.calls, 100)


class FailingClient:
    def json(self, url, params=None, body=None, headers=None):
        raise OSError('network is down')


class FailureTests(unittest.TestCase):
    def test_a_failed_run_keeps_the_last_files_and_says_which(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            (output / 'ja').mkdir()
            last = output / 'ja' / 'today.json'
            last.write_text('yesterday', encoding='utf-8')
            job = builder.Job(FailingClient(), builder.Store(':memory:'), date(2026, 10, 21))
            failed = builder.run(job, output, ['ja'])
            self.assertEqual(last.read_text(encoding='utf-8'), 'yesterday')
            self.assertEqual(sorted(failed), ['ja/classics', 'ja/completed', 'ja/month', 'ja/today', 'ja/year'])


if __name__ == '__main__':
    unittest.main()
