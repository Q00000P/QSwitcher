#!/usr/bin/env python3
"""Частоты слов по языкам из nn/sem/data/corpus.txt (нижний регистр, токены через пробел).
Выход: data/words-ru.tsv, data/words-en.tsv  (слово \t счётчик, счётчик >= 2, по убыванию)."""
import collections, os, re, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(HERE, '..', 'sem', 'data', 'corpus.txt')
cnt = collections.Counter()
t0 = time.time(); n = 0
with open(src, encoding='utf-8', errors='ignore') as f:
    for line in f:
        cnt.update(line.split())
        n += 1
        if n % 2000000 == 0:
            print(f'{n:,} строк, {len(cnt):,} типов, {time.time()-t0:.0f} c', flush=True)
CYR = re.compile(r'^[а-яё]+(-[а-яё]+)*$'); LAT = re.compile(r"^[a-z]+(-[a-z]+)*$")
for lang, rx in (('ru', CYR), ('en', LAT)):
    items = sorted(((w, c) for w, c in cnt.items() if c >= 2 and rx.match(w)), key=lambda x: -x[1])
    with open(os.path.join(HERE, 'data', f'words-{lang}.tsv'), 'w', encoding='utf-8') as o:
        for w, c in items: o.write(f'{w}\t{c}\n')
    print(lang, len(items), 'типов, токенов', sum(c for _, c in items), flush=True)
print('готово', time.time()-t0)
