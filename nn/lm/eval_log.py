#!/usr/bin/env python3
"""Прогон реального лога QSwitcher через новое ядро.

Истина по каждому слову лога — то, что в итоге осталось на экране:
  - старое ядро переключило, человек не отменил → нужен свап;
  - старое ядро переключило, человек отменил (тоггл / стёр и набрал заново) → свап не нужен;
  - старое ядро оставило, человек потом свапнул (хоткей / выделение / перенабор) → нужен свап;
  - старое ядро оставило, человек не трогал → свап не нужен;
  - «[manual]» — человек свапнул слово ещё до пробела → нужен свап.
Сессии режутся по клику, смене приложения, паузе > 90 с. Контекст для нового ядра —
его СОБСТВЕННЫЕ решения (как при живом наборе).

    python3 nn/lm/eval_log.py events.json --char qschar.bin --ngram qsngram.bin [--show]
"""
import argparse, collections, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import Scorer, Decoder, Params, Personal, swap, lang_of, letters, split_punct     # noqa

def secs(t): h, m, s = map(int, t.split(':')); return h*3600 + m*60 + s

def build_items(ev):
    bs = [i for i, e in enumerate(ev) if e['t'] == 'b']
    err = {}
    for k, i in enumerate(bs):
        e = ev[i]; w = e['w']; t0 = secs(e['time'])
        j = i + 1; after = []
        while j < len(ev) and ev[j]['t'] != 'b': after.append(ev[j]); j += 1
        nxt = ev[bs[k+1]] if k + 1 < len(bs) else None
        if e['dec'] == 'SWITCH':
            if any(a['t'] == 'tg' for a in after): err[i] = 'FS'
            elif any(a['t'] in ('man', 'mc') and swap(a['a']).lower() == w.lower() for a in after): err[i] = 'FS'
            elif nxt and nxt['w'].lower() == w.lower() and abs(secs(nxt['time']) - t0) <= 15: err[i] = 'FS'
        else:
            if any(a['t'] == 'mc' for a in after): err[i] = 'MS'
            elif (nxt and swap(nxt['w']).lower() == w.lower() and nxt['w'].lower() != w.lower()
                  and len(w) >= 2 and abs(secs(nxt['time']) - t0) <= 15): err[i] = 'MS'
    for i, e in enumerate(ev):
        if e['t'] != 'msel': continue
        words = e['a'].split(); k = i - 1; cnt = 0
        while k >= 0 and cnt < 40 and words:
            if ev[k]['t'] == 'b':
                cnt += 1
                if ev[k]['w'] in words and k not in err and ev[k]['dec'] == 'keep':
                    err[k] = 'MS'; words.remove(ev[k]['w'])
            k -= 1
    # ретро-цепочка старого ядра: исправила предыдущие однобуквенные слова задним числом
    retro_fixed = set()
    for i, e in enumerate(ev):
        if e['t'] != 'retro': continue
        k = len([x for x in e['chain'].split(',') if '→' in x])
        j = i - 1; seen = 0
        while j >= 0 and k > 0:
            if ev[j]['t'] == 'b':
                if seen >= 1: retro_fixed.add(j); k -= 1
                seen += 1
            j -= 1
    # последовательность: сессии
    sessions = []; cur = []; last = None
    def flush():
        nonlocal cur
        if cur: sessions.append(cur)
        cur = []
    for i, e in enumerate(ev):
        if e['t'] in ('click', 'start'):
            flush(); last = None; continue
        if e['t'] == 'man':
            # человек свапнул слово до пробела: 'a' набрано, 'b' — нужное
            a = e['a']
            if lang_of(a): cur.append({'typed': a, 'need_swap': True, 'old': 'preempt', 'app': last['app'] if last else '?', 'src': 'man', 'id': i})
            continue
        if e['t'] != 'b': continue
        if last is not None and (last['app'] != e['app'] or abs(secs(e['time']) - secs(last['time'])) > 90):
            flush()
        w = e['w']
        dec = 'SWITCH' if i in retro_fixed else e['dec']; bad = err.get(i)
        need = (dec == 'SWITCH') != (bad is not None)
        old = ('FS' if bad == 'FS' else 'MS' if bad == 'MS' else ('TP' if dec == 'SWITCH' else 'TN'))
        blind = bool(e['det']) and 'после навигации' in e['det'][-1]
        cur.append({'typed': w, 'need_swap': need, 'old': old, 'app': e['app'], 'src': 'b', 'blind': blind,
                    'det': e['det'][-1] if e['det'] else '', 'id': i})
        last = e
    flush()
    return sessions

def apply_truth(sessions, path):
    """Ручная разметка спорных слов: 'сессия:индекс' → 1 свап / 0 оставить / null неясно."""
    if not path or not os.path.exists(path): return
    t = json.load(open(path)); t.pop('_', None)
    for si, ses in enumerate(sessions):
        for i, it in enumerate(ses):
            k = f'{si}:{i}'
            if k in t:
                if t[k] is None: it['skip'] = True
                else: it['need_swap'] = bool(t[k])

def old_did(it):
    return it['old'] in ('TP', 'FS')

def stats(sessions):
    """Сколько раз язык меняется между соседними словами (по истине) и язык по приложениям."""
    ch = same = 0; per_app = collections.defaultdict(collections.Counter)
    for ses in sessions:
        prev = None
        for it in ses:
            if it.get('skip'): prev = None; continue
            w = swap(it['typed']) if it['need_swap'] else it['typed']
            L = lang_of(w)
            if not L: continue
            per_app[it['app']][L] += 1
            if prev: ch += (L != prev); same += (L == prev)
            prev = L
    return ch / max(1, ch + same), per_app

def app_class(app):
    a = app.lower()
    if any(x in a for x in ('terminal', 'iterm', 'qterm', 'warp', 'ghostty', 'kitty', 'alacritty')): return 'terminal'
    if any(x in a for x in ('vscode', 'xcode', 'jetbrains', 'sublime', 'cursor', 'zed')): return 'code'
    return 'text'

CLASS_PRIOR = {'terminal': 0.15, 'code': 0.2, 'text': 0.75}

def run(sessions, dec, show=False, personal=None):
    res = collections.Counter(); by = collections.defaultdict(collections.Counter)
    shown = []
    app_lang = collections.defaultdict(lambda: [0.0, 0.0])
    for si, ses in enumerate(sessions):
        app = ses[0]['app']; d = CLASS_PRIOR[app_class(app)]
        c = app_lang[app]; k = 20.0
        dec.reset(prior_ru=(c[0] + k * d) / (c[0] + c[1] + k))
        out = []
        for pos, it in enumerate(ses):
            w = it['typed']; T = lang_of(w)
            if not T or letters(w, T) == 0:
                out.append([it, False, None]); continue
            r, retro = dec.step(w, T)
            out.append([it, r.shown != w, r])
        # ретро меняет r.shown у предыдущих — перечитаем
        for o in out:
            if o[2] is not None: o[1] = o[2].shown != o[0]['typed']
        for pos, (it, did, r) in enumerate(out):
            if r is None or it.get('skip'): continue
            need = it['need_swap']
            t = ('TP' if need and did else 'MS' if need else 'FS' if did else 'TN')
            res[t] += 1
            n = letters(it['typed'], lang_of(it['typed']))
            L = '1' if n == 1 else '2' if n == 2 else '3' if n == 3 else '4-5' if n <= 5 else '6+'
            by['длина ' + L][t] += 1
            by['позиция ' + (str(pos) if pos < 3 else '3+')][t] += 1
            by['старое ' + it['old']][t] += 1
            if t in ('FS', 'MS') or (it['old'] in ('FS', 'MS') and show):
                shown.append((t, it['old'], it['typed'], r.shown, it['app'].split('.')[-1], f'{si}:{pos}', r.explain))
        # что осталось на экране (истина) — в ожидание приложения и в личные частоты
        for it, did, r in out:
            if it.get('skip'): continue
            fin = swap(it['typed']) if it['need_swap'] else it['typed']
            L = lang_of(fin)
            if not L: continue
            app_lang[app][0 if L == 'ru' else 1] += 1
            if personal is not None:
                _, core_, _ = split_punct(fin, L)
                if core_ and letters(core_, L) >= 2:
                    personal.add(L, core_)
    return res, by, shown

def report(res, by, title):
    tot = sum(res.values()); err = res['FS'] + res['MS']
    print(f"== {title}: слов {tot}, ошибок {err} ({100*err/max(1,tot):.2f}%): "
          f"ложных свапов {res['FS']}, пропусков {res['MS']}; верных свапов {res['TP']}")
    for k in sorted(by):
        c = by[k]; t = sum(c.values()); e = c['FS'] + c['MS']
        print(f"   {k:14s} {e:3d}/{t:4d}  FS {c['FS']:2d} MS {c['MS']:2d} TP {c['TP']:3d}")

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('events')
    ap.add_argument('--char', required=True); ap.add_argument('--ngram', required=True)
    ap.add_argument('--show', action='store_true')
    ap.add_argument('--personal', action='store_true', help='личные частоты: учиться на том, что осталось на экране')
    ap.add_argument('--truth', default=os.path.join(HERE, 'data', 'log-truth.json'))
    ap.add_argument('--set', action='append', default=[], help='параметр=значение')
    a = ap.parse_args()
    p = Params()
    for kv in a.set:
        k, v = kv.split('='); setattr(p, k, type(getattr(p, k))(v))
    sessions = build_items(json.load(open(a.events)))
    apply_truth(sessions, a.truth)
    n = sum(len(s) for s in sessions)
    pi, per_app = stats(sessions)
    print(f"сессий {len(sessions)}, слов {n}; смена языка между словами π = {pi:.3f}")
    for app, c in sorted(per_app.items(), key=lambda x: -sum(x[1].values()))[:6]:
        print(f"   {app.split('.')[-1][:18]:18s} ru {c['ru']:5d} en {c['en']:4d}")
    # старое ядро против той же истины
    oc = collections.Counter(); ob = collections.defaultdict(collections.Counter)
    for ses in sessions:
        for pos, it in enumerate(ses):
            T = lang_of(it['typed'])
            if it.get('skip') or not T or letters(it['typed'], T) == 0: continue
            did = old_did(it); need = it['need_swap']
            t = ('TP' if need and did else 'MS' if need else 'FS' if did else 'TN')
            oc[t] += 1
            n_ = letters(it['typed'], T)
            ob['длина ' + ('1' if n_ == 1 else '2' if n_ == 2 else '3' if n_ == 3 else '4-5' if n_ <= 5 else '6+')][t] += 1
            ob['позиция ' + (str(pos) if pos < 3 else '3+')][t] += 1
    report(oc, ob, 'старое ядро')
    pers = Personal() if a.personal else None
    dec = Decoder(Scorer(a.char, a.ngram, p, pers), p)
    res, by, shown = run(sessions, dec, show=a.show, personal=pers)
    report(res, by, 'новое ядро')
    for t, o, w, s, app, pos, ex in shown:
        print(f"  {t:2s} (старое {o:7s}) {w!r:16s} → {s!r:16s} {app[:12]:12s} pos {pos} | {ex[:170]}")
