#!/usr/bin/env python3
"""Прогон тестовых фраз (формат --test приложения) через новое ядро.

Строка: «[@место] слова … *цель* … => ожидание». Слова до цели решаются по очереди, как при
живом наборе; с --right слова после цели тоже набираются (отложенное решение коротких).
Итог — «верно / промолчал / испортил» и по длине слова.

    python3 nn/lm/eval_phrases.py nn/sem/scan-phrases.txt --char … --ngram … [--right]
"""
import argparse, collections, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Scorer, Decoder, Params, swap, lang_of, letters      # noqa

PLACE = {'terminal': 0.15, 'code': 0.2, 'address': 0.05, 'password': 0.02, 'chat': 0.8, 'browser': 0.6}

def parse(line):
    line = line.strip()
    if not line or line.startswith('#') or '=>' not in line: return None
    left, exp = line.rsplit('=>', 1)
    words = left.split(); tag = None
    if words and words[0].startswith('@'): tag = words[0][1:]; words = words[1:]
    ti = len(words) - 1
    for k, w in enumerate(words):
        if len(w) > 2 and w.startswith('*') and w.endswith('*'): words[k] = w[1:-1]; ti = k
    return tag, words, ti, exp.strip()

def run(path, dec, right=False, show=0):
    res = collections.Counter(); by = collections.defaultdict(collections.Counter); bad = []
    for raw in open(path, encoding='utf-8'):
        pr = parse(raw)
        if not pr: continue
        tag, words, ti, exp = pr
        dec.reset(prior_ru=PLACE.get(tag, 0.5))
        rs = []
        upto = len(words) if right else ti + 1
        for w in words[:upto]:
            T = lang_of(w)
            if not T: rs.append(None); continue
            r, _ = dec.step(w, T); rs.append(r)
        r = rs[ti]
        got = r.shown if r else words[ti]
        typed = words[ti]
        ok = got.lower() == exp.lower()
        t = 'верно' if ok else ('промолчал' if got == typed else 'испортил')
        res[t] += 1
        n = letters(typed, lang_of(typed) or 'en')
        by['длина ' + ('1' if n == 1 else '2' if n == 2 else '3' if n == 3 else '4-5' if n <= 5 else '6+')][t] += 1
        if not ok and len(bad) < show: bad.append((raw.strip(), got, r.explain if r else ''))
    return res, by, bad

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+')
    ap.add_argument('--char', required=True); ap.add_argument('--ngram', required=True)
    ap.add_argument('--right', action='store_true')
    ap.add_argument('--show', type=int, default=0)
    ap.add_argument('--set', action='append', default=[])
    a = ap.parse_args()
    p = Params()
    for kv in a.set:
        k, v = kv.split('='); setattr(p, k, type(getattr(p, k))(v))
    dec = Decoder(Scorer(a.char, a.ngram, p), p)
    for f in a.files:
        res, by, bad = run(f, dec, a.right, a.show)
        tot = sum(res.values())
        print(f"== {os.path.basename(f)}{' (+справа)' if a.right else ''}: {tot} строк — верно {res['верно']} "
              f"({100*res['верно']/max(1,tot):.1f}%), промолчал {res['промолчал']}, испортил {res['испортил']}")
        for k in sorted(by):
            c = by[k]; print(f"   {k:10s} верно {c['верно']:4d}  промолчал {c['промолчал']:4d}  испортил {c['испортил']:4d}")
        for line, got, ex in bad: print(f"   ✗ {line[:70]:70s} → {got!r:14s} | {ex[:150]}")
