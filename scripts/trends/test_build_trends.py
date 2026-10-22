from datetime import date, datetime, timedelta, timezone
import html
import json
import tempfile
import unittest
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

    def test_windows_end_on_the_last_counted_day(self):
        latest = date(2026, 10, 20)
        daily = {builder.format_day(latest - timedelta(days=offset)): 10 for offset in range(400)}
        self.assertEqual(builder.window_total(daily, latest, 1), 10)
        self.assertEqual(builder.window_total(daily, latest, 30), 300)
        self.assertEqual(builder.window_total(daily, latest, 365), 3650)

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

    def test_classics_are_asked_in_every_written_form_of_the_language(self):
        self.assertIn('Q783605', builder.REGIONS['zh-Hant'].classic_languages)  # 紅樓夢: written vernacular Chinese
        self.assertIn('Q182695', builder.REGIONS['ja'].classic_languages)       # 源氏物語: Early Middle Japanese
        self.assertIn('Q36395', builder.REGIONS['en'].classic_languages)        # The Canterbury Tales: Middle English

    def test_english_has_no_completed_list(self):
        self.assertNotIn('completed', builder.REGIONS['en'].lists)
        self.assertEqual(set(builder.REGIONS), {'zh-Hant', 'zh-Hans', 'ja', 'en'})


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
