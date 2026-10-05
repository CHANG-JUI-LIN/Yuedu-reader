# TXT codec fixtures

`generate.py` creates original Aozora-style prose using Python `cp932`, `euc_jp`,
`gbk`, `gb18030`, `big5`, and `euc_kr` codecs. The `.txt` files contain actual
encoded bytes; `.utf8` files are exact expected decoded text. CP932 includes NEC
extensions, EUC-JP includes halfwidth kana and a JIS X 0212 supplementary character,
and GB18030 includes four-byte characters. No network is needed for tests.

`aozora-neko-jijo.txt` is the unmodified public-domain Aozora Bunko download of
Natsume Soseki's *『吾輩は猫である』中篇自序*. The original credits are retained.

- Card: https://www.aozora.gr.jp/cards/000148/card2671.html
- Archive: https://www.aozora.gr.jp/cards/000148/files/2671_ruby_6335.zip
- ZIP entry: `neko_chuhen.txt`, 5,772 bytes, Shift_JIS
- Downloaded: 2026-10-05
- SHA-256: `9bcd576a96eeaeda9d96c738009b23d4024549514e69b9e4ca4fc884cc83ce65`

The full novel was also checked outside the test bundle:
https://www.aozora.gr.jp/cards/000148/files/789_ruby_5639.zip,
entry `wagahaiwa_nekodearu.txt`, 749,051 bytes,
SHA-256 `f8c511ab3e69e3a1ccfea475783c2e4d64917a2cdedfb67441ea27655aca5f75`.

Both real downloads previously selected GB18030. The original generated CP932
fixture did too; EUC-JP failed whole-file decoding, and Big5 selected GB18030.
