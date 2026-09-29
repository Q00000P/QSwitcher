#!/usr/bin/env python3
"""Регистр коротких токенов (2–6 букв) по сырым текстам: сколько раз слово встретилось
ВСЕГО и сколько раз ЦЕЛИКОМ ЗАГЛАВНЫМИ. Нужно, чтобы отличать аббревиатуры (UI, IP, РФ)
от обычных слов. Выход: data/caps-<имя>.tsv (слово \t всего \t капсом)."""
import collections, gzip, html, os, re, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
D = os.path.join(HERE, '..', 'sem', 'data')
name, limit = sys.argv[1], int(sys.argv[2])
TOK = re.compile(r'(?<![A-Za-zА-Яа-яЁё0-9])([A-Za-z]{1,6}|[А-Яа-яЁё]{1,6})(?![A-Za-zА-Яа-яЁё0-9])')
def lines():
    if name.startswith('se-'):
        rx = re.compile(r' Body="([^"]*)"')
        with open(os.path.join(D, name, 'Posts.xml'), encoding='utf-8', errors='ignore') as f:
            for l in f:
                m = rx.search(l)
                if m:
                    t = html.unescape(m.group(1))
                    t = re.sub(r'<code>.*?</code>', ' ', t, flags=re.S)
                    yield re.sub(r'<[^>]+>', ' ', t)
    else:
        with gzip.open(os.path.join(D, name + '.gz'), 'rt', encoding='utf-8', errors='ignore') as f:
            yield from f
tot = collections.Counter(); caps = collections.Counter(); n = 0; t0 = time.time()
for l in lines():
    for w in TOK.findall(l):
        lw = w.lower(); tot[lw] += 1
        if len(w) >= 2 and w.isupper(): caps[lw] += 1
    n += 1
    if n >= limit or time.time()-t0 > float(os.environ.get("QS_DEADLINE","150")): break
    if n % 1000000 == 0: print(name, f'{n:,}', f'{time.time()-t0:.0f}c', flush=True)
with open(os.path.join(HERE, 'data', f'caps-{name}.tsv'), 'w', encoding='utf-8') as o:
    for w, c in tot.most_common():
        if c >= 2: o.write(f'{w}\t{c}\t{caps.get(w, 0)}\n')
print(name, 'готово', n, 'строк', f'{time.time()-t0:.0f}c', flush=True)
