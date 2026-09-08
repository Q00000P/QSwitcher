#!/usr/bin/env python3
"""Отсев выдуманных пар по достоверному признаку — словарям приложения.

Корпус лежит в нижнем регистре, поэтому «ЕЛ» (если это сокращение) и «ел»
(глагол) в нём неразличимы; статистика по нему сокращения не подтверждает —
она оставляет УЛ/EK и ЕЛ/TK и выбрасывает ТД/NL. Поэтому пары делим на два
честных класса:

  A — оба чтения есть в ru.txt / en.txt (коллизия обычных слов: он/he, мы/vs,
      шт/in). Это то, что детектор обязан решать контекстом.
  B — сокращения из белого списка nn/sem/abbrev.txt (по строке «РФ HA» —
      пара, которую пользователь реально пишет). Их немного, и они личные.

Остальное выбрасывается: пара, где одно чтение — слово, а другое обломок,
коллизией не является, детектор такое и так решает словарём.

    python3 nn/sem/filter_collisions.py --tsv nn/sem/collisions.tsv \
        --out nn/sem/collisions-clean.tsv
"""
import argparse, os, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "data", "corpus.txt")
TOKEN = re.compile(r"[а-яёa-z0-9]+", re.I)
RU_TO_EN = dict(zip("йцукенгшщзхъфывапролджэячсмитьбю", "qwertyuiop[]asdfghjkl;'zxcvbnm,."))
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}

def swap(w):
    out = []
    for ch in w:
        lo = ch.lower()
        m = RU_TO_EN.get(lo) or EN_TO_RU.get(lo)
        if not m: return None
        out.append(m)
    return "".join(out)

def load_dict(name):
    for base in (os.path.join(HERE, "..", "..", "Sources", "QSwitcher", "Resources"),
                 os.path.expanduser("~/dev/QSwitcher/QSwitcher.app/Contents/Resources")):
        f = os.path.join(base, name)
        if os.path.exists(f):
            return {w.strip().lower() for w in open(f, encoding="utf-8", errors="ignore") if w.strip()}
    return set()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", default=os.path.join(HERE, "collisions.tsv"))
    ap.add_argument("--abbrev", default=os.path.join(HERE, "abbrev.txt"),
                    help="белый список сокращений: по паре «РФ HA» в строке")
    ap.add_argument("--out", default=os.path.join(HERE, "collisions-clean.tsv"))
    a = ap.parse_args()

    ru_d, en_d = load_dict("ru.txt"), load_dict("en.txt")
    print(f"словари: ru={len(ru_d):,}, en={len(en_d):,}")
    if not ru_d or not en_d:
        sys.exit("словарей нет — собери приложение (./make-app.sh) или укажи путь")

    white = set()
    if os.path.exists(a.abbrev):
        for line in open(a.abbrev, encoding="utf-8"):
            p = line.split("#")[0].split()
            if len(p) == 2: white.add((p[0].lower(), p[1].lower()))
    print(f"белый список сокращений: {len(white)} пар ({a.abbrev})")

    pairs, raw = [], {}
    for line in open(a.tsv, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) < 3 or p[0] == "клавиши_EN": continue
        ru, en = p[1].strip(), p[2].strip()
        if swap(ru.lower()) != en.lower(): continue
        pairs.append((ru, en)); raw[(ru, en)] = line.rstrip("\n")

    keep, drop = [], []
    for ru, en in pairs:
        in_ru = ru.lower() in ru_d or ru.lower() in en_d
        in_en = en.lower() in ru_d or en.lower() in en_d
        if (ru.lower(), en.lower()) in white or (en.lower(), ru.lower()) in white:
            keep.append((ru, en, "B сокращение"))
        elif in_ru and in_en:
            keep.append((ru, en, "A оба слова"))
        else:
            miss = [w for w, ok in ((ru, in_ru), (en, in_en)) if not ok]
            drop.append((ru, en, "нет в словарях: " + ", ".join(miss)))

    with open(a.out, "w", encoding="utf-8") as f:
        f.write("клавиши_EN\tчтение_RU\tчтение_EN\tтип_RU\tтип_EN\tкомментарий\n")
        for ru, en, cls in keep: f.write(raw[(ru, en)] + f" [{cls}]\n")
    print(f"\nоставлено {len(keep)} → {a.out}")
    for ru, en, cls in keep: print(f"  ✅ {ru}/{en}  {cls}")
    print(f"\nотброшено {len(drop)}:")
    for ru, en, why in drop: print(f"  ✖ {ru}/{en}  {why}")

if __name__ == "__main__":
    main()
