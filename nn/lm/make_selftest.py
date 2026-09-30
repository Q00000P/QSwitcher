#!/usr/bin/env python3
"""Эталон для самопроверки порта ядра (Swift/C#): те же входы → те же решения.

Пишет nn/lm/core5-selftest.json:
  "chars": [[слово, язык, стоимость символьной модели], …]
  "seqs":  [{"prior": P(ru), "words": [[набрано, показано, LO, отложено, ретро-предыдущего], …]}, …]
  "personal": личный слой для проверки (uni/bi/typo — формат Personal.to_json)
  "pseqs": то же, что seqs, но с включённым личным слоем
Порт прогоняет то же самое (замена букв — та же таблица R2E/E2R, что в model.py) и
сравнивает: показанное — точно, LO и стоимости — с допуском 0.05.

Только открытые фразы (тестовые наборы репозитория), никаких личных текстов.

    python3 nn/lm/make_selftest.py --char nn/lm/qschar.bin --ngram nn/ngram/qsngram.bin
"""
import argparse, json, os, random, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Scorer, Decoder, Params, Personal, lang_of, letters, split_punct     # noqa
from eval_phrases import parse                                   # noqa

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--char', default=os.path.join(HERE, 'qschar.bin'))
    ap.add_argument('--ngram', default=os.path.join(HERE, '..', 'ngram', 'qsngram.bin'))
    ap.add_argument('--out', default=os.path.join(HERE, 'core5-selftest.json'))
    ap.add_argument('--scan', type=int, default=150)
    a = ap.parse_args()
    random.seed(5)
    s = Scorer(a.char, a.ngram, Params())
    d = Decoder(s)
    chars = []
    for w, L in (('привет', 'ru'), ('ghbdtn', 'en'), ('ьез', 'ru'), ('mtp', 'en'), ("don't", 'en'),
                 ('hf,jnf.n', 'en'), ('пушнул', 'ru'), ('Обнаружилась', 'ru'), ('qwerty', 'en'), ('ёжик', 'ru')):
        chars.append([w, L, round(s.ch.word_cost(w.lower(), L), 4)])
    seqs = []
    lines = []
    sem = os.path.join(HERE, '..', 'sem')
    for f in ('my-phrases.txt', 'test-phrases.txt'):
        lines += [l for l in open(os.path.join(sem, f), encoding='utf-8')]
    scan = [l for l in open(os.path.join(sem, 'scan-phrases.txt'), encoding='utf-8') if '=>' in l]
    lines += random.sample(scan, min(a.scan, len(scan)))
    extra = ["Xnj ns pyftim ghj ghbdtn => x", "я yt хочу => x", "ye ns ghbdtn => x", "скрипт ГШ и ЬЕЗ ЦУИ ыр => x",
             "прще още нахуй => x", "d ,eatht gecnj => x", "f ytkmpz chfpe => x", "ok kubectl qwen => x",
             "ghbdtn, rfr ltkf? => x", "это ок jr => x"]
    for raw in lines + extra:
        pr = parse(raw)
        if not pr: continue
        tag, words, ti, exp = pr
        prior = {'terminal': 0.15, 'code': 0.2, 'chat': 0.8, 'address': 0.05}.get(tag, 0.5)
        d.reset(prior_ru=prior)
        out = []
        for w in words:
            T = lang_of(w)
            if not T or letters(w, T) == 0: continue
            r, retro = d.step(w, T)
            out.append([w, r.shown, round(r.lo, 4), r.pending, bool(retro)])
        if out: seqs.append({'prior': prior, 'words': out})
    # Личный слой из открытых фраз: nn/sem/my-train.txt как принятый текст (вес [n]),
    # плюс исправления (вес 3) и привычные опечатки — всё выдуманное, ничего личного.
    pers = Personal()
    for raw in open(os.path.join(sem, 'my-train.txt'), encoding='utf-8'):
        raw = raw.strip()
        if not raw or raw.startswith('#') or '=>' in raw: continue
        k = 1.0
        if raw.endswith(']') and '[' in raw:
            k = float(raw[raw.rindex('[') + 1:-1]); raw = raw[:raw.rindex('[')].strip()
        prev = None
        for w in raw.replace('*', '').split():
            L = lang_of(w)
            if not L: prev = None; continue
            core_ = split_punct(w, L)[1]
            if core_: pers.add(L, core_, k, prev=prev)
            prev = core_ or None
    for L, w, prev in (('en', 'awg', None), ('en', 'mtp', None), ('ru', 'гпт', 'чат'), ('en', 'ha', 'сервер'),
                       ('en', 'kubectl', None), ('ru', 'ру', 'он')):
        pers.add(L, w, 3.0, prev=prev)
    for L, wrong, right in (('ru', 'шына', 'шина'), ('ru', 'шына', 'шина'), ('ru', 'малоко', 'молоко'),
                            ('ru', 'малоко', 'молоко'), ('ru', 'малоко', 'малако'), ('en', 'teh', 'the'),
                            ('en', 'teh', 'the'), ('ru', 'щас', 'сейчас')):
        pers.add_typo(L, wrong, right)
    sp = Scorer(a.char, a.ngram, Params(), pers)
    dp = Decoder(sp)
    pextra = ["перезагрузил шлюз *РФ* => x", "сервер РФ ok => x", "причем тут фцп => x", "чат гпт сделал => x",
              "купил isyf => x", "vfkjrj и хлеб => x", "он he сказал => x", "the teh ntr => x", "ьез сейчас допилю => x",
              "граждане HA => x", "шина малоко щас => x"]
    pseqs = []
    plines = [l for l in open(os.path.join(sem, 'test-phrases.txt'), encoding='utf-8')]
    plines += [l for l in open(os.path.join(sem, 'my-phrases.txt'), encoding='utf-8')]
    plines += random.sample(scan, min(60, len(scan)))
    for raw in plines + pextra:
        pr = parse(raw)
        if not pr: continue
        tag, words, ti, exp = pr
        prior = {'terminal': 0.15, 'code': 0.2, 'chat': 0.8, 'address': 0.05}.get(tag, 0.5)
        dp.reset(prior_ru=prior)
        out = []
        for w in words:
            T = lang_of(w)
            if not T or letters(w, T) == 0: continue
            r, retro = dp.step(w, T)
            out.append([w, r.shown, round(r.lo, 4), r.pending, bool(retro)])
        if out: pseqs.append({'prior': prior, 'words': out})
    json.dump({'v': 2, 'chars': chars, 'seqs': seqs, 'personal': pers.to_json(), 'pseqs': pseqs},
              open(a.out, 'w'), ensure_ascii=False, indent=0)
    print(f'→ {a.out}: символьных {len(chars)}, последовательностей {len(seqs)} + {len(pseqs)} с личным слоем, '
          f'слов {sum(len(x["words"]) for x in seqs) + sum(len(x["words"]) for x in pseqs)}')

if __name__ == '__main__':
    main()
