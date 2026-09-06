#!/usr/bin/env python3
"""
Профиль пользователя — эталон формата и логики, который повторят Swift/C#.
Это второй слой (первый — общие векторы qsvec.bin, третий — тема окна в памяти).

Профиль хранит ЧТЕНИЯ коллизий: у клавиш (например 'ha') есть варианты 'HA' и 'РФ',
и у каждого варианта копится:
  * topic  — центроид тем окна, в которых пользователь его выбирал;
  * left   — центроид ЛЕВЫХ соседей (слово перед): 'сервер', 'настроил' vs 'ip', 'в';
  * case   — как он его набирает: {"lower": n, "upper": n, "title": n};
  * count, updated — для слияния при синке.

Решение (decide): считаем для каждого чтения балл
    w_left · cos(left_ctx, reading.left) + w_topic · cos(topic, reading.topic) + w_case · case_fit
Побеждает лучшее, НО только если отрыв от второго больше margin — иначе оставляем
как набрано. Пропущенный свап чинится одним тапом, ложный портит текст.

Синк: файл profile.json, слияние по (keys, reading) — центроиды складываются с
весами count, счётчики суммируются, при конфликте берётся более свежий updated.
Ничего лишнего (сырых фраз) не хранится, только векторы — это и приватность, и объём.
"""
import argparse
import json
import os
import re
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsvec  # noqa: E402

W_LEFT, W_TOPIC, W_CASE = 1.0, 0.6, 0.4
MARGIN = 0.10          # отрыв лидера, ниже которого не вмешиваемся
CASE_MIN = 3           # с какого числа примеров регистр вообще учитывается
SINGLE_MIN = 0.35      # порог для клавиш с единственным чтением
MIN_SIGNAL = 0.25      # у победителя сосед или тема должны быть хотя бы такими
TOP_K = 2              # балл чтения — среднее по K ближайшим примерам
W_TOPICS = 0.8         # вес совпадения гистограмм тем (обобщение по осмысленным осям)
SEED_WEIGHT = 3        # вес строки «#тема …» (описание темы словами)
MAX_EXAMPLES = 300     # примеров на чтение (старые с весом 1 вытесняются)


def case_of(word):
    if word.isupper() and len(word) > 1:
        return "upper"
    if word[:1].isupper():
        return "title"
    return "lower"


class Profile:
    """Формат 2: у чтения не центроид, а САМИ примеры (тема, сосед, вес, регистр).
    Сравниваем с ближайшими, а не со средним: «HA» — это десяток конкретных
    ситуаций, и чужое слово ни к одной из них не близко → молчим. Тематика
    настолько широка, насколько разнообразны примеры, без ручных категорий."""

    def __init__(self, dim, path=None, topics=None):
        self.dim = dim
        self.path = path
        self.readings = {}   # keys → { text → {"ex": [...], "tp": гистограмма тем, "case": {}, "count", "updated"} }
        self.topics = topics   # {"centers": np.array(k×dim), "names": [...], "tau": float} или None

    @staticmethod
    def load_topics(path):
        if not path or not os.path.exists(path):
            return None
        with open(path, encoding="utf-8") as f:
            t = json.load(f)
        return {"centers": np.array(t["centers"], np.float32), "names": t["names"], "tau": float(t.get("tau", 8.0))}

    def assign(self, vec):
        """Единичный вектор → распределение по темам (softmax по косинусу)."""
        if self.topics is None or vec is None:
            return None
        n = np.linalg.norm(vec)
        if n == 0:
            return None
        s = self.topics["centers"] @ (vec / n)
        p = np.exp(self.topics["tau"] * (s - s.max()))
        return (p / p.sum()).astype(np.float32)

    def ctx_dist(self, topic_vec, left_vec):
        """Распределение контекста: тема окна и левый сосед пополам."""
        parts = [d for d in (self.assign(topic_vec), self.assign(left_vec)) if d is not None]
        if not parts:
            return None
        d = sum(parts) / len(parts)
        return d / d.sum()

    @staticmethod
    def hist_sim(a, b):
        """Сходство гистограмм: косинус корней (устойчив к разной массе)."""
        if a is None or b is None or a.sum() == 0 or b.sum() == 0:
            return 0.0
        x, y = np.sqrt(a / a.sum()), np.sqrt(b / b.sum())
        return float(x @ y)

    def explain_dist(self, d, n=3):
        if d is None or self.topics is None:
            return "—"
        d = d / d.sum() if d.sum() > 0 else d
        idx = np.argsort(-d)[:n]
        return ", ".join(f"{self.topics['names'][i].split('/')[0]} {d[i]:.2f}" for i in idx)

    # ---------------------------------------------------------------- ввод-вывод

    @staticmethod
    def load(path, dim):
        p = Profile(dim, path)
        if not os.path.exists(path):
            return p
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        if d.get("format", 1) < 2:
            return p   # старый формат (центроиды) — пересобрать из журнала
        p.dim = d.get("dim", dim)
        for keys, readings in (d.get("readings") or {}).items():
            p.readings[keys] = {}
            for text, r in readings.items():
                ex = [(np.array(e[0], np.float32), np.array(e[1], np.float32) if e[1] else None,
                       int(e[2]), e[3], int(e[4])) for e in r.get("ex", [])]
                p.readings[keys][text] = {"ex": ex, "case": r.get("case", {}),
                                          "tp": np.array(r["tp"], np.float32) if r.get("tp") else None,
                                          "count": r.get("count", 0), "updated": r.get("updated", 0)}
        return p

    def save(self, path=None):
        path = path or self.path
        rd = lambda v: [round(float(x), 3) for x in v] if v is not None else None
        d = {"format": 2, "dim": self.dim, "saved": int(time.time()), "readings": {
            keys: {text: {"ex": [[rd(t), rd(l), w, c, ts] for t, l, w, c, ts in r["ex"]],
                          "tp": rd(r["tp"]) if r.get("tp") is not None else None,
                          "case": r["case"], "count": r["count"], "updated": r["updated"]}
                   for text, r in readings.items()}
            for keys, readings in self.readings.items()}}
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False)
        os.replace(tmp, path)

    # ---------------------------------------------------------------- обучение

    def observe(self, keys, text, topic_vec, left_vec, weight=1):
        r = self.readings.setdefault(keys, {}).setdefault(text.lower(), {"ex": [], "tp": None, "case": {}, "count": 0, "updated": 0})
        w = max(1, int(weight))
        unit = lambda v: (v / np.linalg.norm(v)).astype(np.float32) if v is not None and np.linalg.norm(v) > 0 else None
        t, l = unit(topic_vec), unit(left_vec)
        if t is None and l is None:
            return
        d = self.ctx_dist(t, l)
        if d is not None:
            r["tp"] = d * w if r.get("tp") is None else r["tp"] + d * w
        c = case_of(text)
        r["ex"].append((t if t is not None else np.zeros(self.dim, np.float32), l, w, c, int(time.time())))
        while len(r["ex"]) > MAX_EXAMPLES:
            # вытесняем самый старый с весом 1; если таких нет — самый старый
            idx = next((i for i, e in enumerate(r["ex"]) if e[2] <= 1), 0)
            r["ex"].pop(idx)
        r["case"][c] = r["case"].get(c, 0) + w
        r["count"] += w
        r["updated"] = int(time.time())

    # ---------------------------------------------------------------- обучение текстом

    @staticmethod
    def parse_line(line):
        """'живу в рф [10]' → (слова, индекс цели, вес). Цель — слово в *звёздочках*
        или последнее; вес — [n] в конце. None, если учить нечему."""
        line = line.strip()
        if not line or line.startswith("#"):
            return None
        line = line.split("#", 1)[0].strip()   # хвостовой комментарий — только для человека
        if not line:
            return None
        weight = 1
        m = re.search(r"\[\s*(\d+)\s*\]\s*$", line)
        if m:
            weight = int(m.group(1))
            line = line[:m.start()].strip()
        tokens = line.split()
        target = None
        words = []
        for t in tokens:
            core = t.strip(".,;:!?()«»\"'")
            if core.startswith("*") and core.endswith("*") and len(core) > 2:
                core = core[1:-1]
                target = len(words)
            core = "".join(ch for ch in core if ch.isalpha())
            if core:
                words.append(core)
        if not words:
            return None
        if target is None:
            target = len(words) - 1
        return words, target, weight

    def seed_topic(self, reading_text, words, vec, to_keys, weight=SEED_WEIGHT):
        """«#тема HA: home assistant умный дом датчики шлюз» — готовое облако чтения
        без примеров: тема из слов + гистограмма тем; левого соседа нет."""
        keys = to_keys(reading_text.lower())
        if not keys or len(keys) < 2 or not words:
            return False
        self.observe(keys, reading_text, vec.topic(list(reversed(words))), None, weight)
        return True

    def train_text(self, text, vec, to_keys):
        lines = examples = 0
        touched = set()
        for raw in text.splitlines():
            m = re.match(r"^\s*#тема\s+(\S+)\s*:\s*(.+?)\s*(\[\s*(\d+)\s*\])?\s*$", raw)
            if m:
                words = [w for w in re.findall(r"[^\W\d_]+", m.group(2))]
                w = int(m.group(4)) if m.group(4) else SEED_WEIGHT
                if self.seed_topic(m.group(1), words, vec, to_keys, w):
                    lines += 1
                    examples += w
                    touched.add(to_keys(m.group(1).lower()))
                continue
            parsed = self.parse_line(raw)
            if not parsed:
                continue
            words, ti, weight = parsed
            keys = to_keys(words[ti].lower())
            if not keys or len(keys) < 2:
                continue
            others = words[:ti] + words[ti + 1:]
            topic = vec.topic(list(reversed(others))) if others else None
            left = vec.centered(words[ti - 1]) if ti > 0 else None
            self.observe(keys, words[ti], topic, left, weight)
            lines += 1
            examples += weight
            touched.add(keys)
        return lines, examples, sorted(touched)

    # ---------------------------------------------------------------- решение

    def case_fit(self, r, typed_case):
        total = sum(r["case"].values())
        if total < CASE_MIN:
            return 0.0
        share = r["case"].get(typed_case, 0) / total
        return 2 * share - 1

    def decide(self, keys, typed, topic_vec, left_vec):
        """→ (текст, балл, отрыв, объяснение) или (None, объяснение)."""
        readings = self.readings.get(keys)
        if not readings:
            return None, ""
        unit = lambda v: v / (np.linalg.norm(v) + 1e-9)
        tq = unit(topic_vec) if topic_vec is not None and np.linalg.norm(topic_vec) > 0 else None
        lq = unit(left_vec) if left_vec is not None else None
        typed_case = case_of(typed)
        ctx_d = self.ctx_dist(tq, lq)
        scored = []
        for text, r in readings.items():
            sims = []
            for t, l, w, c, ts in r["ex"]:
                sl = float(lq @ l) if (lq is not None and l is not None) else None
                st = float(tq @ t) if (tq is not None and np.linalg.norm(t) > 0) else None
                s = (W_LEFT * sl if sl is not None else 0) + (W_TOPIC * st if st is not None else 0)
                sims.append((s, sl or 0.0, st or 0.0))
            if not sims:
                continue
            sims.sort(reverse=True)
            top = sims[:TOP_K]
            s = sum(x[0] for x in top) / len(top)
            best = max(max(x[1], x[2]) for x in top)
            # темы: обобщение по осмысленным осям — «шлюхи» к «людям/стране», «шлюз» к «сети»
            th = self.hist_sim(r.get("tp"), ctx_d)
            s += W_TOPICS * th
            best = max(best, th)
            cf = self.case_fit(r, typed_case)
            s += W_CASE * cf
            scored.append((s, text, best, f"{text} {s:+.2f} (темы {th:.2f} [{self.explain_dist(r.get('tp'))}], сосед {top[0][1]:.2f}, тема {top[0][2]:.2f}, регистр {cf:+.1f}, прим. {len(sims)})"))
        if not scored:
            return None, ""
        scored.sort(reverse=True)
        explain = " vs ".join(x[3] for x in scored)
        if scored[0][2] < MIN_SIGNAL:
            return None, explain + f" — сигнал слаб (< {MIN_SIGNAL})"
        if len(scored) == 1:
            need = max(MARGIN, SINGLE_MIN)
            return ((scored[0][1], scored[0][0], scored[0][0], explain) if scored[0][0] >= need else (None, explain))
        lead = scored[0][0] - scored[1][0]
        if lead < MARGIN:
            return None, explain
        return scored[0][1], scored[0][0], lead, explain

    # ---------------------------------------------------------------- синк

    def merge(self, other):
        """Слияние профилей: примеры объединяются (одинаковые по времени и вектору не дублируются)."""
        for keys, readings in other.readings.items():
            mine = self.readings.setdefault(keys, {})
            for text, r in readings.items():
                a = mine.setdefault(text, {"ex": [], "case": {}, "count": 0, "updated": 0})
                seen = {(e[4], round(float(e[0][0]), 3)) for e in a["ex"]}
                for e in r["ex"]:
                    if (e[4], round(float(e[0][0]), 3)) not in seen:
                        a["ex"].append(e)
                        a["count"] += e[2]
                        a["case"][e[3]] = a["case"].get(e[3], 0) + e[2]
                a["ex"].sort(key=lambda e: e[4])
                a["ex"] = a["ex"][-MAX_EXAMPLES:]
                if r.get("tp") is not None:
                    a["tp"] = r["tp"] if a.get("tp") is None else a["tp"] + r["tp"]
                a["updated"] = max(a["updated"], r["updated"])


# ---------------------------------------------------------------- CLI (проверка)

def main(argv):
    ap = argparse.ArgumentParser(description="профиль чтений: обучение и проверка")
    ap.add_argument("vectors")
    ap.add_argument("--profile", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "profile.json"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("observe", help="запомнить выбор: клавиши, чтение, фраза до слова")
    o.add_argument("keys"); o.add_argument("text"); o.add_argument("context")
    d = sub.add_parser("decide", help="что выбрать: клавиши, как набрано, фраза до слова")
    d.add_argument("keys"); d.add_argument("typed"); d.add_argument("context")
    t = sub.add_parser("train", help="обучить на тексте: строка = пример, цель последняя или *в звёздочках*, вес [n]")
    t.add_argument("file")
    sub.add_parser("show", help="что в профиле")
    a = ap.parse_args(argv)

    m = qsvec.QSVec(a.vectors)
    topics = Profile.load_topics(os.path.join(os.path.dirname(a.vectors), "qsvec-topics.json"))
    p = Profile.load(a.profile, m.h["dim"])
    p.topics = topics
    if a.cmd == "observe":
        words = a.context.split()
        p.observe(a.keys, a.text, m.topic(words), m.centered(words[-1]) if words else None)
        p.save(a.profile)
        print(f"✅ {a.keys} → {a.text}; чтений: {list(p.readings[a.keys])}")
    elif a.cmd == "decide":
        words = a.context.split()
        res = p.decide(a.keys, a.typed, m.topic(words), m.centered(words[-1]) if words else None)
        if res[0] is None:
            print(f"не уверен → оставляем как набрано   [{res[1]}]")
        else:
            text, score, lead, explain = res
            print(f"→ {text}  (балл {score:+.3f}, отрыв {lead:.3f})   [{explain}]")
    elif a.cmd == "train":
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
        import qsnet
        with open(a.file, encoding="utf-8") as f:
            lines, examples, touched = p.train_text(f.read(), m, qsnet.to_keys)
        p.save(a.profile)
        print(f"✅ строк {lines}, примеров {examples}, клавиши: {', '.join(touched)}")
    else:
        for keys, readings in p.readings.items():
            for text, r in readings.items():
                print(f"  {keys} → {text}: примеров {r['count']} (хранится {len(r['ex'])}), регистр {r['case']}, темы: {p.explain_dist(r.get('tp'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
