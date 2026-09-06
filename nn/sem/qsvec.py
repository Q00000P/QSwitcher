#!/usr/bin/env python3
"""
Эталонный ридер QSV1 и лукап векторов — это надо повторить на Swift/C#.
CLI-проверка:
  python3 qsvec.py qsvec.bin near сервер            # соседи слова
  python3 qsvec.py qsvec.bin topic "я настроил сервера и датчики" ha рф   # тема → чтения
"""
import json
import struct
import sys

import numpy as np

# Accelerate на Apple Silicon поднимает флаги FP-исключений внутри matmul при
# корректном результате — numpy честно на них ругается. Глушим.
np.seterr(all="ignore")


def ft_hash(s: str) -> int:
    """FNV-1a как в fastText: байт приводится к знаковому int8 перед xor."""
    h = 2166136261
    for b in s.encode("utf-8"):
        if b >= 128:
            b -= 256
        h ^= (b & 0xFFFFFFFF)
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def ngrams(word: str, minn: int, maxn: int):
    s = "<" + word + ">"
    out = []
    n = len(s)
    for i in range(n):
        for L in range(minn, maxn + 1):
            if i + L <= n and not (i == 0 and L == n):   # слово целиком в n-граммы не входит
                out.append(s[i:i + L])
    return out


# Служебные слова: они частотны везде, их векторы тянут любой центроид на себя.
# В теме не участвуют (список короткий — остальное снимает вычитание общей компоненты).
STOP = set("""и в во не что он на я с со как а то все она так его но да ты к у же вы за бы
по только ее мне было вот от меня еще нет о из ему теперь когда даже ну вдруг ли если уже
или ни быть был него до вас нибудь опять уж вам ведь там потом себя ничего ей может они тут
где есть надо ней для мы тебя их чем была сам чтоб без будто чего раз тоже себе под будет ж
тогда кто этот того потому этого какой совсем ним здесь этом один почти мой тем чтобы нее
сейчас были куда зачем всех никогда можно при наконец два об другой хоть после над больше
тот через эти нас про всего них какая много разве три эту моя впрочем хорошо свою этой перед
иногда лучше чуть том нельзя такой им более всегда конечно всю между
the be to of and a in that have i it for not on with he as you do at this but his by from
they we say her she or an will my one all would there their what so up out if about who get
which go me when make can like time no just him know take people into year your good some
could them see other than then now look only come its over think also back after use two how
our work first well way even new want because any these give day most us is are was were been
has had did does am
""".split())


class QSVec:
    def __init__(self, path):
        with open(path, "rb") as f:
            assert f.read(4) == b"QSV1"
            (hlen,) = struct.unpack("<I", f.read(4))
            self.h = json.loads(f.read(hlen).decode("utf-8"))
            D, V, B = self.h["dim"], self.h["vocab"], self.h["buckets"]
            self.words = []
            for _ in range(V):
                (n,) = struct.unpack("<H", f.read(2))
                self.words.append(f.read(n).decode("utf-8"))
            self.index = {w: i for i, w in enumerate(self.words)}
            raw = np.frombuffer(f.read(V * (4 + D)), dtype=np.uint8).reshape(V, 4 + D)
            self.vec = self._dequant(raw, D)
            raw = np.frombuffer(f.read(B * (4 + D)), dtype=np.uint8).reshape(B, 4 + D)
            self.ng = self._dequant(raw, D)
        # Общая компонента: среднее по частотной части словаря. У всех векторов есть
        # общий «фон» (частотность, язык), из-за него cos с чем угодно высокий и
        # темы неразличимы. Вычитаем его — сравнение начинает мерить смысл.
        self.common = self.vec[:min(len(self.words), 50_000)].mean(axis=0)
        c = self.vec - self.common
        self.vec_c = c / (np.linalg.norm(c, axis=1, keepdims=True) + 1e-9)

    @staticmethod
    def _dequant(raw, D):
        scale = raw[:, :4].copy().view("<f4").reshape(-1)
        q = raw[:, 4:].view(np.int8).astype(np.float32)
        return q * scale[:, None]

    def vector(self, word: str):
        w = word.lower()
        if w in self.index:
            return self.vec[self.index[w]]
        rows = [ft_hash(g) % self.h["buckets"] for g in ngrams(w, self.h["minn"], self.h["maxn"])]
        if not rows:
            return np.zeros(self.h["dim"], np.float32)
        return self.ng[rows].mean(axis=0)

    def centered(self, word):
        """Вектор без общей компоненты, единичной длины — им и меряем смысл."""
        v = self.vector(word) - self.common
        return v / (np.linalg.norm(v) + 1e-9)

    def topic(self, words, decay=0.9):
        """Тема: затухающее среднее очищенных векторов (ближние слова весят больше,
        служебные и короткие не участвуют)."""
        acc = np.zeros(self.h["dim"], np.float32)
        wsum = 0.0
        w = 1.0
        for word in reversed(words):
            lw = word.lower()
            if lw in STOP or len(lw) < 3:
                continue
            acc += w * self.centered(lw)
            wsum += w
            w *= decay
        return acc / wsum if wsum else acc

    def near(self, vec, k=10, centered=True):
        v = vec - (0 if centered else self.common)
        sims = self.vec_c @ (v / (np.linalg.norm(v) + 1e-9))
        idx = np.argsort(-sims)[:k]
        return [(self.words[i], float(sims[i])) for i in idx]

    def score(self, topic_vec, word):
        """Насколько слово подходит теме. Сравнивать абсолютные cos между разными
        словами нельзя — у каждого свой «фон»; поэтому нормируем на фон слова:
        сколько сигм его сходство с этой темой выше сходства со случайными темами."""
        v = self.centered(word)
        if not hasattr(self, "_bg"):
            rng = np.random.default_rng(0)
            idx = rng.integers(0, min(len(self.words), 50_000), size=(200, 8))
            self._bg = np.stack([self.vec_c[row].mean(axis=0) for row in idx])
            self._bg /= np.linalg.norm(self._bg, axis=1, keepdims=True) + 1e-9
        bg = self._bg @ v
        t = float(topic_vec @ v / (np.linalg.norm(topic_vec) + 1e-9))
        return (t - float(bg.mean())) / (float(bg.std()) + 1e-9)


def cos(a, b):
    return float(a @ b / ((np.linalg.norm(a) + 1e-9) * (np.linalg.norm(b) + 1e-9)))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    m = QSVec(argv[1])
    if argv[2] == "near":
        for w, s in m.near(m.vector(argv[3])):
            print(f"  {s:.3f}  {w}")
    elif argv[2] == "align":
        # Проверка, что RU и EN в одном пространстве: у пары переводов должен быть
        # высокий cos, а у случайной пары — низкий.
        pairs = [("computer", "компьютер"), ("server", "сервер"), ("network", "сеть"),
                 ("password", "пароль"), ("router", "роутер"), ("config", "конфиг"),
                 ("computer", "борщ"), ("router", "любовь")]
        for en, ru in pairs:
            print(f"  {en:10s} ↔ {ru:12s} cos = {cos(m.centered(en), m.centered(ru)):+.3f}")
    elif argv[2] == "topic":
        t = m.topic(argv[3].split())
        print("тема ближе к:", ", ".join(w for w, _ in m.near(t, 8)))
        for cand in argv[4:]:
            print(f"  {cand}: score = {m.score(t, cand):+.2f} σ  (cos {cos(t, m.centered(cand)):+.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
