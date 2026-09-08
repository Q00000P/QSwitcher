#!/usr/bin/env python3
"""Полный перебор коллизий по словарям приложения — без выдумок.

Для каждого слова из ru.txt берём свап клавиш и проверяем в en.txt (и наоборот).
Всё, что нашлось, — коллизия обычных слов: одни и те же клавиши читаются как
слово в обоих языках. Это исчерпывающий класс A; ИИ нужен только для того, что
перебором не взять, — сокращений и имён.

Слишком редкие чтения отсекаем по корпусу: слово, которого в 34 млн строк нет,
в тест брать бессмысленно.

    python3 nn/sem/scan_collisions.py --min-len 2 --max-len 5 --min-n 200
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
        m = RU_TO_EN.get(ch) or EN_TO_RU.get(ch)
        if not m: return None
        out.append(m)
    return "".join(out)

def load_dict(name):
    for base in (os.path.join(HERE, "..", "..", "Sources", "QSwitcher", "Resources"),
                 os.path.expanduser("~/dev/QSwitcher/QSwitcher.app/Contents/Resources")):
        f = os.path.join(base, name)
        if os.path.exists(f):
            return {w.strip().lower() for w in open(f, encoding="utf-8", errors="ignore") if w.strip()}
    sys.exit(f"нет словаря {name} — собери приложение")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "collisions-scan.tsv"))
    ap.add_argument("--corpus", default=CORPUS)
    ap.add_argument("--min-len", type=int, default=2)
    ap.add_argument("--max-len", type=int, default=5)
    ap.add_argument("--min-n", type=int, default=200, help="минимум вхождений КАЖДОГО чтения в корпусе")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    ru, en = load_dict("ru.txt"), load_dict("en.txt")
    print(f"словари: ru={len(ru):,}, en={len(en):,}")
    pairs = set()
    for w in ru:
        if not (a.min_len <= len(w) <= a.max_len): continue
        s = swap(w)
        if s and s in en: pairs.add((w, s))
    for w in en:
        if not (a.min_len <= len(w) <= a.max_len): continue
        s = swap(w)
        if s and s in ru: pairs.add((s, w))
    print(f"коллизий по словарям: {len(pairs):,}")

    need = {w for p in pairs for w in p}
    n = defaultdict(int)
    seen = 0
    for line in open(a.corpus, encoding="utf-8", errors="ignore"):
        seen += 1
        if a.limit and seen > a.limit: break
        if seen % 5000000 == 0: print(f"  строк {seen:,}", flush=True)
        for t in TOKEN.findall(line):
            lt = t.lower()
            if lt in need: n[lt] += 1

    keep = sorted((p for p in pairs if n[p[0]] >= a.min_n and n[p[1]] >= a.min_n),
                  key=lambda p: -min(n[p[0]], n[p[1]]))
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("клавиши_EN\tчтение_RU\tчтение_EN\tтип_RU\tтип_EN\tкомментарий\n")
        for r, e in keep:
            f.write(f"{e}\t{r}\t{e}\tслово\tслово\tперебор словарей; n={n[r]}/{n[e]}\n")
    print(f"\nосталось после порога {a.min_n}: {len(keep):,} → {a.out}")
    for r, e in keep[:40]: print(f"  {r}/{e}  n={n[r]}/{n[e]}")

if __name__ == "__main__":
    main()
