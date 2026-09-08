#!/usr/bin/env python3
"""Эталон решения по n-граммам — тот же расчёт, что будет в приложении.

    python3 nn/ngram/score.py --left да --pair lf/да --right конечно
    python3 nn/ngram/score.py --left он --pair he/ру
    python3 nn/ngram/score.py --test ../sem/my-phrases.txt      (строки со *звёздочками*)

Балл чтения = −(логвес биграммы «сосед → слово» в языке чтения) с откатом на
униграмму, плюс штраф за переключение языка относительно соседа. Побеждает
чтение с меньшим весом; при близких весах — молчим (как набрано).
"""
import argparse, json, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import fnv1a, fp16, lang_of, slots

class LM:
    def __init__(self, path):
        with open(path, "rb") as f:
            assert f.read(5) == b"QSNG2", "не QSNG2 — пересобери build.py"
            hl = struct.unpack("<I", f.read(4))[0]
            self.h = json.loads(f.read(hl))
            self.d = {}
            for lang in self.h["langs"]:
                ul, bl = struct.unpack("<II", f.read(8))
                self.d[lang] = (f.read(ul), f.read(bl))
        self.um = (1 << self.h["uni_bits"]) - 1
        self.bm = (1 << self.h["bi_bits"]) - 1
        self.scale = self.h["scale"]

    def get(self, table, mask, key):
        fp = fp16(key)
        for slot in slots(key, mask):
            i = slot * 3
            if (table[i] | (table[i + 1] << 8)) == fp: return table[i + 2] * self.scale
        return None

    def uni(self, lang, w): return self.get(self.d[lang][0], self.um, w)
    def bi(self, lang, p, w): return self.get(self.d[lang][1], self.bm, p + "\x1f" + w)

    # Штрафы: не видели пару — откат на униграмму с надбавкой; не видели слово — потолок.
    BACKOFF, UNSEEN, SWITCH = 1.2, 12.0, 0.7

    def cost(self, word, left=None, right=None):
        lang = lang_of(word)
        if not lang: return self.UNSEEN, "нет алфавита"
        u = self.uni(lang, word)
        if u is None: return self.UNSEEN, f"{lang}: слова нет"
        parts, c, why = [], 0.0, []
        for nb, order in ((left, "L"), (right, "R")):
            if not nb: continue
            nl = lang_of(nb)
            # Сосед другого алфавита: пары «да → lf» в английской модели быть не может,
            # сразу откат на униграмму + смена языка.
            b = None if (nl and nl != lang) else (self.bi(lang, nb, word) if order == "L" else self.bi(lang, word, nb))
            if b is not None:
                parts.append(b); why.append(f"пара {order} {b:.1f}")
            else:
                parts.append(u + self.BACKOFF); why.append(f"откат {order} {u + self.BACKOFF:.1f}")
            if nb and lang_of(nb) and lang_of(nb) != lang:
                c += self.SWITCH; why.append("смена языка +0.7")
        if not parts: parts = [u]; why.append(f"слово {u:.1f}")
        return sum(parts) / len(parts) + c, ", ".join(why)

def decide(lm, typed, swapped, left=None, right=None, margin=0.6):
    a, wa = lm.cost(typed, left, right)
    b, wb = lm.cost(swapped, left, right)
    win = swapped if b + margin < a else (typed if a + margin < b else None)
    return win, f"{typed} {a:.2f} ({wa}) vs {swapped} {b:.2f} ({wb}) → " + (win or "молчим")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "qsngram.bin"))
    ap.add_argument("--pair", required=True, help="набрано/свап, например lf/да")
    ap.add_argument("--left"); ap.add_argument("--right")
    ap.add_argument("--margin", type=float, default=0.6)
    a = ap.parse_args()
    lm = LM(a.model)
    t, s = a.pair.split("/")
    print(decide(lm, t.lower(), s.lower(), a.left, a.right, a.margin)[1])

if __name__ == "__main__":
    main()
