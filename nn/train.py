#!/usr/bin/env python3
"""
Обучение QSNet (numpy, без torch). Читает nn/data/corpus.tsv и words.tsv
(см. prepare_data.py), пишет qsnet.bin (формат QSN1, см. qsnet.py / README.md).

  python3 train.py                       # умолчания: 6 эпох, buckets=65536, dim=32, hidden=64
  python3 train.py --epochs 10 --out qsnet.bin

Архитектура (fastText-стиль + контекст):
  слово → хэшированные n-граммы клавиш (1..4) + слово целиком → среднее строк
  таблицы эмбеддингов (buckets×dim). То же для 3 предыдущих слов + флаг их языка.
  + класс приложения (one-hot 5) + текущая раскладка (one-hot 2)
  → полносвязный слой hidden (ReLU) → 1 логит → sigmoid = P(имелся в виду RU).

Аугментация (каждую эпоху заново): раскладка правильная/неправильная 80/20,
флаги контекста портятся в 5%, в 10% контекст подменяется чужим языком
(code-switch), в 15% контекста нет, в 10% класс приложения случайный.
"""
import argparse
import math
import os
import random
import sys
import time

import numpy as np

# Accelerate на Apple Silicon поднимает флаги FP-исключений внутри matmul при
# корректном результате — numpy честно на них ругается. Глушим; реальный взрыв
# ловится проверкой на конечность loss в train.py.
np.seterr(all="ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsnet  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
D_CTX = qsnet.CTX_WORDS
N_FLAG = len(qsnet.CTX_FLAGS)
N_APP = len(qsnet.APPS)
N_LAY = len(qsnet.LANGS)
SLOTS = 1 + D_CTX  # слово + контекстные слова


# ------------------------------------------------------------------ данные

def tokenize(text):
    """Строка → список токенов (keys|None, lang|None). lang по алфавиту токена
    даже если keys нет (для флага контекста)."""
    toks = []
    for raw in text.split():
        w = raw.lower()
        # обрезаем снаружи всё, что не буква (кавычки, скобки, точки, дефисы)
        i, j = 0, len(w)
        while i < j and not (qsnet.is_lat(w[i]) or qsnet.is_cyr(w[i])):
            i += 1
        while j > i and not (qsnet.is_lat(w[j - 1]) or qsnet.is_cyr(w[j - 1])):
            j -= 1
        w = w[i:j]
        if not w:
            continue
        lang = qsnet.word_lang(w)
        keys = qsnet.to_keys(w) if lang else None
        toks.append((keys, lang))
    return toks


def load_corpus(path, limit=None):
    lines = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            app, w, text = parts
            if app not in qsnet.APPS:
                app = "other"
            toks = tokenize(text)
            if any(k for k, _ in toks):
                lines.append((qsnet.APPS.index(app), float(w), toks))
            if limit and len(lines) >= limit:
                break
    return lines


def load_words(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            lang, w, word = parts
            keys = qsnet.to_keys(word)
            if keys and lang in ("ru", "en"):
                out.append((keys, 1 if lang == "ru" else 0, float(w)))
    return out


class Sampler:
    """Генерирует обучающие примеры с аугментацией."""

    def __init__(self, lines, words, rng, train=True):
        self.lines, self.words, self.rng, self.train = lines, words, rng, train
        self.index = [(li, ti) for li, (_, _, toks) in enumerate(lines)
                      for ti, (k, l) in enumerate(toks) if k]
        # пулы контекстов по языку для подмены (code-switch)
        self.pool = {0: [], 1: []}
        for _, _, toks in lines:
            for i in range(1, len(toks)):
                if toks[i][0] and toks[i][1]:
                    self.pool[1 if toks[i][1] == "ru" else 0].append(toks[max(0, i - D_CTX):i][::-1])
        for k in self.pool:
            if len(self.pool[k]) > 200_000:
                self.pool[k] = rng.sample(self.pool[k], 200_000)

    def __len__(self):
        return len(self.index) + len(self.words)

    def ctx_of(self, toks, ti):
        return [(k, (l or "none")) for k, l in toks[max(0, ti - D_CTX):ti][::-1]]

    def sample(self, n):
        """Возвращает список (keys, ctx, app, layout, label, weight)."""
        rng = self.rng
        out = []
        n_words = int(n * len(self.words) / max(1, len(self)))
        for _ in range(n - n_words):
            li, ti = rng.choice(self.index)
            app, w, toks = self.lines[li]
            keys, lang = toks[ti]
            label = 1 if lang == "ru" else 0
            ctx = self.ctx_of(toks, ti)
            if self.train:
                r = rng.random()
                if r < 0.15:
                    ctx = []
                elif r < 0.25 and self.pool[1 - label]:
                    ctx = [(k, (l or "none")) for k, l in rng.choice(self.pool[1 - label])]
                if rng.random() < 0.10:
                    app = rng.randrange(N_APP)
                ctx = [(k, self.flip(fl)) for k, fl in ctx]
            out.append((keys, ctx, app, self.layout(label), label, w))
        for _ in range(n_words):
            keys, label, w = rng.choice(self.words)
            out.append((keys, [], rng.randrange(N_APP), self.layout(label), label, w))
        return out

    def flip(self, flag):
        if self.train and flag != "none" and self.rng.random() < 0.05:
            return "en" if flag == "ru" else "ru"
        return flag

    def layout(self, label):
        """Раскладка, в которой слово «набирали»: правильная в 80%, иначе чужая."""
        intended = "ru" if label == 1 else "en"
        if self.rng.random() < 0.8:
            return intended
        return "en" if intended == "ru" else "ru"


# ------------------------------------------------------------------ батч

class Batch:
    """Плоские индексы для усреднения эмбеддингов по слотам + плотные признаки."""

    def __init__(self, samples, buckets, dim):
        B = len(samples)
        self.B = B
        self.idx, self.seg, self.cnt = [], [], []
        for s in range(SLOTS):
            idx, seg = [], []
            cnt = np.zeros(B, np.float32)
            for b, (keys, ctx, app, lay, label, w) in enumerate(samples):
                k = keys if s == 0 else (ctx[s - 1][0] if s - 1 < len(ctx) else None)
                if k:
                    bk = qsnet.word_buckets(k, buckets)
                    idx += bk
                    seg += [b] * len(bk)
                    cnt[b] = len(bk)
            self.idx.append(np.asarray(idx, np.int64))
            self.seg.append(np.asarray(seg, np.int64))
            self.cnt.append(np.maximum(cnt, 1))
        self.dense = np.zeros((B, D_CTX * N_FLAG + N_APP + N_LAY), np.float32)
        self.y = np.zeros(B, np.float32)
        self.w = np.zeros(B, np.float32)
        for b, (keys, ctx, app, lay, label, w) in enumerate(samples):
            for c in range(D_CTX):
                fl = ctx[c][1] if c < len(ctx) else "none"
                self.dense[b, c * N_FLAG + qsnet.CTX_FLAGS.index(fl)] = 1
            self.dense[b, D_CTX * N_FLAG + app] = 1
            self.dense[b, D_CTX * N_FLAG + N_APP + qsnet.LANGS.index(lay)] = 1
            self.y[b] = label
            self.w[b] = w
        self.dim = dim

    def assemble(self, emb):
        """→ X (B×input_dim) в том же порядке, что qsnet.QSNet.build_input."""
        B, D = self.B, self.dim
        vecs = []
        for s in range(SLOTS):
            V = np.zeros((B, D), np.float32)
            if len(self.idx[s]):
                np.add.at(V, self.seg[s], emb[self.idx[s]])
                V /= self.cnt[s][:, None]
            vecs.append(V)
        parts = [vecs[0]]
        for c in range(D_CTX):
            parts.append(vecs[1 + c])
            parts.append(self.dense[:, c * N_FLAG:(c + 1) * N_FLAG])
        parts.append(self.dense[:, D_CTX * N_FLAG:])
        return np.concatenate(parts, axis=1)

    def scatter(self, dX, buckets, dim):
        """dX → градиент строк эмбеддингов: (unique_rows, dRows)."""
        B, D = self.B, dim
        rows, grads = [], []
        col = 0
        for s in range(SLOTS):
            dV = dX[:, col:col + D]
            col += D + (N_FLAG if s >= 1 else 0)   # слово: D; ctx-слот: D + флаг
            if len(self.idx[s]):
                rows.append(self.idx[s])
                grads.append(dV[self.seg[s]] / self.cnt[s][self.seg[s]][:, None])
        if not rows:
            return None, None
        rows = np.concatenate(rows)
        grads = np.concatenate(grads)
        uniq, inv = np.unique(rows, return_inverse=True)
        g = np.zeros((len(uniq), D), np.float32)
        np.add.at(g, inv, grads)
        return uniq, g


# ------------------------------------------------------------------ модель

class Model:
    def __init__(self, buckets, dim, hidden, rng):
        self.buckets, self.dim, self.hidden = buckets, dim, hidden
        nin = qsnet.input_dim(dim)
        self.p = {
            "emb": rng.uniform(-1.0 / dim, 1.0 / dim, (buckets, dim)).astype(np.float32),
            "w1": (rng.standard_normal((nin, hidden)) * math.sqrt(2.0 / nin)).astype(np.float32),
            "b1": np.zeros(hidden, np.float32),
            "w2": (rng.standard_normal(hidden) * math.sqrt(1.0 / hidden)).astype(np.float32),
            "b2": np.zeros(1, np.float32),
        }
        self.m = {k: np.zeros_like(v) for k, v in self.p.items()}
        self.v = {k: np.zeros_like(v) for k, v in self.p.items()}
        self.t = 0

    def forward(self, X):
        h_pre = X @ self.p["w1"] + self.p["b1"]
        h = np.maximum(h_pre, 0)
        z = h @ self.p["w2"] + self.p["b2"][0]
        return h_pre, h, z

    def step(self, batch, lr, l2=1e-6, smooth=0.02):
        X = batch.assemble(self.p["emb"])
        h_pre, h, z = self.forward(X)
        p = 1 / (1 + np.exp(-z))
        w = batch.w / batch.w.mean()
        y = batch.y * (1 - 2 * smooth) + smooth   # сглаживание меток — не даёт вероятностям липнуть к 0/1
        loss = -(w * (y * np.log(p + 1e-7) + (1 - y) * np.log(1 - p + 1e-7))).mean()
        dz = (p - y) * w / batch.B
        g = {
            "w2": h.T @ dz,
            "b2": np.array([dz.sum()], np.float32),
        }
        dh = np.outer(dz, self.p["w2"]) * (h_pre > 0)
        g["w1"] = X.T @ dh
        g["b1"] = dh.sum(axis=0)
        dX = dh @ self.p["w1"].T
        rows, grows = batch.scatter(dX, self.buckets, self.dim)

        self.t += 1
        b1, b2, eps = 0.9, 0.999, 1e-8
        corr = math.sqrt(1 - b2 ** self.t) / (1 - b1 ** self.t)
        for k, gk in g.items():
            gk = gk + l2 * self.p[k]
            self.m[k] = b1 * self.m[k] + (1 - b1) * gk
            self.v[k] = b2 * self.v[k] + (1 - b2) * gk * gk
            self.p[k] -= lr * corr * self.m[k] / (np.sqrt(self.v[k]) + eps)
        if rows is not None:  # ленивый Adam по затронутым строкам
            m = self.m["emb"][rows]
            v = self.v["emb"][rows]
            m = b1 * m + (1 - b1) * grows
            v = b2 * v + (1 - b2) * grows * grows
            self.m["emb"][rows] = m
            self.v["emb"][rows] = v
            self.p["emb"][rows] -= lr * corr * m / (np.sqrt(v) + eps)
        acc = ((p >= 0.5) == (batch.y >= 0.5)).mean()
        return float(loss), float(acc)

    def predict(self, batch):
        X = batch.assemble(self.p["emb"])
        _, _, z = self.forward(X)
        return 1 / (1 + np.exp(-z))


# ------------------------------------------------------------------ оценка

def evaluate(model, sampler, n, rng, buckets, dim):
    samples = sampler.sample(n)
    p = model.predict(Batch(samples, buckets, dim))
    y = np.array([s[4] for s in samples])
    ok = (p >= 0.5) == (y >= 0.5)
    res = {"all": ok.mean()}
    short = np.array([len(s[0]) <= 3 for s in samples])
    if short.any():
        res["short≤3"] = ok[short].mean()
    noctx = np.array([len(s[1]) == 0 for s in samples])
    if noctx.any():
        res["без ctx"] = ok[noctx].mean()
        res["с ctx"] = ok[~noctx].mean()
    conf = np.maximum(p, 1 - p)
    for thr in (0.85, 0.95):
        sure = conf >= thr
        res[f"уверен≥{thr}"] = f"{sure.mean():.0%} примеров, точность {ok[sure].mean():.3f}" if sure.any() else "—"
    for ai, app in enumerate(qsnet.APPS):
        m = np.array([s[2] == ai for s in samples])
        if m.any():
            res[app] = ok[m].mean()
    return res


SANITY = [
    # (слово как набрано, контекст на экране, app, раскладка, ожидание)
    ("ghbdtn", "", "other", "en", "ru"),
    ("hello", "", "other", "en", "en"),
    ("руддщ", "", "other", "ru", "en"),
    ("привет", "", "other", "ru", "ru"),
    ("dns", "cat /etc/resolv.conf", "terminal", "en", "en"),
    ("днс", "прописал в конфиге", "chat", "ru", "ru"),
    ("вты", "cat /etc/resolv.conf", "terminal", "ru", "en"),
    ("yt", "я этого", "chat", "en", "ru"),
    ("yt", "", "other", "en", "ru"),
    ("dct", "мы", "chat", "en", "ru"),
    ("dmg", "open", "terminal", "en", "en"),
    ("jpg", "", "other", "en", "en"),
    ("sql", "select from", "code", "en", "en"),
    ("git", "cd repo", "terminal", "en", "en"),
    ("пше", "cd repo", "terminal", "ru", "en"),
    ("ру", "а он", "chat", "ru", "ru"),   # 'he' частое, «ру» в корпусах нет — это дело щита/personal.txt
    ("gbitim", "ты", "chat", "en", "ru"),
    ("ntcn", "", "other", "en", "ru"),
    ("ntcn", "run the", "terminal", "en", "ru"),
]


def sanity(model):
    net = qsnet.QSNet({"buckets": model.buckets, "dim": model.dim}, model.p)
    print("  слово        ctx                     app       lay  P(ru)  →    ждём")
    bad = 0
    for word, ctx, app, lay, want in SANITY:
        keys = qsnet.to_keys(word)
        p = net.p_ru(keys, qsnet.ctx_from_text(ctx), app, lay)
        got = "ru" if p >= 0.5 else "en"
        mark = "" if got == want else "  ✗"
        bad += got != want
        print(f"  {word:12s} {ctx[:22]:22s}  {app:8s}  {lay}   {p:.3f}  {got}   {want}{mark}")
    print(f"  промахов: {bad}/{len(SANITY)}")


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(DATA, "corpus.tsv"))
    ap.add_argument("--words", default=os.path.join(DATA, "words.tsv"))
    ap.add_argument("--out", default=os.path.join(HERE, "qsnet.bin"))
    ap.add_argument("--buckets", type=int, default=65536)
    ap.add_argument("--dim", type=int, default=32)
    ap.add_argument("--hidden", type=int, default=64)
    ap.add_argument("--epochs", type=int, default=6)
    ap.add_argument("--batch", type=int, default=512)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--samples-per-epoch", type=int, default=2_000_000, help="0 = размер индекса")
    ap.add_argument("--limit-lines", type=int, default=0, help="для быстрых проб")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    nrng = np.random.default_rng(a.seed)

    t0 = time.time()
    lines = load_corpus(a.corpus, a.limit_lines or None)
    words = load_words(a.words)
    rng.shuffle(lines)
    rng.shuffle(words)
    n_val_l, n_val_w = max(1, len(lines) // 33), max(1, len(words) // 33)
    val = Sampler(lines[:n_val_l], words[:n_val_w], random.Random(99), train=False)
    train = Sampler(lines[n_val_l:], words[n_val_w:], rng, train=True)

    # баланс классов по суммарному весу
    tot = {0: 0.0, 1: 0.0}
    for li, ti in train.index:
        app, w, toks = train.lines[li]
        tot[1 if toks[ti][1] == "ru" else 0] += w
    for _, label, w in train.words:
        tot[label] += w
    scale = {k: (tot[0] + tot[1]) / (2 * max(tot[k], 1e-9)) for k in tot}
    print(f"строк {len(lines)}, слов {len(words)}, примеров в эпохе ≈ {len(train)} "
          f"(ru {tot[1]:.0f} / en {tot[0]:.0f} по весу, баланс ×{scale[1]:.2f}/×{scale[0]:.2f}), "
          f"загрузка {time.time() - t0:.0f}с")

    model = Model(a.buckets, a.dim, a.hidden, nrng)
    per_epoch = min(a.samples_per_epoch, len(train)) if a.samples_per_epoch else len(train)
    steps = max(1, per_epoch // a.batch)
    total_steps = steps * a.epochs
    step = 0
    for ep in range(1, a.epochs + 1):
        t1 = time.time()
        sl, sa = 0.0, 0.0
        for i in range(steps):
            samples = train.sample(a.batch)
            samples = [(k, c, ap_, l, y, w * scale[y]) for k, c, ap_, l, y, w in samples]
            lr = a.lr * 0.5 * (1 + math.cos(math.pi * step / total_steps))  # косинус до нуля
            step += 1
            loss, acc = model.step(Batch(samples, a.buckets, a.dim), lr)
            if not math.isfinite(loss):
                sys.exit(f"❌ loss стал {loss} на шаге {step} — сеть разошлась, уменьши --lr")
            sl += loss
            sa += acc
            if (i + 1) % 200 == 0:
                print(f"  эпоха {ep} шаг {i + 1}/{steps} loss {sl / (i + 1):.4f} acc {sa / (i + 1):.4f}", flush=True)
        res = evaluate(model, val, 20000, rng, a.buckets, a.dim)
        print(f"эпоха {ep}/{a.epochs}: loss {sl / steps:.4f} train-acc {sa / steps:.4f} | val: " +
              ", ".join(f"{k} {v:.4f}" if isinstance(v, float) else f"{k} {v}" for k, v in res.items()) +
              f" | {time.time() - t1:.0f}с", flush=True)

    print("Проверка на знакомых случаях:")
    sanity(model)

    res = evaluate(model, val, 40000, rng, a.buckets, a.dim)
    meta = {
        "buckets": a.buckets, "dim": a.dim, "hidden": a.hidden,
        "trained": time.strftime("%Y-%m-%d %H:%M"),
        "epochs": a.epochs, "lines": len(lines), "words": len(words),
        "val_acc": round(float(res["all"]), 4),
        "val_acc_short": round(float(res.get("short≤3", 0)), 4),
    }
    qsnet.save_qsn(a.out, model.p, meta)
    print(f"✅ веса: {a.out} ({os.path.getsize(a.out) / 1e6:.1f} МБ), val acc {meta['val_acc']}, "
          f"короткие {meta['val_acc_short']}")

    # эталонная проверка: файл читается и даёт то же, что модель в памяти
    header, params = qsnet.load_qsn(a.out)
    net = qsnet.QSNet(header, params)
    k = qsnet.to_keys("ghbdtn")
    assert abs(net.p_ru(k) - qsnet.QSNet({"buckets": a.buckets, "dim": a.dim}, model.p).p_ru(k)) < 1e-6
    print("   перечитан и сверен")


if __name__ == "__main__":
    main()
