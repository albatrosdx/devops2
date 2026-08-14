#!/usr/bin/env python3
"""Noto Sans JP から jsPDF 用の日本語フォント静的リソースを生成する。

静的リソースは1ファイル5MBが上限のため、全CJK(約2万字)をそのまま埋め込むと
base64換算で約5.6MBとなり上限を超える。ここでは JIS X 0208(第一・第二水準)
相当の文字集合に絞り込むことで、base64で約2.9MBに収める。

文字集合は Python 標準の cp932 コーデックから機械的に導出しているため、
外部の文字リストに依存せず、何度実行しても同じ結果になる。

前提:
    pip install fonttools brotli

使い方:
    python3 scripts/font/build-japanese-font.py

出力:
    force-app/main/default/staticresources/NotoSansJPNormal.js

ライセンス:
    Noto Sans JP は SIL Open Font License 1.1 のため再配布可能。
"""

import base64
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

FONT_URL = (
    "https://github.com/google/fonts/raw/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf"
)
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = REPO_ROOT / "force-app/main/default/staticresources/NotoSansJPNormal.js"
STATIC_RESOURCE_LIMIT = 5 * 1024 * 1024


def build_charset() -> str:
    """JIS X 0208(第一・第二水準) + ASCII + 一部記号の文字集合を返す。"""
    chars = set()
    for hi in range(0x81, 0xF0):
        for lo in range(0x40, 0xFD):
            try:
                decoded = bytes([hi, lo]).decode("cp932")
            except UnicodeDecodeError:
                continue
            if len(decoded) == 1:
                chars.add(decoded)
    # ASCII と、見積書で使う通貨・番号記号
    for code_point in list(range(0x20, 0x7F)) + [0xA5, 0x20AC, 0x2116]:
        chars.add(chr(code_point))
    return "".join(sorted(chars))


def main() -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = pathlib.Path(tmpdir)
        variable_font = tmp / "NotoSansJP-VF.ttf"
        static_font = tmp / "NotoSansJP-400.ttf"
        subset_font = tmp / "NotoSansJP-subset.ttf"
        charset_file = tmp / "charset.txt"

        print(f"ダウンロード中: {FONT_URL}")
        urllib.request.urlretrieve(FONT_URL, variable_font)

        # 可変フォントを Regular(wght=400) の静的フォントに固定する
        print("wght=400 のインスタンスを生成中...")
        subprocess.run(
            [
                sys.executable, "-m", "fontTools.varLib.instancer",
                str(variable_font), "wght=400", "-o", str(static_font),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )

        charset = build_charset()
        charset_file.write_text(charset, encoding="utf-8")
        print(f"文字集合: {len(charset)} 字")

        print("サブセット化中...")
        subprocess.run(
            [
                sys.executable, "-m", "fontTools.subset",
                str(static_font),
                f"--text-file={charset_file}",
                f"--output-file={subset_font}",
                "--layout-features=",
                "--no-hinting",
                "--drop-tables+=GSUB,GPOS,GDEF",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )

        encoded = base64.b64encode(subset_font.read_bytes()).decode("ascii")

    contents = (
        "/* Noto Sans JP (Regular) — JIS X 0208 サブセット。SIL Open Font License 1.1。\n"
        " * scripts/font/build-japanese-font.py で生成。手で編集しないこと。 */\n"
        f'window.NotoSansJPNormal = "{encoded}";\n'
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(contents, encoding="utf-8")

    size = OUTPUT.stat().st_size
    print(f"生成: {OUTPUT.relative_to(REPO_ROOT)}  {size / 1024 / 1024:.2f} MB")
    if size >= STATIC_RESOURCE_LIMIT:
        print("エラー: 静的リソースの5MB上限を超えています。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
