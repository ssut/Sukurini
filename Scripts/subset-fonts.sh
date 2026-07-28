#!/usr/bin/env bash
# Rebuild docs/fonts/*.woff2 from the exact characters the site uses.
#
# The subsets are cut to the page's real glyph demand, so ANY copy change in
# docs/index.html or docs/i18n.js needs this re-run — otherwise the new
# characters silently render in a fallback face.
#
#   pip install fonttools brotli zopfli
#   Scripts/subset-fonts.sh
#
# Source fonts are downloaded into vendor-fonts/ (gitignored). Only the
# subset woff2 files under docs/fonts/ are committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor-fonts"
OUT="$ROOT/docs/fonts"
mkdir -p "$SRC" "$OUT"

fetch() {
  local url="$1" dest="$SRC/$2"
  [ -f "$dest" ] && return 0
  echo "fetch source=$2"
  curl -fsSL "$url" -o "$dest"
}

fetch "https://github.com/vercel/geist-font/raw/main/fonts/Geist/ttf/Geist%5Bwght%5D.ttf" "Geist[wght].ttf"
fetch "https://github.com/poposnail61/min-sans/raw/main/fonts/variable/MinSansVF.ttf" "MinSansVF.ttf"
fetch "https://github.com/google/fonts/raw/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf" "NotoSansJP[wght].ttf"
fetch "https://github.com/JetBrains/JetBrainsMono/raw/master/fonts/variable/JetBrainsMono%5Bwght%5D.ttf" "JetBrainsMono[wght].ttf"

python3 - "$ROOT" <<'PY'
import html as H, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
docs = root / "docs"

page = (docs / "index.html").read_text(encoding="utf-8")
page = re.sub(r"<(script|style)\b.*?</\1>", " ", page, flags=re.S | re.I)
attrs = " ".join(re.findall(r'(?:alt|title|aria-label|placeholder|content)="([^"]*)"', page))
text = H.unescape(re.sub(r"<[^>]*>", " ", page) + " " + attrs)
text += " " + (docs / "i18n.js").read_text(encoding="utf-8")
text += " " + (docs / "app.js").read_text(encoding="utf-8")

chars = set(text) - set("\n\r\t")
chars |= set(map(chr, range(0x20, 0x7F)))
chars |= set("—–·×⌘⇧…“”‘’°→←•™©®⌄✓№")

def emit(name, keep):
    picked = "".join(sorted(c for c in chars if keep(ord(c))))
    (root / (".chars-%s.txt" % name)).write_text(picked, encoding="utf-8")
    print("glyphs set=%s count=%d" % (name, len(picked)))

emit("latin", lambda o: o < 0x2E80)
emit("ko", lambda o: 0x1100 <= o <= 0x11FF or 0x3130 <= o <= 0x318F
                     or 0xA960 <= o <= 0xA97F or 0xAC00 <= o <= 0xD7A3)
emit("ja", lambda o: 0x3000 <= o <= 0x30FF or 0x31F0 <= o <= 0x31FF
                     or 0x4E00 <= o <= 0x9FFF or 0xFF00 <= o <= 0xFFEF)
PY

cut() {
  pyftsubset "$SRC/$1" \
    --text-file="$ROOT/.chars-$2.txt" \
    --output-file="$OUT/$3" \
    --flavor=woff2 --layout-features="$4" \
    --no-hinting --desubroutinize --drop-tables+=DSIG
  printf 'subset file=%-22s bytes=%s\n' "$3" "$(wc -c < "$OUT/$3" | tr -d ' ')"
}

cut "Geist[wght].ttf"                latin geist-latin.woff2    'ccmp,locl,kern,liga,calt,tnum,case,frac,sups'
cut "MinSansVF.ttf"                  ko    minsans-ko.woff2     'ccmp,locl,kern,calt'
cut "NotoSansJP[wght].ttf"           ja    notosansjp-ja.woff2  'ccmp,locl,kern,palt'
cut "JetBrainsMono[wght].ttf"        latin jetbrainsmono.woff2  'ccmp,locl,kern,calt'

# The product name is written in katakana even on the English and Korean pages.
# A 2 KB cut keeps those readers from pulling the whole Japanese face.
printf '\u30b9\u30af\u30ea\u30fc\u30cb\u30fc' > "$ROOT/.chars-brand.txt"
cut "NotoSansJP[wght].ttf"            brand brandkana.woff2      'ccmp,kern'

rm -f "$ROOT"/.chars-*.txt
echo "fonts status=ok total=$(du -sk "$OUT" | cut -f1)KB"
