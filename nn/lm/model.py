#!/usr/bin/env python3
"""Эталон решающего ядра QSwitcher 5 — одна формула вместо каскада.

На каждое слово — два прочтения одних и тех же клавиш: набранное (язык T) и другое
(язык A). Для каждого языка считается стоимость = −ln P (меньше — правдоподобнее):

  P_L(слово) = (1−α−τ)·P_известн(слово) + α·P_символы(слово) + τ·P_опечатка(слово)
      P_известн  = (1−γ)·P_корпус + γ·P_личн        частоты слов: корпус и твой набор
      P_символы  — символьная модель (форма слова: «ghbdtn» — не английское)
      P_опечатка — слово в одной правке от известного («прще» → «проще»)
  + пара с предыдущим словом того же языка (если сосед уверенный)
  + регистр: слово целиком ЗАГЛАВНЫМИ → −ln P(капсом | слово, L)
  + переход: −ln(1−π) тот же язык, −ln π смена; в начале ввода — ожидание приложения
  + раскладка: +b_K, если L — не текущая раскладка

  LO = стоимость(T) − стоимость(A);   LO > θ и «другое прочтение — слово» → свап.

Короткое слово с LO в (θ_defer, θ] откладывается: следующее уверенное слово добавляет
переход и пару справа, и при LO > θ отложенное исправляется задним числом.

Вето нет: всё — слагаемые одной суммы, любое решение раскладывается по слагаемым.
"""
import math, os, sys
from collections import defaultdict
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'ngram'))
sys.path.insert(0, HERE)
from charlm import CharLM, RU_ALPHA, EN_ALPHA          # noqa: E402

R2E = dict(zip("йцукенгшщзхъфывапролджэячсмитьбюё", "qwertyuiop[]asdfghjkl;'zxcvbnm,.\\"))
E2R = {v: k for k, v in R2E.items()}
VALID1 = {'ru': set('авикосуя'), 'en': set('ai')}
ALPHA = {'ru': RU_ALPHA, 'en': EN_ALPHA}

def swap(w):
    out = []
    for ch in w:
        lo = ch.lower()
        m = R2E.get(lo) or E2R.get(lo)
        if m is None: out.append(ch); continue
        out.append(m.upper() if ch != lo else m)
    return ''.join(out)

def lang_of(w):
    for ch in w.lower():
        if ch in RU_ALPHA: return 'ru'
        if ch in EN_ALPHA: return 'en'
    return ''

def letters(w, lang):
    a = ALPHA[lang]
    return sum(1 for ch in w.lower() if ch in a)

def split_punct(w, lang):
    """(начало, ядро, конец): по краям — символы, которые в этом языке не буквы."""
    a = set(ALPHA[lang]) | ({'-', "'"} if lang == 'en' else {'-'})
    i, j = 0, len(w)
    while i < j and w[i].lower() not in a: i += 1
    while j > i and w[j-1].lower() not in a: j -= 1
    return w[:i], w[i:j], w[j:]

def is_caps(w):
    return sum(1 for ch in w if ch.isalpha()) >= 2 and w.upper() == w and w.lower() != w

class WordLM:
    """qsngram.bin (QSNG2): −ln P(слово), −ln P(слово | предыдущее)."""
    def __init__(self, path):
        from score import LM
        self.lm = LM(path)
        self._cache = {}
    def uni(self, lang, w):
        k = (lang, w)
        if k not in self._cache: self._cache[k] = self.lm.uni(lang, w)
        return self._cache[k]
    def bi(self, lang, p, w):
        return self.lm.bi(lang, p, w)

class Personal:
    """Личные частоты: слова, которые человек оставил на экране (в своём языке)."""
    def __init__(self):
        self.c = {'ru': defaultdict(float), 'en': defaultdict(float)}
        self.n = {'ru': 0.0, 'en': 0.0}
    def add(self, lang, w, k=1.0):
        self.c[lang][w.lower()] += k; self.n[lang] += k
    def cost(self, lang, w):
        v = self.c[lang].get(w.lower())
        if not v or v < 2: return None               # одно вхождение — не довод
        return -math.log(v / (self.n[lang] + 50.0))

@dataclass
class Params:
    alpha: float = 0.03       # доля новых/редких слов (символьная модель)
    tau: float = 0.02         # доля опечаток
    gamma: float = 0.3        # вес личных частот
    beta: float = 0.5         # вес пары с предыдущим словом
    pi: float = 0.04          # смена языка между соседними словами
    bK: float = 1.0           # «язык не совпадает с раскладкой»
    theta: float = 2.0        # порог свапа
    theta_defer: float = -1.0 # короткое слово выше этого LO ждёт правого соседа
    caps_p0: float = 0.03     # P(капсом) для слова вне таблицы регистра
    u_short: float = 13.0     # короткое (2–3 буквы) другое прочтение: частота слова не реже e^-13
    u_short2: float = 16.0    # …или не реже e^-16, но тогда нужен уверенный LO
    lo_strong: float = 5.0    # «уверенный» LO
    c_rel: float = 4.5        # набранное — явный мусор: новое прочтение хотя бы произносимо (на букву)
    c_junk: float = 6.0       # «явный мусор»: символьная стоимость набранного на букву выше
    c_max: float = 3.2        # неизвестное длинное: символьная стоимость на букву не выше
    typo_min: int = 4         # модель опечаток — со скольких букв
    typo_max: int = 32        # …и до скольких (длинное — URL/путь, не опечатка)
    short: int = 3
    edge: float = 1.5         # цена символа-«пунктуации» на краю прочтения

@dataclass
class Word:
    typed: str
    T: str
    A: str = ''
    alt: str = ''
    shown: str = ''
    lang: str = ''
    lo: float = 0.0
    pending: bool = False
    confident: bool = True
    explain: str = ''

class Scorer:
    def __init__(self, char_path, ngram_path, params=None, personal=None):
        self.ch = CharLM(char_path)
        self.wl = WordLM(ngram_path)
        self.p = params or Params()
        self.pers = personal

    def known(self, lang, w):
        """−ln P_известн(w): смесь корпуса и личного, или None."""
        u = self.wl.uni(lang, w)
        pc = self.pers.cost(lang, w) if self.pers else None
        if u is None and pc is None: return None
        g = self.p.gamma if pc is not None else 0.0
        pu = math.exp(-u) if u is not None else 0.0
        pp = math.exp(-pc) if pc is not None else 0.0
        return -math.log((1 - g) * pu + g * pp) if (1 - g) * pu + g * pp > 0 else None

    def typo(self, lang, w):
        """Ближайшее известное слово в одной правке: −ln P(соседа) + ln(число правок)."""
        if len(w) < self.p.typo_min or len(w) > self.p.typo_max: return None
        a = ALPHA[lang]; best = None
        cands = set()
        for i in range(len(w)):
            cands.add(w[:i] + w[i+1:])                                   # удаление
            if i + 1 < len(w): cands.add(w[:i] + w[i+1] + w[i] + w[i+2:])  # перестановка
            for c in a:
                if c != w[i]: cands.add(w[:i] + c + w[i+1:])              # замена
        for i in range(len(w) + 1):
            for c in a: cands.add(w[:i] + c + w[i:])                    # вставка
        for c in cands:
            u = self.known(lang, c)
            if u is not None and (best is None or u < best): best = u
        if best is None: return None
        return best + math.log(len(cands))

    def word_cost(self, w, lang, prev=None):
        p = self.p
        lw = w.lower()
        k = self.known(lang, lw)
        c = self.ch.word_cost(lw, lang)
        t = self.typo(lang, lw) if k is None else None
        pw = ((1 - p.alpha - p.tau) * (math.exp(-k) if k is not None else 0.0)
              + p.alpha * math.exp(-c) + p.tau * (math.exp(-t) if t is not None else 0.0))
        parts = {'слово': k, 'симв': c}
        if t is not None: parts['опеч'] = t
        if prev:
            b = self.wl.bi(lang, prev.lower(), lw)
            if b is not None:
                pw = p.beta * math.exp(-b) + (1 - p.beta) * pw
                parts['пара'] = b
        return -math.log(max(pw, 1e-300)), parts

    def reading(self, r, lang, prev_word=None, prev_lang=None, caps=False):
        pre, cr, post = split_punct(r, lang)
        if not cr: return 60.0, {'пусто': 0.0}, cr
        prev = prev_word if (prev_word and prev_lang == lang) else None
        cost, parts = self.word_cost(cr, lang, prev)
        cost += self.p.edge * (len(pre) + len(post))
        if caps:
            cp = self.ch.caps_p(cr, lang)
            cp = self.p.caps_p0 if cp is None else min(0.99, max(0.01, cp))
            parts['капс'] = -math.log(cp); cost += parts['капс']
        return cost, parts, cr

    def is_word(self, core_, lang, parts, caps, lo=0.0, typed_cpc=0.0):
        """Можно ли переключать В это прочтение: оно должно быть словом.
        lo — перевес другого прочтения, typed_cpc — «мусорность» набранного (нат на букву)."""
        p = self.p
        n = letters(core_, lang)
        if n == 0: return False
        if n == 1: return core_.lower() in VALID1[lang]
        k = parts.get('слово')
        if n <= p.short:
            if k is not None and k <= p.u_short: return True
            if k is not None and k <= p.u_short2 and lo > p.lo_strong: return True
            if caps and parts.get('капс', 9) < 1.0 and k is not None: return True
            return False
        if k is not None or parts.get('опеч') is not None: return True
        cpc = parts['симв'] / (n + 1)
        if cpc <= p.c_max: return True
        # набранное — явный мусор («bvzlt,fu»), новое хотя бы произносимо («имядебаг»)
        return typed_cpc > p.c_junk and cpc <= p.c_rel and lo > 10.0

class Decoder:
    """Слово за словом, со своими решениями в контексте — как при живом наборе."""
    def __init__(self, scorer, params=None):
        self.s = scorer
        self.p = params or scorer.p
        self.reset()

    def reset(self, prior_ru=0.5):
        self.hist = []
        self.prior_ru = prior_ru

    def _prior(self, lang):
        pr = self.prior_ru if lang == 'ru' else 1 - self.prior_ru
        return -math.log(min(max(pr, 0.02), 0.98))

    def _trans(self, lang, prev):
        if prev is None or not prev.confident: return self._prior(lang)
        return -math.log(1 - self.p.pi) if lang == prev.lang else -math.log(self.p.pi)

    def score(self, typed, T, prev):
        p = self.p
        A = 'en' if T == 'ru' else 'ru'
        alt = swap(typed)
        caps = is_caps(typed)
        ctx = prev if (prev is not None and prev.confident) else None
        pw = ctx.shown if ctx else None; pl = ctx.lang if ctx else None
        cT, partsT, coreT = self.s.reading(typed, T, pw, pl, caps)
        cA, partsA, coreA = self.s.reading(alt, A, pw, pl, caps)
        # хвост, который в набранной раскладке — пунктуация, можно оставить как набран
        pre, cr, post = split_punct(typed, T)
        if post and not pre and cr:
            c2, parts2, core2 = self.s.reading(swap(cr), A, pw, pl, caps)
            if c2 < cA: cA, partsA, coreA, alt = c2, parts2, core2, swap(cr) + post
        tT = self._trans(T, prev); tA = self._trans(A, prev)
        lo = (cT + tT) - (cA + tA + p.bK)
        nT = max(1, letters(coreT, T))
        ok = self.s.is_word(coreA, A, partsA, caps, lo, partsT.get('симв', 0.0) / (nT + 1))
        return lo, alt, A, ok, (cT, partsT, cA, partsA, tT, tA)

    def step(self, typed, T):
        p = self.p
        prev = self.hist[-1] if self.hist else None
        lo, alt, A, ok, dbg = self.score(typed, T, prev)
        n = letters(typed, T)
        w = Word(typed=typed, T=T, A=A, alt=alt, lo=lo)
        if lo > p.theta and ok:
            w.shown, w.lang = alt, A
        else:
            w.shown, w.lang = typed, T
            if n <= p.short and lo > p.theta_defer and ok:
                w.pending = True; w.confident = False
        retro = []
        cur_conf = (w.shown != typed) or lo < -p.theta
        if prev is not None and prev.pending and cur_conf:
            bonus = math.log((1 - p.pi) / p.pi)
            add = bonus if w.lang == prev.A else -bonus
            # пара справа: «другое прочтение prev → текущее» против «prev как набрано → текущее»
            bA = self.s.wl.bi(prev.A, prev.alt.lower(), w.shown.lower()) if w.lang == prev.A else None
            bT = self.s.wl.bi(prev.T, prev.typed.lower(), w.shown.lower()) if w.lang == prev.T else None
            if bA is not None: add += min(3.0, max(0.0, 12.0 - bA) / 3)
            if bT is not None: add -= min(3.0, max(0.0, 12.0 - bT) / 3)
            new_lo = prev.lo + add
            if new_lo > p.theta:
                prev.shown, prev.lang = prev.alt, prev.A
                retro.append((len(self.hist) - 1, prev.shown))
            prev.pending = False; prev.confident = True; prev.lo = new_lo
            if retro:   # текущее — с исправленным соседом
                lo2, alt2, A2, ok2, dbg = self.score(typed, T, prev)
                w.lo = lo2
                if lo2 > p.theta and ok2: w.shown, w.lang = alt2, A2
                else: w.shown, w.lang = typed, T
        cT, partsT, cA, partsA, tT, tA = dbg
        w.explain = (f"{typed}[{T}] {cT:.1f}+{tT:.1f} {fmt(partsT)} vs {alt}[{A}] {cA:.1f}+{tA:.1f}+{p.bK} "
                     f"{fmt(partsA)} → LO {lo:+.1f}{'' if ok else ' (не слово)'}{' отложено' if w.pending else ''}")
        self.hist.append(w)
        return w, retro

def fmt(parts):
    return '{' + ', '.join(f"{k} {v:.1f}" if isinstance(v, float) else f"{k} -" for k, v in parts.items()) + '}'

if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--char', default=os.path.join(HERE, 'qschar.bin'))
    ap.add_argument('--ngram', default=os.path.join(HERE, '..', 'ngram', 'qsngram.bin'))
    ap.add_argument('--prior-ru', type=float, default=0.5)
    ap.add_argument('phrase', nargs='+')
    a = ap.parse_args()
    d = Decoder(Scorer(a.char, a.ngram)); d.reset(a.prior_ru)
    for w in ' '.join(a.phrase).split():
        r, retro = d.step(w, lang_of(w) or 'en')
        for i, s in retro: print(f'   ↺ слово {i} → {s}')
        print(f'{r.shown:14s} {r.explain}')
