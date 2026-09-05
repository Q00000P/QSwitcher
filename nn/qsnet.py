#!/usr/bin/env python3
"""
QSNet — общий модуль контекстного детектора раскладки QSwitcher.

Здесь всё, что должно один в один совпадать с инференсом на Swift и C#:
  * нормализация слова в последовательность физических клавиш;
  * извлечение признаков (хэшированные n-граммы клавиш);
  * формат файла весов QSN1;
  * прямой проход сети на numpy (эталон для портов).

Зависимости: только numpy. Обучение — в train.py.

Идея: слово представляется НЕ буквами, а нажатыми клавишами (в обозначениях
EN-раскладки: «привет» → «ghbdtn»). Сеть отвечает на один вопрос: какой язык
имел в виду человек, нажав эти клавиши в этом контексте. Веса одни на обе
платформы и на оба направления.

Использование как CLI (проверка весов):
  python3 qsnet.py qsnet.bin ghbdtn                      # без контекста
  python3 qsnet.py qsnet.bin dns --ctx "cat /etc/resolv.conf" --app terminal
  python3 qsnet.py qsnet.bin днс --ctx "прописал в конфиге" --app chat --layout ru
"""
import json
import struct
import sys

import numpy as np

# Accelerate на Apple Silicon поднимает флаги FP-исключений внутри matmul при
# корректном результате — numpy честно на них ругается. Глушим; реальный взрыв
# ловится проверкой на конечность loss в train.py.
np.seterr(all="ignore")

# ---------------------------------------------------------------- константы

FORMAT_MAGIC = b"QSN1"

# Клавиши, которые в паре раскладок RU/EN дают буквы. Обозначаем клавишу её
# EN-символом. Всё остальное (цифры, знаки) в слово не входит.
KEYS = "abcdefghijklmnopqrstuvwxyz[];',.`"

# Стандартная ПК-раскладка RU → клавиша. Совпадает с layout_map.json приложения;
# на устройстве приложение подставляет свою динамическую карту, но вокабуляр
# клавиш — этот.
RU_TO_KEY = {
    "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i",
    "щ": "o", "з": "p", "х": "[", "ъ": "]", "ф": "a", "ы": "s", "в": "d", "а": "f",
    "п": "g", "р": "h", "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'", "я": "z",
    "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m", "б": ",", "ю": ".",
    "ё": "`",
}
KEY_TO_RU = {v: k for k, v in RU_TO_KEY.items()}

APPS = ["other", "terminal", "code", "browser", "chat"]
LANGS = ["ru", "en"]           # порядок one-hot текущей раскладки и метки
CTX_FLAGS = ["ru", "en", "none"]  # флаг языка контекстного слова

NGRAM_MIN, NGRAM_MAX = 1, 4
CTX_WORDS = 3
MAX_WORD_LEN = 24


def is_cyr(ch: str) -> bool:
    return ("а" <= ch <= "я") or ch == "ё"


def is_lat(ch: str) -> bool:
    return "a" <= ch <= "z"


def word_lang(word: str):
    """Язык слова по тому, каким оно написано: 'ru' / 'en' / None (смесь или не слово)."""
    w = word.lower()
    cyr = sum(1 for c in w if is_cyr(c))
    lat = sum(1 for c in w if is_lat(c))
    if cyr and not lat:
        return "ru"
    if lat and not cyr:
        return "en"
    return None


def to_keys(word: str):
    """Слово (в любой раскладке) → строка клавиш в EN-обозначениях.
    None, если в слове есть что-то, что не является клавишей-буквой
    (цифры, дефисы, кириллица вне стандартной раскладки)."""
    out = []
    for ch in word.lower():
        if ch in "\\|":
            out.append("`")   # ё живёт на ` (ПК) или на \ (мак) — одна клавиша-токен
        elif is_lat(ch) or ch in "[];',.`":
            out.append(ch)
        elif ch in RU_TO_KEY:
            out.append(RU_TO_KEY[ch])
        else:
            return None
    if not out or len(out) > MAX_WORD_LEN:
        return None
    return "".join(out)


def keys_to_ru(keys: str) -> str:
    return "".join(KEY_TO_RU.get(c, c) for c in keys)


# ---------------------------------------------------------------- признаки

def fnv1a32(s: str) -> int:
    """FNV-1a 32 бит по байтам ASCII-строки. Строки признаков — только ASCII."""
    h = 0x811C9DC5
    for b in s.encode("ascii"):
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h


def word_features(keys: str):
    """Список строк-признаков слова. Порядок не важен (усредняем).
    '<' и '>' — маркеры границ, '=' + слово — признак слова целиком."""
    s = "<" + keys + ">"
    feats = []
    n = len(s)
    for L in range(NGRAM_MIN, NGRAM_MAX + 1):
        if L > n:
            break
        for i in range(n - L + 1):
            feats.append(s[i:i + L])
    feats.append("=" + keys)
    return feats


def word_buckets(keys: str, buckets: int):
    return [fnv1a32(f) % buckets for f in word_features(keys)]


# ---------------------------------------------------------------- формат QSN1

def input_dim(dim: int) -> int:
    return dim + CTX_WORDS * (dim + len(CTX_FLAGS)) + len(APPS) + len(LANGS)


def tensor_spec(buckets: int, dim: int, hidden: int):
    return [
        ["emb", [buckets, dim]],
        ["w1", [input_dim(dim), hidden]],
        ["b1", [hidden]],
        ["w2", [hidden]],
        ["b2", [1]],
    ]


def save_qsn(path: str, params: dict, meta: dict):
    """params: dict name → np.ndarray float32; meta: buckets/dim/hidden + произвольное."""
    spec = tensor_spec(meta["buckets"], meta["dim"], meta["hidden"])
    header = dict(meta)
    header.update({
        "format": 1,
        "keys": KEYS,
        "apps": APPS,
        "langs": LANGS,
        "ctx_flags": CTX_FLAGS,
        "ngram_min": NGRAM_MIN,
        "ngram_max": NGRAM_MAX,
        "ctx_words": CTX_WORDS,
        "max_word_len": MAX_WORD_LEN,
        "hash": "fnv1a32",
        "input_dim": input_dim(meta["dim"]),
        "tensors": spec,
    })
    hbytes = json.dumps(header, ensure_ascii=False).encode("utf-8")
    with open(path, "wb") as f:
        f.write(FORMAT_MAGIC)
        f.write(struct.pack("<I", len(hbytes)))
        f.write(hbytes)
        for name, shape in spec:
            a = np.ascontiguousarray(params[name], dtype="<f4")
            assert list(a.shape) == shape, (name, a.shape, shape)
            f.write(a.tobytes())


def load_qsn(path: str):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != FORMAT_MAGIC:
            raise ValueError("не QSN1: %r" % magic)
        (hlen,) = struct.unpack("<I", f.read(4))
        header = json.loads(f.read(hlen).decode("utf-8"))
        params = {}
        for name, shape in header["tensors"]:
            count = int(np.prod(shape))
            buf = f.read(count * 4)
            if len(buf) != count * 4:
                raise ValueError("обрезанный файл на тензоре " + name)
            params[name] = np.frombuffer(buf, dtype="<f4").reshape(shape)
    return header, params


# ---------------------------------------------------------------- инференс (эталон)

class QSNet:
    """Прямой проход. Ровно это надо повторить на Swift/C#."""

    def __init__(self, header, params):
        self.h = header
        self.p = params
        self.buckets = header["buckets"]
        self.dim = header["dim"]

    def word_vec(self, keys):
        if not keys:
            return np.zeros(self.dim, dtype=np.float32)
        b = word_buckets(keys, self.buckets)
        return self.p["emb"][b].mean(axis=0)

    def build_input(self, keys, ctx, app, layout):
        """ctx: список до CTX_WORDS кортежей (keys|None, flag) — ближайшее предыдущее
        слово ПЕРВЫМ. Отсутствующие слоты — нули + флаг 'none'."""
        parts = [self.word_vec(keys)]
        for i in range(CTX_WORDS):
            if i < len(ctx):
                ckeys, flag = ctx[i]
            else:
                ckeys, flag = None, "none"
            parts.append(self.word_vec(ckeys) if ckeys else np.zeros(self.dim, np.float32))
            fl = np.zeros(len(CTX_FLAGS), np.float32)
            fl[CTX_FLAGS.index(flag)] = 1
            parts.append(fl)
        ap = np.zeros(len(APPS), np.float32)
        ap[APPS.index(app)] = 1
        parts.append(ap)
        ly = np.zeros(len(LANGS), np.float32)
        ly[LANGS.index(layout)] = 1
        parts.append(ly)
        return np.concatenate(parts)

    def forward(self, x):
        h = x @ self.p["w1"] + self.p["b1"]
        h = np.maximum(h, 0)
        z = float(h @ self.p["w2"] + self.p["b2"][0])
        return 1.0 / (1.0 + np.exp(-z))

    def p_ru(self, keys, ctx=(), app="other", layout="en"):
        """Вероятность того, что нажатые клавиши означали русское слово."""
        return self.forward(self.build_input(keys, list(ctx), app, layout))


def ctx_from_text(text: str):
    """Строка предыдущих слов (как на экране, уже в правильной раскладке) →
    список контекста для build_input: ближайшее слово первым."""
    ctx = []
    for w in reversed(text.split()):
        w = w.lower().strip("\"'«»()")
        lang = word_lang(w)          # по алфавиту букв
        keys = to_keys(w) if lang else None   # путь/число → нет вектора, есть флаг (как в клиентах)
        ctx.append((keys, lang or "none"))
        if len(ctx) >= CTX_WORDS:
            break
    return ctx


# ---------------------------------------------------------------- CLI

def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="проверка весов QSNet")
    ap.add_argument("weights")
    ap.add_argument("word", help="слово как набрано (любая раскладка)")
    ap.add_argument("--ctx", default="", help="предыдущие слова, как они на экране")
    ap.add_argument("--app", default="other", choices=APPS)
    ap.add_argument("--layout", default=None, choices=LANGS,
                    help="текущая раскладка (по умолчанию — по алфавиту слова)")
    a = ap.parse_args(argv)

    header, params = load_qsn(a.weights)
    net = QSNet(header, params)
    keys = to_keys(a.word)
    if keys is None:
        print("слово не переводится в клавиши:", a.word)
        return 2
    layout = a.layout or (word_lang(a.word) or "en")
    p = net.p_ru(keys, ctx_from_text(a.ctx), a.app, layout)
    ru, en = keys_to_ru(keys), keys
    print(f"клавиши={keys}  ru='{ru}'  en='{en}'  раскладка={layout}  app={a.app}")
    print(f"P(ru)={p:.3f}  P(en)={1-p:.3f}  → имелось в виду: {'ru' if p >= 0.5 else 'en'}"
          f"{'  (СВАП)' if (p >= 0.5) != (layout == 'ru') else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
