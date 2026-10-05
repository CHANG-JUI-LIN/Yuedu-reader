"""Reproducible original Aozora-style text, encoded by Python's real codecs."""
from pathlib import Path
root = Path(__file__).parent
japanese = ('夏の読書\n\n　私は｜漢字《かんじ》の読み方を調べた。\n'
            '　静かな図書館《としょかん》で、あいうえお、カタカナ、「日本語」を読む。\n'
            '　［＃ここから二字下げ］窓の外には山と川があり、子どもたちの声が聞こえる。［＃改ページ］\n'
            '　これは青空文庫の形式を使った、文字コードと注音の検証用の文章です。\n') * 24
samples = {
 'aozora-cp932': (japanese + '　NEC拡張文字：①②③、ⅠⅡⅢ、㍉、㈱。\n', 'cp932'),
 'aozora-euc-jp': (japanese + '　半角カナ：ｱｲｳ。補助漢字：丂。\n', 'euc_jp'),
 'simplified-gbk': (('第一章 阅读\n　这个世界的故事从今天开始，我们一起看书，学习生活中的知识。\n'
                    '　他说，这里的时间和事情都很重要，大家可以用自己的方法发现新的问题。\n') * 80, 'gbk'),
 'simplified-gb18030': (('第一章 阅读\n　我们一起学习新的知识，这是一个关于生活和时间的故事。\n') * 80 + '　扩展字符：𠀀、😀。\n', 'gb18030'),
 'traditional-big5': (('第一章 閱讀\n　這個世界的故事從今天開始，我們一起看書，學習生活中的知識。\n'
                     '　他說，這裡的時間和事情都很重要，大家可以用自己的方法發現新的問題。\n') * 80, 'big5'),
 'korean-euc-kr': (('첫 번째 이야기\n　오늘은 도서관에서 책을 읽고 새로운 이야기를 배웠습니다.\n'
                    '　사람들은 함께 살아가며 서로의 생각을 나누고 우리나라의 문화를 이야기합니다.\n') * 80, 'euc_kr'),
}
for name,(text,encoding) in samples.items():
 (root / (name + '.txt')).write_bytes(text.encode(encoding))
 (root / (name + '.utf8')).write_bytes(text.encode('utf-8'))
