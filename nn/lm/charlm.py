#!/usr/bin/env python3
"""Символьная модель языка (RU и EN) для QSwitcher — «как выглядит слово этого языка».

Зачем. Решение «набрано не в той раскладке» — это сравнение двух прочтений одних и тех
же клавиш: какое из них правдоподобнее как слово своего языка. Словарь отвечает только
«есть/нет» и молчит на опечатках, сленге, новых словоформах («пушнул», «челендж»,
«сделоть»); частоты слов из корпуса — только для виденных слов. Символьная модель
оценивает ЛЮБУЮ строку: «ghbdtn» как английское — невозможно, «привет» как русское —
обычно; «ьез» как русское — невозможно (слово на «ь»), «mtp» как английское — терпимо.

Модель: символьные n-граммы порядка N внутри слова, с метками начала «^» и конца «$»,
сглаживание Уиттена–Белла, хранение в форме «с откатом»:
    P(c|h) = stored(h+c)                     если такая n-грамма есть,
           = λ(h) · P(c|h[1:])               иначе (λ(h) — если h встречалась).
Учится на ТИПАХ слов (каждое слово один раз): описывает форму редких и новых слов;
частые слова и так покрыты частотами слов (qsngram.bin).

Формат QSCL1 (читается Swift/C# теми же хэшами, что QSNG2):
    "QSCL1" | u32 длина JSON | JSON-заголовок | по языкам: [u32 размер, таблица] × 3
    таблица = массив записей по 3 байта: fp16 LE + значение uint8,
    две корзины на ключ (fnv1a(key), fnv1a("\\x03"+key)), отпечаток fp16(key).
    ng   — ключ h+c,   значение −ln P · 20  (шаг 0.05 ната, потолок 12.75)
    hist — ключ h,     значение −ln λ · 20
    caps — ключ слово, значение round(P(капсом | слово) · 255)

    python3 nn/lm/charlm.py train --order 6 --out nn/lm/qschar.bin
    python3 nn/lm/charlm.py score ghbdtn привет ьез mtp
"""
import argparse, json, math, os, struct, sys, time
from collections import defaultdict
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, 'data')

RU_ALPHA = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'
EN_ALPHA = 'abcdefghijklmnopqrstuvwxyz'
EXTRA = {'ru': '-', 'en': "-'"}
UNK = '#'
SCALE = 20.0           # uint8 = −ln P · 20
CAP = 255 / SCALE      # 12.75 ната

def norm(word, lang):
    """Строка → символы модели: нижний регистр, ё как есть, всё чужое → '#'."""
    alpha = RU_ALPHA if lang == 'ru' else EN_ALPHA
    ok = set(alpha) | set(EXTRA[lang])
    return ''.join(ch if ch in ok else UNK for ch in word.lower())

# ---------------------------------------------------------------- хэши (как QSNG2)

def fnv1a_bytes(b, seed=0x811C9DC5):
    h = seed
    for x in b:
        h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF
    return h

def fnv_batch(keys):
    """FNV-1a для списка bytes, векторно (по столбцам байтов)."""
    n = len(keys)
    out = np.full(n, 0x811C9DC5, dtype=np.uint64)
    lens = np.fromiter((len(k) for k in keys), dtype=np.int64, count=n)
    L = int(lens.max()) if n else 0
    buf = np.zeros((n, L), dtype=np.uint64)
    for i, k in enumerate(keys):
        buf[i, :len(k)] = np.frombuffer(k, dtype=np.uint8)
    for j in range(L):
        live = lens > j
        h = out[live]
        h = ((h ^ buf[live, j]) * np.uint64(0x01000193)) & np.uint64(0xFFFFFFFF)
        out[live] = h
    return out.astype(np.uint32)

def slots_fp(keys_str, mask):
    kb = [k.encode('utf-8') for k in keys_str]
    a = fnv_batch(kb).astype(np.int64) & mask
    b = fnv_batch([b'\x03' + k for k in kb]).astype(np.int64) & mask
    b = np.where(b == a, (a + 1) & mask, b)
    fp = (fnv_batch([b'\x01' + k + b'\x02' for k in kb]).astype(np.int64) >> 16)
    fp = np.where(fp == 0, 1, fp)
    return a, b, fp

def pack_table(items, bits):
    """items: [(key, uint8)] по убыванию важности. Запись: fp16 LE + значение."""
    mask = (1 << bits) - 1
    table = np.zeros(((mask + 1) * 3,), dtype=np.uint8)
    if not items: return table.tobytes(), 0
    keys = [k for k, _ in items]; vals = [v for _, v in items]
    a, b, fp = slots_fp(keys, mask)
    used = np.zeros(mask + 1, dtype=np.int64)       # 0 = пусто, иначе fp
    lost = 0
    for i in range(len(keys)):
        f = int(fp[i])
        for s in (int(a[i]), int(b[i])):
            cur = used[s]
            if cur == 0 or cur == f:
                used[s] = f
                table[s*3] = f & 0xFF; table[s*3+1] = f >> 8; table[s*3+2] = vals[i]
                break
        else:
            lost += 1
    return table.tobytes(), lost

def bits_for(n, load=0.5):
    b = 10
    while (1 << b) * load < n: b += 1
    return b

# ---------------------------------------------------------------- обучение

def read_types(lang, min_count, max_types):
    path = os.path.join(DATA, f'words-{lang}.tsv')
    out = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            w, c = line.rstrip('\n').split('\t')
            c = int(c)
            if c < min_count: break               # файл по убыванию
            out.append(norm(w, lang))
            if len(out) >= max_types: break
    if lang == 'en':
        # в корпусе апострофы разрезаны; добавим частые формы с ними
        for w in ("don't", "can't", "won't", "isn't", "aren't", "didn't", "doesn't", "wasn't",
                  "weren't", "haven't", "hasn't", "wouldn't", "couldn't", "shouldn't", "it's",
                  "i'm", "you're", "we're", "they're", "i've", "you've", "we've", "i'll",
                  "you'll", "we'll", "that's", "what's", "there's", "let's", "he's", "she's",
                  "i'd", "you'd", "he'd", "she'd", "we'd", "they'd", "who's", "here's"):
            out.append(w)
    return out

def train(types, N):
    """Счётчики по типам: C[(h, c)] для всех порядков 0..N-1 длины истории."""
    C = [defaultdict(int) for _ in range(N)]      # C[k][h+c], len(h)=k
    pad = '^' * (N - 1)
    for w in types:
        s = pad + w + '$'
        for i in range(N - 1, len(s)):
            c = s[i]
            for k in range(N):
                C[k][s[i-k:i] + c] += 1
    # по истории: сумма и число разных продолжений
    H = [defaultdict(lambda: [0, 0]) for _ in range(N)]
    for k in range(N):
        for g, n in C[k].items():
            h = g[:-1]; e = H[k][h]; e[0] += n; e[1] += 1
    return C, H

def probs(C, H, N, vocab_size):
    """Уиттен–Белл: P[k][h+c] = −ln P(c|h), L[k][h] = −ln λ(h)."""
    P = [dict() for _ in range(N)]; L = [dict() for _ in range(N)]
    uni = 1.0 / vocab_size
    for k in range(N):
        for h, (ch, th) in H[k].items():
            L[k][h] = -math.log(th / (ch + th))
        for g, n in C[k].items():
            h = g[:-1]; c = g[-1]; ch, th = H[k][h]
            lower = uni if k == 0 else math.exp(-P[k-1][g[1:]])
            P[k][g] = -math.log((n + th * lower) / (ch + th))
    return P, L

def q(x):
    return int(min(255, max(0, round(x * SCALE))))

def build(lang, N, min_count, max_types, prune, out_items):
    t0 = time.time()
    types = read_types(lang, min_count, max_types)
    alpha = RU_ALPHA if lang == 'ru' else EN_ALPHA
    V = len(alpha) + len(EXTRA[lang]) + 2          # + '$' и '#'
    C, H = train(types, N)
    P, L = probs(C, H, N, V)
    ng, hi = [], []
    for k in range(N):
        mc = prune[k] if k < len(prune) else prune[-1]
        for g, lp in P[k].items():
            if C[k][g] >= mc: ng.append((C[k][g], g, q(lp)))
        for h, ll in L[k].items():
            if H[k][h][0] >= mc: hi.append((H[k][h][0], h, q(ll)))
    ng.sort(key=lambda x: -x[0]); hi.sort(key=lambda x: -x[0])
    print(f'  {lang}: типов {len(types):,}, n-грамм {sum(len(c) for c in C):,} → оставлено {len(ng):,}, '
          f'историй {len(hi):,}  ({time.time()-t0:.0f} c)', flush=True)
    out_items[lang] = ([(g, v) for _, g, v in ng], [(h, v) for _, h, v in hi])

def read_caps(lang, min_total):
    """Регистр по сырым текстам: доля вхождений целиком заглавными (2–6 букв)."""
    tot = defaultdict(int); cap = defaultdict(int)
    for fn in os.listdir(DATA):
        if not (fn.startswith('caps-') and fn.endswith('.tsv')): continue
        with open(os.path.join(DATA, fn), encoding='utf-8') as f:
            for line in f:
                p = line.rstrip('\n').split('\t')
                if len(p) != 3: continue
                w = p[0]
                is_ru = all(ch in RU_ALPHA for ch in w); is_en = all(ch in EN_ALPHA for ch in w)
                if (lang == 'ru' and not is_ru) or (lang == 'en' and not is_en) or len(w) < 2: continue
                tot[w] += int(p[1]); cap[w] += int(p[2])
    items = []
    for w, t in tot.items():
        if t >= min_total:
            items.append((t, w, int(round(255 * (cap[w] + 0.2) / (t + 1.0)))))
    items.sort(key=lambda x: -x[0])
    return [(w, v) for _, w, v in items]

def cmd_train(a):
    out = {}
    prune = [int(x) for x in a.prune.split(',')]
    for lang in ('ru', 'en'):
        build(lang, a.order, a.min_count, a.max_types, prune, out)
    header = {'v': 1, 'order': a.order, 'scale': SCALE, 'langs': ['ru', 'en'],
              'alpha': {'ru': RU_ALPHA + EXTRA['ru'], 'en': EN_ALPHA + EXTRA['en']},
              'unk': UNK, 'tables': {}}
    blobs = []
    for lang in ('ru', 'en'):
        ng, hi = out[lang]
        caps = read_caps(lang, a.caps_min)
        for name, items in (('ng', ng), ('hist', hi), ('caps', caps)):
            bits = bits_for(len(items), a.load)
            blob, lost = pack_table(items, bits)
            header['tables'][f'{lang}.{name}'] = {'bits': bits, 'n': len(items), 'lost': lost}
            print(f'  {lang}.{name}: {len(items):,} в 2^{bits} (потеряно {lost})', flush=True)
            blobs.append(blob)
    hb = json.dumps(header, ensure_ascii=False).encode('utf-8')
    with open(a.out, 'wb') as f:
        f.write(b'QSCL1'); f.write(struct.pack('<I', len(hb))); f.write(hb)
        for b in blobs:
            f.write(struct.pack('<I', len(b))); f.write(b)
    print(f'→ {a.out}  {os.path.getsize(a.out)/1e6:.1f} МБ')

# ---------------------------------------------------------------- чтение и оценка

class CharLM:
    def __init__(self, path):
        with open(path, 'rb') as f:
            assert f.read(5) == b'QSCL1', 'не QSCL1'
            hl = struct.unpack('<I', f.read(4))[0]
            self.h = json.loads(f.read(hl))
            self.N = self.h['order']; self.scale = self.h['scale']
            self.t = {}
            for lang in self.h['langs']:
                for name in ('ng', 'hist', 'caps'):
                    n = struct.unpack('<I', f.read(4))[0]
                    self.t[f'{lang}.{name}'] = (f.read(n), self.h['tables'][f'{lang}.{name}']['bits'])

    def _get(self, table, key):
        data, bits = self.t[table]
        mask = (1 << bits) - 1
        kb = key.encode('utf-8')
        a = fnv1a_bytes(kb) & mask
        b = fnv1a_bytes(b'\x03' + kb) & mask
        if b == a: b = (a + 1) & mask
        fp = fnv1a_bytes(b'\x01' + kb + b'\x02') >> 16 or 1
        for s in (a, b):
            i = s * 3
            if (data[i] | (data[i+1] << 8)) == fp: return data[i+2]
        return None

    def char_cost(self, lang, h, c):
        """−ln P(c|h) с откатом."""
        bo = 0.0
        for k in range(len(h), -1, -1):
            hk = h[len(h)-k:]
            v = self._get(f'{lang}.ng', hk + c)
            if v is not None: return bo + v / self.scale
            l = self._get(f'{lang}.hist', hk)
            if l is not None: bo += l / self.scale
        return bo + CAP

    def word_cost(self, word, lang):
        """−ln P(слово) по символам, с концом слова. Слово — как есть (любые символы)."""
        s = norm(word, lang)
        s = '^' * (self.N - 1) + s + '$'
        return sum(self.char_cost(lang, s[i-self.N+1:i], s[i]) for i in range(self.N - 1, len(s)))

    def caps_p(self, word, lang):
        v = self._get(f'{lang}.caps', word.lower())
        return None if v is None else v / 255.0

def cmd_score(a):
    m = CharLM(a.model)
    for w in a.words:
        cr = m.word_cost(w, 'ru'); ce = m.word_cost(w, 'en')
        print(f'{w:16s} ru {cr:6.2f}  en {ce:6.2f}  (на символ ru {cr/(len(w)+1):.2f} en {ce/(len(w)+1):.2f})'
              f'  caps ru {m.caps_p(w,"ru")} en {m.caps_p(w,"en")}')

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    t = sp.add_parser('train')
    t.add_argument('--order', type=int, default=6)
    t.add_argument('--min-count', type=int, default=3, help='минимальная частота слова-типа')
    t.add_argument('--max-types', type=int, default=2_000_000)
    t.add_argument('--prune', default='1,1,1,2,2,2', help='мин. счётчик n-граммы по длине истории 0..N-1')
    t.add_argument('--caps-min', type=int, default=20)
    t.add_argument('--load', type=float, default=0.5)
    t.add_argument('--out', default=os.path.join(HERE, 'qschar.bin'))
    s = sp.add_parser('score')
    s.add_argument('--model', default=os.path.join(HERE, 'qschar.bin'))
    s.add_argument('words', nargs='+')
    a = ap.parse_args()
    {'train': cmd_train, 'score': cmd_score}[a.cmd](a)
