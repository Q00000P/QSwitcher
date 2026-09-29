#!/usr/bin/env python3
"""Лог QSwitcher (~/Library/Logs/QSwitcher.log) → события для eval_log.py.

    python3 nn/lm/parse_log.py ~/Library/Logs/QSwitcher.log nn/lm/data/events.json [--from N]

События: b (граница слова и решение), sw (автозамена), man (ручной свап набора),
mc (ручной свап завершённого слова), msel (свап выделения), tg (тоггл),
retro (исправление задним числом), click (клик / начало ввода), start (запуск).
Понимает строки и прежних ядер, и ядра 5. Текст лога личный — результат кладём
в nn/lm/data/ (в гит не попадает).
"""
import collections, json, re, sys

B = re.compile(r"^\[(\d\d:\d\d:\d\d)\] \[boundary\] '(.*)' \((ru|en), ctx=(\w+), app=(.*?)\) → (SWITCH|keep)$")
SW = re.compile(r"^\[switch/v[45]\] '(.*)' → '(.*?)'")
MAN = re.compile(r"^\[manual\] '(.*)' → '(.*)'")
MC = re.compile(r"^\[manual-completed\] '(.*)' → '(.*)'")
MS = re.compile(r"^\[manual-sel\] '(.*)' → '(.*)'")
TG = re.compile(r"^\[toggle\] '(.*)' → '(.*)' \(state теперь = (\w+)\)")
RT = re.compile(r"^\[retro\] цепочка: (.*)")

def parse(lines):
    ev, det, wave = [], [], '?'
    for i, l in enumerate(lines):
        s = l.strip()
        if l.startswith('===== QSwitcher'):
            m = re.search(r'\((wave\d+)', l); wave = m.group(1) if m else '?'
            ev.append({'t': 'start', 'wave': wave, 'line': i}); det = []; continue
        if s.startswith('[det]'):
            # ядро 5: «начало ввода» — сессия начинается заново (клик, другое окно, пауза)
            if 'ядро5: начало ввода' in s: ev.append({'t': 'click', 'line': i})
            det.append(s); continue
        m = B.match(l)
        if m:
            ev.append({'t': 'b', 'time': m.group(1), 'w': m.group(2), 'cur': m.group(3), 'ctx': m.group(4),
                       'app': m.group(5), 'dec': m.group(6), 'det': det, 'wave': wave, 'line': i})
            det = []; continue
        for rx, t in ((SW, 'sw'), (MAN, 'man'), (MC, 'mc'), (MS, 'msel'), (TG, 'tg')):
            m = rx.match(l)
            if m: ev.append({'t': t, 'a': m.group(1), 'b': m.group(2), 'line': i}); break
        else:
            m = RT.match(l)
            if m: ev.append({'t': 'retro', 'chain': m.group(1), 'line': i})
            elif '[buf] клик' in l: ev.append({'t': 'click', 'line': i})
    return ev

if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit(__doc__)
    lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().split('\n')
    if '--from' in sys.argv: lines = lines[int(sys.argv[sys.argv.index('--from') + 1]):]
    ev = parse(lines)
    json.dump(ev, open(sys.argv[2], 'w'), ensure_ascii=False)
    print(sys.argv[2], dict(collections.Counter(e['t'] for e in ev)))
