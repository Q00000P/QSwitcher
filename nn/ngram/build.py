#!/usr/bin/env python3
"""Языковая модель на словных n-граммах для QSwitcher.

Зачем: семантика бессильна на двухбуквенных («he»/«ру», «lf»/«да») — у таких
токенов нет темы. Зато у них есть соседи: «да ... конечно» встречается в русском
корпусе постоянно, «lf ... конечно» — никогда. Модель отвечает ровно на это.

Вход: nn/sem/data/corpus.txt (по документу на строку, языки вперемешку — строки
параллельного корпуса содержат и русский, и английский). Разрезаем каждую строку
на однородные по алфавиту куски и учим ДВЕ модели: ru и en.

Выход: nn/ngram/qsngram.bin, формат QSNG2 — хэш-таблицы униграмм и биграмм:
запись 3 байта = 16-битный отпечаток (второй хэш, чтобы чужая корзина отвечала
«не видели», а не чужим числом) + −logP в uint8 шагами 0.1 ната. Читается один раз в память, лукап — сложение
двух хэшей, микросекунды, одинаково на любой машине.

    python3 nn/ngram/build.py                 (~55 МБ)
    python3 nn/ngram/build.py --bi-bits 22 --min-bi 5   (~30 МБ, реже пары)
    python3 nn/ngram/build.py --score "да ? конечно" --pair lf/да
"""
import argparse, math, os, re, struct, sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "..", "sem", "data", "corpus.txt")
OUT = os.path.join(HERE, "qsngram.bin")

CYR = re.compile(r"[а-яёА-ЯЁ]")
LAT = re.compile(r"[a-zA-Z]")
TOKEN = re.compile(r"[а-яёa-z0-9]+", re.I)

def fnv1a(s: str) -> int:
    h = 0x811C9DC5
    for b in s.encode("utf-8"):
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h

def fp16(s: str) -> int:
    """Отпечаток — FNV-1a от строки с солью, старшие 16 бит; 0 зарезервирован под «пусто»."""
    h = fnv1a("\x01" + s + "\x02") >> 16
    return h or 1

def lang_of(tok: str) -> str:
    if CYR.search(tok): return "ru"
    if LAT.search(tok): return "en"
    return ""          # цифры — общие, идут в оба

def runs(line: str):
    """Строка → последовательности токенов одного алфавита."""
    cur, lang = [], ""
    for m in TOKEN.finditer(line.lower()):
        t = m.group(0)
        l = lang_of(t)
        if l == "" and cur:
            cur.append(t); continue
        if l != lang and cur:
            yield lang, cur; cur = []
        lang = l or lang
        if lang: cur.append(t)
    if cur and lang: yield lang, cur

def count(corpus, limit):
    uni = {"ru": Counter(), "en": Counter()}
    bi  = {"ru": Counter(), "en": Counter()}
    tot = {"ru": 0, "en": 0}
    n = 0
    with open(corpus, encoding="utf-8", errors="ignore") as f:
        for line in f:
            n += 1
            if limit and n > limit: break
            if n % 500000 == 0: print(f"  строк {n:,}", flush=True)
            for lang, toks in runs(line):
                if len(toks) < 2: continue
                u, b = uni[lang], bi[lang]
                prev = "<s>"
                for t in toks:
                    u[t] += 1; b[(prev, t)] += 1; prev = t
                    tot[lang] += 1
                b[(prev, "</s>")] += 1
    return uni, bi, tot

def slots(key, mask):
    """Две корзины на ключ: основная и запасная (второй хэш). Ищем в обеих."""
    a = fnv1a(key) & mask
    b = fnv1a("\x03" + key) & mask
    return (a, b) if b != a else (a, (a + 1) & mask)

def put(table, mask, key, v):
    """Запись 3 байта: fp16 LE + значение. Занятые корзины не трогаем — вызывающий
    кладёт n-граммы по убыванию частоты, так что первым пришёл = самый частый."""
    fp = fp16(key)
    for slot in slots(key, mask):
        i = slot * 3
        cur = table[i] | (table[i + 1] << 8)
        if cur == 0 or cur == fp:
            table[i] = fp & 0xFF; table[i + 1] = fp >> 8; table[i + 2] = v
            return 0
    return 1

def pack(uni, bi, tot, uni_bits, bi_bits, min_uni, min_bi):
    umask, bmask = (1 << uni_bits) - 1, (1 << bi_bits) - 1
    blobs = {}
    for lang in ("ru", "en"):
        ua = bytearray((umask + 1) * 3); ba = bytearray((bmask + 1) * 3)
        T = max(1, tot[lang])
        nu = nb = lu = lb = 0
        # По убыванию счётчика: если корзин не хватает, теряются самые редкие.
        for w, c in sorted(uni[lang].items(), key=lambda kv: -kv[1]):
            if c < min_uni: break
            v = min(255, max(1, int(-math.log(c / T) * 10)))
            lu += put(ua, umask, w, v); nu += 1
        for (p, w), c in sorted(bi[lang].items(), key=lambda kv: -kv[1]):
            if c < min_bi: break
            pc = uni[lang].get(p, 0) or (T if p == "<s>" else 0)
            if not pc: continue
            v = min(255, max(1, int(-math.log(c / pc) * 10)))
            lb += put(ba, bmask, p + "\x1f" + w, v); nb += 1
        blobs[lang] = (bytes(ua), bytes(ba))
        print(f"  {lang}: токенов {T:,}; слов {nu:,} в {umask+1:,} корзин (потеряно {lu:,}); "
              f"пар {nb:,} в {bmask+1:,} корзин (потеряно {lb:,}, заполнение {nb/(bmask+1):.2f})")
        if lb: print(f"    потерянные — самые редкие; меньше потерь: --bi-bits {bi_bits+1} или --min-bi {min_bi+1}")
    return blobs

def write(path, blobs, uni_bits, bi_bits):
    import json
    head = json.dumps({"v": 2, "uni_bits": uni_bits, "bi_bits": bi_bits, "entry": 3, "ways": 2,
                       "langs": ["ru", "en"], "scale": 0.1}).encode("utf-8")
    with open(path, "wb") as f:
        f.write(b"QSNG2"); f.write(struct.pack("<I", len(head))); f.write(head)
        for lang in ("ru", "en"):
            ua, ba = blobs[lang]
            f.write(struct.pack("<II", len(ua), len(ba))); f.write(ua); f.write(ba)
    print(f"→ {path}  {os.path.getsize(path)/1e6:.1f} МБ")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=CORPUS)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--uni-bits", type=int, default=20)   # 3 МБ на язык
    ap.add_argument("--bi-bits", type=int, default=23)    # 25 МБ на язык
    ap.add_argument("--min-uni", type=int, default=2)
    ap.add_argument("--min-bi", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    if not os.path.exists(a.corpus):
        sys.exit(f"нет корпуса: {a.corpus} — сначала nn/sem/fetch_corpus.py")
    print("считаю n-граммы…", flush=True)
    uni, bi, tot = count(a.corpus, a.limit)
    print("пакую…", flush=True)
    write(a.out, pack(uni, bi, tot, a.uni_bits, a.bi_bits, a.min_uni, a.min_bi),
          a.uni_bits, a.bi_bits)

if __name__ == "__main__":
    main()
