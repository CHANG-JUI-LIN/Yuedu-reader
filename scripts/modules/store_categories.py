#!/usr/bin/env python3
"""The store's categories (所有類型): writes them into three official modules' files.

The maintainer (2026-11-16) asked for 所有類型 as Apple Books has it, twenty-odd categories with
the nonfiction ones, each opening its own store with its subgenres as shelves (More in Romance).

- 趨勢 (official-module-trends.json): 小說與文學, a list of the region's own lists, its genres as
  shelves; each genre's subgenres, a shelf a subgenre for the regions whose wiki has it
  (scripts/trends/build_trends.py's `SUBGENRES` says which; the host writes their files).
- Bangumi (official-module-bangumi.json): 漫畫與圖畫小說, Bangumi's manga by tag.
- Open Library (official-module-openlibrary.json): everything else, its search by subject: a
  list per category, its subgenres an option of its `topic` (a module holds at most 50 lists),
  sorted by Open Library's own `trending`, `new` and `rating`.

Open Library files novels under nearly every subject (`history` led with The Woman in White,
`science` with Solaris; checked 2026-11-16), so a nonfiction category leaves out what is filed
under fiction. Titles are the works' own, mostly English: Open Library's records are.

    python3 scripts/modules/store_categories.py          # rewrite the three module files
    python3 scripts/modules/store_categories.py --probe  # ask each Open Library query once
"""
import importlib.util
from urllib.parse import quote
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'Resources/Assets/official-module-openlibrary.json'
TRENDS = ROOT / 'Resources/Assets/official-module-trends.json'
BANGUMI = ROOT / 'Resources/Assets/official-module-bangumi.json'
LANGUAGES = ('zh-Hans', 'en', 'ja', 'ko')
# Open Library files erotica under ordinary subjects (`photography` led with it, 2026-11-16): every
# query leaves it out. A nonfiction one leaves out fiction and romance as well (`sports` led with
# Elle Kennedy's novels).
NO_EROTICA = ' -subject:"erotica" -subject:"erotic photography" -subject:"photography, erotic" -subject:"erotic literature" -subject:"sex instruction"'
NOT_FICTION = ' -subject:"fiction" -subject:"romance" -subject:"love stories"'
USER_AGENT = 'yuedureader/Yuedu (iOS) (+https://yuedureader.com/support)'


def s(subject):
    """A query of one subject."""
    return f'subject:"{subject}"'


# (id, names zh-Hant/zh-Hans/en/ja/ko, query, fiction, [(sub id, names, query)…]) in 所有類型's
# order. A subgenre's query is narrowed to the category's when it alone is too wide.
CATEGORIES = [
    ('kids', ('兒童', '儿童', 'Kids', '児童書', '어린이'), s('juvenile fiction'), True, [
        ('picture-books', ('圖畫書', '图画书', 'Picture Books', '絵本', '그림책'), s('picture books')),
        ('fairy-tales', ('童話', '童话', 'Fairy Tales', '童話', '동화'), s('fairy tales')),
        ('animals', ('動物故事', '动物故事', 'Animal Stories', '動物の物語', '동물 이야기'), s('animals') + ' ' + s('juvenile fiction')),
        ('adventure', ('冒險', '冒险', 'Adventure', '冒険', '모험'), s('adventure and adventurers') + ' ' + s('juvenile fiction')),
        ('school', ('校園', '校园', 'School', '学校', '학교'), s('schools') + ' ' + s('juvenile fiction')),
        ('friendship', ('友誼', '友谊', 'Friendship', '友情', '우정'), s('friendship') + ' ' + s('juvenile fiction')),
    ]),
    ('nonfiction', ('非小說', '非小说', 'Nonfiction', 'ノンフィクション', '논픽션'), s('nonfiction'), False, [
        ('self-help', ('自我成長', '自我成长', 'Self-Improvement', '自己啓発', '자기계발'), s('self-help')),
        ('true-crime', ('真實犯罪', '真实犯罪', 'True Crime', '実録犯罪', '실화 범죄'), s('true crime')),
        ('popular-science', ('科普', '科普', 'Popular Science', 'ポピュラーサイエンス', '대중 과학'), s('popular science')),
        ('essays', ('散文隨筆', '散文随笔', 'Essays', 'エッセイ', '에세이'), s('essays')),
        ('philosophy', ('哲學', '哲学', 'Philosophy', '哲学', '철학'), s('philosophy')),
        ('social-sciences', ('社會科學', '社会科学', 'Social Science', '社会科学', '사회과학'), s('social sciences')),
    ]),
    ('biography', ('傳記與回憶錄', '传记与回忆录', 'Biographies & Memoirs', '伝記・回想録', '전기 및 회고록'), s('biography'), False, [
        ('autobiography', ('自傳', '自传', 'Autobiography', '自伝', '자서전'), s('autobiography')),
        ('entertainers', ('演藝人物', '演艺人物', 'Arts & Entertainment', '芸能人', '연예인'), s('actors')),
        ('politicians', ('政治人物', '政治人物', 'Political Figures', '政治家', '정치인'), s('politicians')),
        ('athletes', ('運動員', '运动员', 'Sports Figures', 'スポーツ選手', '운동선수'), s('athletes')),
        ('artists', ('藝術家', '艺术家', 'Artists', '芸術家', '예술가'), s('artists')),
        ('scientists', ('科學家', '科学家', 'Scientists', '科学者', '과학자'), s('scientists')),
    ]),
    ('history', ('歷史', '历史', 'History', '歴史', '역사'), s('history'), False, [
        ('world', ('世界史', '世界史', 'World History', '世界史', '세계사'), s('world history')),
        ('military', ('軍事史', '军事史', 'Military History', '軍事史', '군사사'), s('military history')),
        ('ancient', ('古代史', '古代史', 'Ancient History', '古代史', '고대사'), s('ancient history')),
        ('ww2', ('第二次世界大戰', '第二次世界大战', 'World War II', '第二次世界大戦', '제2차 세계 대전'), s('world war, 1939-1945')),
        ('china', ('中國史', '中国史', 'Chinese History', '中国史', '중국사'), s('china') + ' ' + s('history')),
        ('japan', ('日本史', '日本史', 'Japanese History', '日本史', '일본사'), s('japan') + ' ' + s('history')),
    ]),
    ('business', ('商業與個人理財', '商业与个人理财', 'Business & Personal Finance', 'ビジネス・マネー', '비즈니스 및 개인 금융'), s('business'), False, [
        ('personal-finance', ('個人理財', '个人理财', 'Personal Finance', '資産運用', '개인 금융'), s('personal finance')),
        ('investing', ('投資', '投资', 'Investing', '投資', '투자'), s('investments')),
        ('leadership', ('領導', '领导', 'Leadership', 'リーダーシップ', '리더십'), s('leadership')),
        ('marketing', ('行銷', '营销', 'Marketing', 'マーケティング', '마케팅'), s('marketing')),
        ('economics', ('經濟學', '经济学', 'Economics', '経済学', '경제학'), s('economics')),
        ('entrepreneurship', ('創業', '创业', 'Entrepreneurship', '起業', '창업'), s('entrepreneurship')),
    ]),
    ('health', ('健康、心理與生理', '健康、心理与生理', 'Health, Mind & Body', '健康・心と体', '건강, 마음 및 신체'), s('health'), False, [
        ('psychology', ('心理學', '心理学', 'Psychology', '心理学', '심리학'), s('psychology')),
        ('fitness', ('健身', '健身', 'Fitness', 'フィットネス', '피트니스'), s('physical fitness')),
        ('nutrition', ('營養', '营养', 'Nutrition', '栄養', '영양'), s('nutrition')),
        ('meditation', ('冥想', '冥想', 'Meditation', '瞑想', '명상'), s('meditation')),
        ('mental-health', ('心理健康', '心理健康', 'Mental Health', 'メンタルヘルス', '정신 건강'), s('mental health')),
        ('diet', ('飲食', '饮食', 'Diet', '食事法', '식단'), s('diet')),
    ]),
    ('religion', ('宗教與靈修', '宗教与灵修', 'Religion & Spirituality', '宗教・スピリチュアル', '종교 및 영성'), s('religion'), False, [
        ('christianity', ('基督教', '基督教', 'Christianity', 'キリスト教', '기독교'), s('christian life')),
        ('buddhism', ('佛教', '佛教', 'Buddhism', '仏教', '불교'), s('buddhism')),
        ('spirituality', ('靈性', '灵性', 'Spirituality', 'スピリチュアリティ', '영성'), s('spirituality')),
        ('islam', ('伊斯蘭教', '伊斯兰教', 'Islam', 'イスラム教', '이슬람교'), s('islam')),
        ('mythology', ('神話', '神话', 'Mythology', '神話', '신화'), s('mythology')),
    ]),
    ('politics', ('政治與時事', '政治与时事', 'Politics & Current Events', '政治・時事', '정치 및 시사'), s('politics and government'), False, [
        ('international', ('國際關係', '国际关系', 'International Relations', '国際関係', '국제 관계'), s('international relations')),
        ('democracy', ('民主', '民主', 'Democracy', '民主主義', '민주주의'), s('democracy')),
        ('social-issues', ('社會議題', '社会议题', 'Social Issues', '社会問題', '사회 문제'), s('social problems')),
        ('journalism', ('新聞', '新闻', 'Journalism', 'ジャーナリズム', '저널리즘'), s('journalism')),
        ('human-rights', ('人權', '人权', 'Human Rights', '人権', '인권'), s('human rights')),
    ]),
    ('education', ('教育', '教育', 'Education', '教育', '교육'), s('education'), False, [
        ('teaching', ('教學', '教学', 'Teaching', '教授法', '교수법'), s('teaching')),
        ('study-skills', ('學習方法', '学习方法', 'Study Skills', '勉強法', '학습법'), s('study skills')),
        ('languages', ('語言學習', '语言学习', 'Language Learning', '語学', '어학'), s('language and languages')),
        ('early-childhood', ('幼兒教育', '幼儿教育', 'Early Childhood', '幼児教育', '유아 교육'), s('early childhood education')),
    ]),
    ('cooking', ('食譜、美食與品酒', '食谱、美食与品酒', 'Cookbooks, Food & Wine', '料理・グルメ・ワイン', '요리, 음식 및 와인'), s('cooking'), False, [
        ('baking', ('烘焙', '烘焙', 'Baking', 'お菓子・パン作り', '베이킹'), s('baking')),
        ('desserts', ('甜點', '甜点', 'Desserts', 'デザート', '디저트'), s('desserts')),
        ('vegetarian', ('素食', '素食', 'Vegetarian', 'ベジタリアン', '채식'), s('vegetarian cooking')),
        ('wine', ('葡萄酒', '葡萄酒', 'Wine', 'ワイン', '와인'), s('wine and wine making')),
        ('chinese', ('中式料理', '中式料理', 'Chinese Cooking', '中華料理', '중식'), s('cooking, chinese')),
        ('italian', ('義式料理', '意式料理', 'Italian Cooking', 'イタリア料理', '이탈리아 요리'), s('cooking, italian')),
    ]),
    ('sports', ('運動與戶外活動', '运动与户外活动', 'Sports & Outdoors', 'スポーツ・アウトドア', '스포츠 및 아웃도어'), s('sports'), False, [
        ('soccer', ('足球', '足球', 'Soccer', 'サッカー', '축구'), s('soccer')),
        ('basketball', ('籃球', '篮球', 'Basketball', 'バスケットボール', '농구'), s('basketball')),
        ('baseball', ('棒球', '棒球', 'Baseball', '野球', '야구'), s('baseball')),
        ('mountaineering', ('登山', '登山', 'Mountaineering', '登山', '등산'), s('mountaineering')),
        ('fishing', ('釣魚', '钓鱼', 'Fishing', '釣り', '낚시'), s('fishing')),
        ('running', ('跑步', '跑步', 'Running', 'ランニング', '달리기'), s('running')),
    ]),
    ('computers', ('電腦與網路', '电脑与网络', 'Computers & Internet', 'コンピュータ・インターネット', '컴퓨터 및 인터넷'), s('computers'), False, [
        ('programming', ('程式設計', '程序设计', 'Programming', 'プログラミング', '프로그래밍'), s('computer programming')),
        ('internet', ('網際網路', '互联网', 'Internet', 'インターネット', '인터넷'), s('internet')),
        ('ai', ('人工智慧', '人工智能', 'Artificial Intelligence', '人工知能', '인공지능'), s('artificial intelligence')),
        ('security', ('資訊安全', '信息安全', 'Security', 'セキュリティ', '보안'), s('computer security')),
        ('databases', ('資料庫', '数据库', 'Databases', 'データベース', '데이터베이스'), s('database management')),
    ]),
    ('arts', ('藝術與娛樂', '艺术与娱乐', 'Arts & Entertainment', 'アート・エンターテインメント', '예술 및 엔터테인먼트'), s('art'), False, [
        ('music', ('音樂', '音乐', 'Music', '音楽', '음악'), s('music')),
        ('film', ('電影', '电影', 'Film', '映画', '영화'), s('motion pictures')),
        ('photography', ('攝影', '摄影', 'Photography', '写真', '사진'), s('photographers')),
        ('architecture', ('建築', '建筑', 'Architecture', '建築', '건축'), s('architecture')),
        ('design', ('設計', '设计', 'Design', 'デザイン', '디자인'), s('design')),
    ]),
    ('science', ('科學與自然', '科学与自然', 'Science & Nature', '科学・自然', '과학 및 자연'), s('science'), False, [
        ('physics', ('物理', '物理', 'Physics', '物理学', '물리학'), s('physics')),
        ('biology', ('生物', '生物', 'Biology', '生物学', '생물학'), s('biology')),
        ('astronomy', ('天文', '天文', 'Astronomy', '天文学', '천문학'), s('astronomy')),
        ('mathematics', ('數學', '数学', 'Mathematics', '数学', '수학'), s('mathematics')),
        ('nature', ('自然', '自然', 'Nature', '自然', '자연'), s('natural history')),
        ('animals', ('動物', '动物', 'Animals', '動物', '동물'), s('animals')),
    ]),
    ('travel', ('旅遊與探險', '旅游与探险', 'Travel & Adventure', '旅行・冒険', '여행 및 모험'), s('travel'), False, [
        ('guidebooks', ('旅遊指南', '旅游指南', 'Guidebooks', 'ガイドブック', '여행 안내서'), s('guidebooks')),
        ('adventure', ('探險', '探险', 'Adventure', '探検', '탐험'), s('adventure and adventurers')),
        ('voyages', ('航海與遊記', '航海与游记', 'Voyages & Travels', '航海・紀行', '항해와 여행기'), s('voyages and travels')),
        ('europe', ('歐洲', '欧洲', 'Europe', 'ヨーロッパ', '유럽'), s('europe, description and travel')),
        ('asia', ('亞洲', '亚洲', 'Asia', 'アジア', '아시아'), s('asia, description and travel')),
    ]),
    ('lifestyle', ('生活與家居', '生活与家居', 'Lifestyle & Home', '暮らし・住まい', '라이프스타일 및 홈'), s('home economics'), False, [
        ('gardening', ('園藝', '园艺', 'Gardening', 'ガーデニング', '원예'), s('gardening')),
        ('crafts', ('手作', '手工', 'Crafts', '手芸', '공예'), s('handicraft')),
        ('interior', ('居家佈置', '居家布置', 'Interior Design', 'インテリア', '인테리어'), s('interior decoration')),
        ('pets', ('寵物', '宠物', 'Pets', 'ペット', '반려동물'), s('pets')),
    ]),
    ('parenting', ('育兒', '育儿', 'Parenting', '子育て', '육아'), s('parenting'), False, [
        ('parent-child', ('親子', '亲子', 'Parent & Child', '親子', '부모와 자녀'), s('parent and child')),
        ('infants', ('嬰幼兒', '婴幼儿', 'Babies', '乳幼児', '영유아'), s('infants')),
        ('adolescence', ('青春期', '青春期', 'Teens', '思春期', '사춘기'), s('adolescence')),
    ]),
    ('humor', ('幽默', '幽默', 'Humor', 'ユーモア', '유머'), s('humor'), False, [
        ('wit', ('笑話與妙語', '笑话与妙语', 'Wit & Humor', 'ジョーク', '재치와 유머'), s('wit and humor')),
        ('comic-strips', ('漫畫短篇', '漫画短篇', 'Comic Strips', '風刺漫画', '만화'), s('comic books, strips')),
    ]),
    ('professional', ('專業與技術', '专业与技术', 'Professional & Technical', '専門・技術', '전문 및 기술'), s('technology'), False, [
        ('engineering', ('工程', '工程', 'Engineering', '工学', '공학'), s('engineering')),
        ('medicine', ('醫學', '医学', 'Medicine', '医学', '의학'), s('medicine')),
        ('law', ('法律', '法律', 'Law', '法律', '법률'), s('law')),
        ('nursing', ('護理', '护理', 'Nursing', '看護', '간호'), s('nursing')),
    ]),
    ('reference', ('參考', '参考', 'Reference', 'リファレンス', '참고'), s('reference'), False, [
        ('dictionaries', ('字典', '词典', 'Dictionaries', '辞書', '사전'), s('dictionaries')),
        ('encyclopedias', ('百科全書', '百科全书', 'Encyclopedias', '百科事典', '백과사전'), s('encyclopedias')),
        ('writing', ('寫作', '写作', 'Writing', '文章術', '글쓰기'), s('authorship')),
    ]),
]

SORTS = [('trending', ('熱門書籍', '热门书籍', 'Popular', '人気の本', '인기 도서')),
         ('new', ('最新出版', '最新出版', 'New', '新刊', '신간')),
         ('rating', ('好評推薦', '好评推荐', 'Top Rated', '高評価', '높은 평점'))]
TOPIC = ('主題', '主题', 'Topic', 'トピック', '주제')
ALL = ('全部', '全部', 'All', 'すべて', '전체')
SORT = ('排序', '排序', 'Sort', '並べ替え', '정렬')
# Each category's store, as a genre's: its carousel, the newest, the best rated, then its subgenres.
STORE = [('heroCards', 'trending'), ('heroGrid', 'new'), ('row', 'rating')]


def exclusions(fiction):
    return NO_EROTICA if fiction else NOT_FICTION + NO_EROTICA


def query(text, fiction):
    return text + exclusions(fiction)


def entry(category):
    cid, names, text, fiction, subs = category
    # A topic's value is its subject alone; the category's exclusions are written into the URL
    # once (with them in every value, and in every language's options, the file outgrew the
    # validator's 256 KiB).
    topic_options = [{'title': ALL[0], 'value': text}]
    topic_options += [{'title': sub[1][0], 'value': sub[2]} for sub in subs]
    params = [
        {'name': 'topic', 'title': TOPIC[0], 'type': 'enumeration', 'value': text, 'enumOptions': topic_options},
        {'name': 'sort', 'title': SORT[0], 'type': 'enumeration', 'value': 'trending',
         'enumOptions': [{'title': title[0], 'value': value} for value, title in SORTS]},
        {'name': 'offset', 'type': 'offset'},
    ]
    store = [{'layout': layout, 'params': {'sort': sort}} for layout, sort in STORE]
    if subs:
        store.append({'layout': 'groupedShelves',
                      'shelves': [{'params': {'topic': sub[2]}} for sub in subs]})
    return {
        'id': cid,
        'title': names[0],
        'cacheDuration': 86400,
        'params': params,
        'request': {
            'url': 'https://openlibrary.org/search.json?q={{topic}}' + quote(exclusions(fiction), safe='') + '&sort={{sort}}'
                   '&fields=key,title,author_name,cover_i,language,isbn&limit=20&offset={{offset}}',
            'headers': {'User-Agent': USER_AGENT, 'Accept': 'application/json'},
        },
        'list': {'items': '$.docs[*]', 'title': '$.title', 'author': '$.author_name',
                 'cover': '$.cover_i##^(\\d+)$##https://covers.openlibrary.org/b/id/$1-M.jpg',
                 'url': '$.key', 'language': '$.language', 'isbn': '$.isbn'},
        'store': store,
    }


def localized(category, index):
    cid, names, text, fiction, subs = category
    options = {text: ALL[index]}
    options.update({sub[2]: sub[1][index] for sub in subs})
    return {'title': names[index], 'params': {
        'topic': {'title': TOPIC[index], 'options': options},
        'sort': {'title': SORT[index], 'options': {value: title[index] for value, title in SORTS}},
    }}


def save(path, module):
    path.write_text(json.dumps(module, ensure_ascii=False, indent=2) + '\n')


def write_openlibrary():
    module = json.loads(MODULE.read_text())
    module['modules'] = [entry(category) for category in CATEGORIES]
    for index, language in enumerate(LANGUAGES, start=1):
        module['localizations'].setdefault(language, {})['entries'] = {
            category[0]: localized(category, index) for category in CATEGORIES}
    module['version'], module['requiredVersion'] = '1.1', '3.0.2'
    save(MODULE, module)


def probe():
    def ask(item):
        name, text = item
        params = urlencode({'q': text, 'sort': 'trending', 'limit': 12, 'fields': 'title,cover_i'})
        out = subprocess.run(['curl', '-s', '-m', '40', '-A', USER_AGENT, f'https://openlibrary.org/search.json?{params}'],
                             capture_output=True, text=True).stdout
        try:
            answer = json.loads(out)
        except ValueError:
            return f'{name}: no answer'
        docs = answer['docs']
        covered = sum(1 for doc in docs if doc.get('cover_i'))
        return f"{name}: {answer['numFound']} found, {covered}/{len(docs)} covers — " + ' | '.join(d['title'][:24] for d in docs[:4])
    items = []
    for cid, names, text, fiction, subs in CATEGORIES:
        items.append((names[0], query(text, fiction)))
        items += [(f'  {names[0]} › {sub[1][0]}', query(sub[2], fiction)) for sub in subs]
    with ThreadPoolExecutor(3) as pool:
        for line in pool.map(ask, items):
            print(line, flush=True)


# MARK: - 趨勢

def trends_subgenres():
    spec = importlib.util.spec_from_file_location('build_trends', ROOT / 'scripts/trends/build_trends.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    return builder.SUBGENRES


# Each subgenre's name (zh-Hant, zh-Hans, en, ja, ko), by genre and id: the host's ids, which wiki
# has which is its `SUBGENRES`.
SUBGENRE_NAMES = {
    'romance': {
        'contemporary': ('現代愛情', '现代爱情', 'Contemporary Romance', '現代ロマンス', '현대 로맨스'),
        'historical': ('歷史愛情', '历史爱情', 'Historical Romance', 'ヒストリカル・ロマンス', '역사 로맨스'),
        'paranormal': ('超自然愛情', '超自然爱情', 'Paranormal Romance', 'パラノーマル・ロマンス', '초자연 로맨스'),
        'romantic-fantasy': ('奇幻愛情', '奇幻爱情', 'Romantic Fantasy', 'ロマンス・ファンタジー', '로맨스 판타지'),
        'romcom': ('浪漫喜劇', '浪漫喜剧', 'Romantic Comedy', 'ラブコメ', '로맨틱 코미디'),
        'young-adult': ('青春愛情', '青春爱情', 'Young Adult Romance', 'ヤングアダルト・ロマンス', '청소년 로맨스'),
        'romantic-sf': ('科幻愛情', '科幻爱情', 'Science Fiction Romance', 'SFロマンス', 'SF 로맨스'),
        'harem': ('後宮', '后宫', 'Harem', 'ハーレム', '하렘'),
        'qiongyao': ('瓊瑤', '琼瑶', 'Chiung Yao', '瓊瑤', '충야오'),
        'yuri': ('百合', '百合', 'Yuri', '百合', '백합'),
    },
    'mystery': {
        'detective': ('偵探', '侦探', 'Detective', '探偵小説', '탐정'),
        'psychological': ('心理驚悚', '心理惊悚', 'Psychological Thrillers', 'サイコスリラー', '심리 스릴러'),
        'political': ('政治驚悚', '政治惊悚', 'Political Thrillers', 'ポリティカル・スリラー', '정치 스릴러'),
        'techno': ('科技驚悚', '科技惊悚', 'Techno-Thrillers', 'テクノスリラー', '테크노 스릴러'),
        'historical': ('歷史推理', '历史推理', 'Historical Mysteries', '歴史ミステリー', '역사 미스터리'),
        'legal': ('法庭推理', '法庭推理', 'Legal Thrillers', 'リーガル・サスペンス', '법정 스릴러'),
        'serial-killers': ('連環殺手', '连环杀手', 'Serial Killers', '連続殺人', '연쇄 살인'),
        'sherlock': ('福爾摩斯', '福尔摩斯', 'Sherlock Holmes', 'シャーロック・ホームズ', '셜록 홈스'),
        'christie': ('阿嘉莎·克莉絲蒂', '阿加莎·克里斯蒂', 'Agatha Christie', 'アガサ・クリスティー', '애거사 크리스티'),
        'japanese': ('日本推理', '日本推理', 'Japanese Crime', '日本の犯罪小説', '일본 범죄 소설'),
        'gongan': ('公案', '公案', "Gong'an", '公案小説', '공안 소설'),
        'thriller': ('驚悚', '惊悚', 'Thrillers', 'スリラー', '스릴러'),
        'short-stories': ('推理短篇', '推理短篇', 'Mystery Short Stories', 'ミステリー短編集', '미스터리 단편'),
        'top': ('高分推理', '高分推理', 'Top-Rated Mysteries', '高評価のミステリー', '평점 높은 미스터리'),
    },
    'scifi': {
        'space': ('太空', '太空', 'Outer Space', '宇宙', '우주'),
        'dystopia': ('反烏托邦', '反乌托邦', 'Dystopia', 'ディストピア', '디스토피아'),
        'space-opera': ('太空歌劇', '太空歌剧', 'Space Opera', 'スペースオペラ', '스페이스 오페라'),
        'parallel': ('平行世界', '平行世界', 'Parallel Universes', 'パラレルワールド', '평행 우주'),
        'military': ('軍事科幻', '军事科幻', 'Military Science Fiction', 'ミリタリーSF', '밀리터리 SF'),
        'ai': ('人工智慧與機器人', '人工智能与机器人', 'AI & Robots', 'AI・ロボット', 'AI와 로봇'),
        'steampunk': ('蒸汽龐克', '蒸汽朋克', 'Steampunk', 'スチームパンク', '스팀펑크'),
        'isekai': ('異世界', '异世界', 'Isekai', '異世界', '이세계'),
        'wisely': ('衛斯理', '卫斯理', 'Wisely Series', '衛斯理シリーズ', '위슬리 시리즈'),
        'science-fantasy': ('科學奇幻', '科学奇幻', 'Science Fantasy', 'サイエンス・ファンタジー', '사이언스 판타지'),
        'short-stories': ('科幻短篇', '科幻短篇', 'Science Fiction Short Stories', 'SF短編', 'SF 단편'),
        'aliens': ('外星人', '外星人', 'Aliens', '異星人', '외계인'),
        'cyberpunk': ('賽博龐克', '赛博朋克', 'Cyberpunk', 'サイバーパンク', '사이버펑크'),
        'sf-horror': ('科幻恐怖', '科幻恐怖', 'Science Fiction Horror', 'SFホラー', 'SF 호러'),
        'top': ('高分科幻', '高分科幻', 'Top-Rated Science Fiction', '高評価のSF', '평점 높은 SF'),
    },
    'fantasy': {
        'high': ('史詩奇幻', '史诗奇幻', 'High Fantasy', 'ハイファンタジー', '하이 판타지'),
        'dark': ('黑暗奇幻', '黑暗奇幻', 'Dark Fantasy', 'ダークファンタジー', '다크 판타지'),
        'contemporary': ('都市奇幻', '都市奇幻', 'Contemporary Fantasy', '現代ファンタジー', '현대 판타지'),
        'historical': ('歷史奇幻', '历史奇幻', 'Historical Fantasy', '歴史ファンタジー', '역사 판타지'),
        'magic': ('魔法', '魔法', 'Magic', '魔法', '마법'),
        'fairies': ('精靈', '精灵', 'Fairies', '妖精', '요정'),
        'romantic-fantasy': ('奇幻愛情', '奇幻爱情', 'Romantic Fantasy', 'ロマンス・ファンタジー', '로맨스 판타지'),
        'isekai': ('異世界', '异世界', 'Isekai', '異世界', '이세계'),
        'children': ('兒童奇幻', '儿童奇幻', "Children's Fantasy", '児童ファンタジー', '아동 판타지'),
        'classic': ('古典奇幻', '古典奇幻', 'Classic Fantasy', '古典ファンタジー', '고전 판타지'),
        'shenmo': ('神魔', '神魔', 'Gods & Demons', '神魔小説', '신마 소설'),
        'science-fantasy': ('科學奇幻', '科学奇幻', 'Science Fantasy', 'サイエンス・ファンタジー', '사이언스 판타지'),
        'xuanhuan': ('玄幻', '玄幻', 'Xuanhuan', '玄幻', '현환'),
    },
    'wuxia': {
        'jinyong': ('金庸', '金庸', 'Jin Yong', '金庸', '김용'),
        'gulong': ('古龍', '古龙', 'Gu Long', '古龍', '고룡'),
        'liangyusheng': ('梁羽生', '梁羽生', 'Liang Yusheng', '梁羽生', '양우생'),
        'huangyi': ('黃易', '黄易', 'Huang Yi', '黄易', '황이'),
        'xianxia': ('仙俠', '仙侠', 'Xianxia', '仙侠', '선협'),
        'edo': ('江戶時代', '江户时代', 'Edo Period', '江戸時代', '에도 시대'),
    },
    'horror': {
        'vampires': ('吸血鬼', '吸血鬼', 'Vampires', '吸血鬼', '뱀파이어'),
        'ghosts': ('鬼故事', '鬼故事', 'Ghosts', '幽霊', '유령'),
        'demons': ('惡魔', '恶魔', 'Demons', '悪魔', '악마'),
        'zombies': ('殭屍', '僵尸', 'Zombies', 'ゾンビ', '좀비'),
        'werewolves': ('狼人', '狼人', 'Werewolves', '人狼', '늑대인간'),
        'psychological': ('心理恐怖', '心理恐怖', 'Psychological Horror', '心理ホラー', '심리 호러'),
        'lovecraftian': ('克蘇魯', '克苏鲁', 'Lovecraftian Horror', 'クトゥルフ', '러브크래프트 호러'),
        'young-adult': ('青少年恐怖', '青少年恐怖', 'Young Adult Horror', 'ヤングアダルト・ホラー', '청소년 호러'),
        'short-stories': ('恐怖短篇', '恐怖短篇', 'Horror Short Stories', 'ホラー短編', '호러 단편'),
        'american': ('美國驚悚', '美国惊悚', 'American Thrillers', 'アメリカのスリラー', '미국 스릴러'),
        'dark-tower': ('黑塔', '黑塔', 'The Dark Tower', 'ダーク・タワー', '다크 타워'),
        'top': ('高分恐怖', '高分恐怖', 'Top-Rated Horror', '高評価のホラー', '평점 높은 호러'),
    },
    'history': {
        'middle-ages': ('中世紀', '中世纪', 'Middle Ages', '中世', '중세'),
        'alternate': ('架空歷史', '架空历史', 'Alternate History', '歴史改変', '대체 역사'),
        'antiquity': ('古代', '古代', 'Antiquity', '古代', '고대'),
        'early-modern': ('近代早期', '近代早期', 'Early Modern', '近世', '근세'),
        'family-saga': ('家族史詩', '家族史诗', 'Family Sagas', '大河小説', '가족 대하소설'),
        'biographical': ('傳記小說', '传记小说', 'Biographical Novels', '伝記小説', '전기 소설'),
        'war': ('戰爭', '战争', 'War', '戦争', '전쟁'),
        'cold-war': ('冷戰', '冷战', 'Cold War', '冷戦', '냉전'),
        'top': ('高分歷史小說', '高分历史小说', 'Top-Rated Historical Fiction', '高評価の歴史小説', '평점 높은 역사 소설'),
    },
    'youth': {
        'fantasy': ('青少年奇幻', '青少年奇幻', 'Young Adult Fantasy', 'YAファンタジー', '청소년 판타지'),
        'scifi': ('青少年科幻', '青少年科幻', 'Young Adult Science Fiction', 'YA SF', '청소년 SF'),
        'romance': ('青少年愛情', '青少年爱情', 'Young Adult Romance', 'YAロマンス', '청소년 로맨스'),
        'horror': ('青少年恐怖', '青少年恐怖', 'Young Adult Horror', 'YAホラー', '청소년 호러'),
        'mystery': ('青少年推理', '青少年推理', 'Young Adult Mystery', 'YAミステリー', '청소년 미스터리'),
        'lgbtq': ('多元性別', '多元性别', 'LGBTQ+', 'LGBTQ+', 'LGBTQ+'),
        'spy': ('少年間諜', '少年间谍', 'Junior Spies', '少年スパイ', '소년 스파이'),
        'high-school': ('高中', '高中', 'High School', '高校', '고등학교'),
        'university': ('大學', '大学', 'University', '大学', '대학'),
        'junior-high': ('國中', '初中', 'Middle School', '中学校', '중학교'),
        'elementary': ('小學', '小学', 'Elementary School', '小学校', '초등학교'),
        'teachers': ('教師', '教师', 'Teachers', '教師', '교사'),
        'magic-school': ('魔法學校', '魔法学校', 'Magic School', '魔法学校', '마법 학교'),
        'campus': ('校園', '校园', 'Campus', '学園', '캠퍼스'),
        'coming-of-age': ('青春', '青春', 'Coming of Age', '青春', '청춘'),
    },
}
# The regions each wiki's subgenres are drawn for.
WIKI_REGIONS = {'zh': ['zh-Hant', 'zh-Hans'], 'ja': ['ja'], 'en': ['en']}
SUBGENRE = ('子類型', '子类型', 'Subgenre', 'サブジャンル', '하위 장르')
# The history genre is 歷史小說: Open Library's 歷史 is nonfiction.
HISTORY = ('歷史小說', '历史小说', 'Historical Fiction', '歴史小説', '역사 소설')
FICTION = ('小說與文學', '小说与文学', 'Fiction & Literature', '小説・文学', '소설 및 문학')
FICTION_LIST = ('清單', '清单', 'List', 'リスト', '목록')
# 小說與文學's store: the region's own lists, then its genres as shelves.
FICTION_STORE = [('heroCards', 'today'), ('multiRow', 'month'), ('heroGrid', 'year'), ('largeRow', 'completed'),
                 ('colorBand', 'classics')]


def write_trends():
    module = json.loads(TRENDS.read_text())
    subgenres = trends_subgenres()
    lists = {entry['id']: entry for entry in module['modules']}
    region = lists['month']['params'][0]
    genres = [entry for entry in module['modules'] if entry['id'].startswith('genre-')]
    for entry in genres:
        genre = entry['id'].removeprefix('genre-')
        names = SUBGENRE_NAMES[genre]
        order, regions = [], {}
        for wiki in ('en', 'zh', 'ja'):
            for sub in subgenres[genre].get(wiki, {}):
                if sub not in regions:
                    order.append(sub)
                regions.setdefault(sub, []).extend(WIKI_REGIONS[wiki])
        # A subgenre is offered only in the regions whose lists have it: picked in another, its
        # file does not exist (the host draws a subgenre from its wiki's categories alone).
        every = [option['value'] for option in region['enumOptions']]
        def option(sub):
            said = {'title': names[sub][0], 'value': f'-{sub}'}
            if sorted(regions[sub]) != sorted(every):
                said['belongTo'] = {'paramName': 'region', 'value': regions[sub]}
            return said
        subgenre = {'name': 'subgenre', 'title': SUBGENRE[0], 'type': 'enumeration', 'value': '',
                    'enumOptions': [{'title': ALL[0], 'value': ''}] + [option(sub) for sub in order]}
        entry['params'] = [param for param in entry['params'] if param['name'] != 'subgenre']
        entry['params'].insert(1, subgenre)
        entry['request']['url'] = f'https://gateway.yuedureader.com/trends/v1/{{{{region}}}}/genre-{genre}{{{{subgenre}}}}-{{{{window}}}}.json'
        entry['store'] = [section for section in entry['store'] if 'shelves' not in section]
        entry['store'].append({'layout': 'groupedShelves', 'shelves': [
            {'params': {'subgenre': f'-{sub}'}, 'belongTo': {'paramName': 'region', 'value': regions[sub]}} for sub in order]})
        if genre == 'history':
            entry['title'] = HISTORY[0]
        for index, language in enumerate(LANGUAGES, start=1):
            said = module['localizations'][language]['entries'][entry['id']]
            said['params']['subgenre'] = {'title': SUBGENRE[index],
                                          'options': {'': ALL[index], **{f'-{sub}': names[sub][index] for sub in order}}}
            if genre == 'history':
                said['title'] = HISTORY[index]
    windows = [(name, lists[name]['title']) for _, name in FICTION_STORE]
    fiction = {
        'id': 'fiction', 'title': FICTION[0], 'cacheDuration': 86400,
        'params': [region, {'name': 'list', 'title': FICTION_LIST[0], 'type': 'enumeration', 'value': 'month',
                            'enumOptions': [{'title': title, 'value': name} for name, title in windows]}],
        'request': {**lists['month']['request'],
                    'url': 'https://gateway.yuedureader.com/trends/v1/{{region}}/{{list}}.json'},
        'list': lists['month']['list'],
        'store': [{'layout': layout, 'params': {'list': name}} for layout, name in FICTION_STORE]
                 + [{'layout': 'groupedShelves', 'shelves': [{'list': entry['id']} for entry in genres]}],
    }
    module['modules'] = [entry for entry in module['modules'] if entry['id'] != 'fiction']
    module['modules'].insert(module['modules'].index(genres[0]), fiction)
    for index, language in enumerate(LANGUAGES, start=1):
        entries = module['localizations'][language]['entries']
        entries['fiction'] = {'title': FICTION[index], 'params': {
            'region': entries['month']['params']['region'],
            'list': {'title': FICTION_LIST[index], 'options': {name: entries[name]['title'] for _, name in FICTION_STORE}}}}
    module['version'] = '1.3'
    save(TRENDS, module)


# MARK: - Bangumi

COMICS = ('漫畫與圖畫小說', '漫画与图画小说', 'Comics & Graphic Novels', 'コミック・グラフィックノベル', '만화 및 그래픽 노블')
# Bangumi's manga tags, a shelf each: Bangumi's tags are written in simplified Chinese.
COMIC_TAGS = [
    ('恋爱', ('戀愛', '恋爱', 'Romance', '恋愛', '연애')),
    ('奇幻', ('奇幻', '奇幻', 'Fantasy', 'ファンタジー', '판타지')),
    ('热血', ('熱血', '热血', 'Action', '熱血', '열혈')),
    ('搞笑', ('搞笑', '搞笑', 'Comedy', 'ギャグ', '개그')),
    ('悬疑', ('懸疑', '悬疑', 'Mystery', 'サスペンス', '미스터리')),
    ('科幻', ('科幻', '科幻', 'Science Fiction', 'SF', 'SF')),
    ('校园', ('校園', '校园', 'School', '学園', '학원')),
    ('运动', ('運動', '运动', 'Sports', 'スポーツ', '스포츠')),
    ('日常', ('日常', '日常', 'Slice of Life', '日常', '일상')),
    ('百合', ('百合', '百合', 'Yuri', '百合', '백합')),
]
COMIC_SORTS = [('heat', ('熱門', '热门', 'Popular', '人気', '인기')), ('rank', ('高分', '高分', 'Top Rated', '高評価', '높은 평점'))]
TAG = ('標籤', '标签', 'Tag', 'タグ', '태그')


def write_bangumi():
    module = json.loads(BANGUMI.read_text())
    manga = next(entry for entry in module['modules'] if entry['id'] == 'manga-rank')
    comics = {
        'id': 'comics', 'title': COMICS[0], 'cacheDuration': 86400, 'contentKind': 'comic',
        'params': [
            {'name': 'tag', 'title': TAG[0], 'type': 'enumeration', 'value': '漫画',
             'enumOptions': [{'title': ALL[0], 'value': '漫画'}] + [{'title': names[0], 'value': tag} for tag, names in COMIC_TAGS]},
            {'name': 'sort', 'title': SORT[0], 'type': 'enumeration', 'value': 'heat',
             'enumOptions': [{'title': names[0], 'value': value} for value, names in COMIC_SORTS]},
            {'name': 'offset', 'type': 'offset'},
        ],
        'request': {'url': 'https://api.bgm.tv/v0/search/subjects?limit=20&offset={{offset}}', 'method': 'POST',
                    'bodyEncoding': 'json',
                    'body': '{"keyword":"","sort":"{{sort}}","filter":{"type":[1],"tag":["{{tag}}"],'
                            '"meta_tags":["漫画"],"rank":[">0"],"nsfw":false}}',
                    'headers': {**manga['request']['headers'], 'Content-Type': 'application/json'}},
        'list': manga['list'], 'excludeTags': manga['excludeTags'],
        'store': [{'layout': 'heroCards', 'params': {'sort': 'heat'}}, {'layout': 'heroGrid', 'params': {'sort': 'rank'}},
                  {'layout': 'groupedShelves', 'shelves': [{'params': {'tag': tag}} for tag, _ in COMIC_TAGS]}],
    }
    module['modules'] = [entry for entry in module['modules'] if entry['id'] != 'comics'] + [comics]
    module['version'], module['requiredVersion'] = '1.1', '3.0.2'
    for index, language in enumerate(LANGUAGES, start=1):
        module.setdefault('localizations', {}).setdefault(language, {}).setdefault('entries', {})['comics'] = {
            'title': COMICS[index], 'params': {
                'tag': {'title': TAG[index], 'options': {'漫画': ALL[index], **{tag: names[index] for tag, names in COMIC_TAGS}}},
                'sort': {'title': SORT[index], 'options': {value: names[index] for value, names in COMIC_SORTS}}}}
    save(BANGUMI, module)


def write():
    write_trends()
    write_bangumi()
    write_openlibrary()


if __name__ == '__main__':
    probe() if '--probe' in sys.argv else write()
