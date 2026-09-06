#!/usr/bin/env python3
"""
Дообучение QSNet на личных примерах — эталон алгоритма, который повторяют
LayoutNet.swift / LayoutNet.cs по пункту меню «Дообучить на моих исправлениях».

  python3 finetune.py [--base qsnet.bin] [--out qsnet-user.bin] examples.jsonl

examples.jsonl — по строке на пример:
  {"keys":"he","ctx":[["f","ru"],["jy","ru"]],"app":"chat","layout":"ru","label":"ru"}
  ctx: ближайшее слово первым, до 3; label — какой язык имелся в виду.

Алгоритм (обе платформы ровно так):
  * старт с текущих весов (базовых или уже дообученных);
  * каждый пример ×2: как есть и с противоположной раскладкой (намерение от
    раскладки не зависит), плюс копия без контекста, если контекст был;
  * полный батч, EPOCHS шагов простого градиентного спуска с шагом LR;
  * обучаются голова (w1, b1, w2, b2) и только ЗАТРОНУТЫЕ строки эмбеддингов;
  * притяжение к исходным весам: + LAMBDA·(w − w0)² на голову, чтобы не забыть
    общее ради десятка личных слов;
  * в конце — отчёт: сколько примеров сеть отвечает правильно до/после.
"""
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsnet  # noqa: E402

EPOCHS = 300
LR = 0.05
LAMBDA = 0.05
SMOOTH = 0.02
PERSONAL_WEIGHT = 20.0   # личный пример весит как двадцать общих


def expand(examples):
    out = []
    for e in examples:
        ctx = [(k, f) for k, f in e.get("ctx", [])][:qsnet.CTX_WORDS]
        for lay in (e["layout"], "en" if e["layout"] == "ru" else "ru"):
            out.append((e["keys"], ctx, e["app"], lay, 1.0 if e["label"] == "ru" else 0.0))
            if ctx:
                out.append((e["keys"], [], e["app"], lay, 1.0 if e["label"] == "ru" else 0.0))
    return out


def finetune(header, params, examples, replay=(), log=print):
    """examples — личные, replay — общие (qsnet-replay.json), чтобы не забыть базу."""
    net = qsnet.QSNet(header, params)
    D, H = header["dim"], header["hidden"]
    personal = expand(examples)
    generic = [(e["keys"], [(k, f) for k, f in e.get("ctx", [])], e["app"], e["layout"],
                1.0 if e["label"] == "ru" else 0.0) for e in replay]
    samples = personal + generic
    W = np.array([PERSONAL_WEIGHT] * len(personal) + [1.0] * len(generic), np.float32)
    W /= W.mean()
    # входы фиксированы структурой; пересчитываем векторы слов каждый шаг,
    # потому что строки эмбеддингов учатся
    rows = []   # для каждого сэмпла: список (offset, [bucket…])
    dense = []  # плотная часть входа (флаги, app, раскладка) — не учится
    for keys, ctx, app, lay, y in samples:
        slots = [(0, qsnet.word_buckets(keys, header["buckets"]))]
        off = D
        for i in range(qsnet.CTX_WORDS):
            ck = ctx[i][0] if i < len(ctx) and ctx[i][0] else None
            if ck:
                slots.append((off, qsnet.word_buckets(ck, header["buckets"])))
            off += D + len(qsnet.CTX_FLAGS)
        rows.append(slots)
        dense.append(net.build_input(keys, ctx, app, lay))   # полный вход как база
    # плоские индексы для векторного обновления эмбеддингов
    flat_rows, flat_i, flat_off, flat_cnt = [], [], [], []
    for i, slots in enumerate(rows):
        for off, bk in slots:
            for r in bk:
                flat_rows.append(r); flat_i.append(i); flat_off.append(off); flat_cnt.append(len(bk))
    flat_rows = np.array(flat_rows); flat_i = np.array(flat_i)
    flat_off = np.array(flat_off); flat_cnt = np.array(flat_cnt, np.float32)
    Y = np.array([s[4] for s in samples], np.float32)
    Yt = Y * (1 - 2 * SMOOTH) + SMOOTH

    emb = params["emb"].astype(np.float32).copy()
    w1, b1 = params["w1"].astype(np.float32).copy(), params["b1"].astype(np.float32).copy()
    w2, b2 = params["w2"].astype(np.float32).copy(), params["b2"].astype(np.float32).copy()
    w1_0, b1_0, w2_0, b2_0 = w1.copy(), b1.copy(), w2.copy(), b2.copy()

    def assemble():
        X = np.stack(dense).copy()
        for i, slots in enumerate(rows):
            for off, bk in slots:
                X[i, off:off + D] = emb[bk].mean(axis=0)
        return X

    def acc():
        X = assemble()
        p = 1 / (1 + np.exp(-(np.maximum(X @ w1 + b1, 0) @ w2 + b2[0])))
        ok = (p >= 0.5) == (Y >= 0.5)
        n = len(personal)
        return int(ok[:n].sum()), n, int(ok[n:].sum()), len(ok) - n

    before = acc()
    for ep in range(EPOCHS):
        X = assemble()
        hp = X @ w1 + b1
        h = np.maximum(hp, 0)
        z = h @ w2 + b2[0]
        p = 1 / (1 + np.exp(-z))
        dz = (p - Yt) * W / len(Y)
        gw2 = h.T @ dz + LAMBDA * (w2 - w2_0)
        gb2 = dz.sum() + LAMBDA * (b2[0] - b2_0[0])
        dh = np.outer(dz, w2) * (hp > 0)
        gw1 = X.T @ dh + LAMBDA * (w1 - w1_0)
        gb1 = dh.sum(axis=0) + LAMBDA * (b1 - b1_0)
        dX = dh @ w1.T
        # строки эмбеддингов: градиент через среднее (все затронутые строки разом)
        g = dX[flat_i[:, None], flat_off[:, None] + np.arange(D)[None, :]] / flat_cnt[:, None]
        np.add.at(emb, flat_rows, -LR * g)
        w1 -= LR * gw1
        b1 -= LR * gb1
        w2 -= LR * gw2
        b2[0] -= LR * gb2
    after = acc()
    log(f"дообучение: {len(examples)} личных (×{len(personal)} с аугментацией) + {len(generic)} общих; "
        f"личные верно {before[0]}/{before[1]} → {after[0]}/{after[1]}, "
        f"общие {before[2]}/{before[3]} → {after[2]}/{after[3]}")
    return {"emb": emb, "w1": w1, "b1": b1, "w2": w2, "b2": b2}, before, after


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("examples")
    ap.add_argument("--base", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "qsnet.bin"))
    ap.add_argument("--out", default="qsnet-user.bin")
    ap.add_argument("--replay", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "qsnet-replay.json"))
    a = ap.parse_args()
    header, params = qsnet.load_qsn(a.base)
    with open(a.examples, encoding="utf-8") as f:
        examples = [json.loads(l) for l in f if l.strip()]
    replay = []
    if os.path.exists(a.replay):
        with open(a.replay, encoding="utf-8") as f:
            replay = json.load(f)
    new, before, after = finetune(header, params, examples, replay)
    meta = {k: header[k] for k in ("buckets", "dim", "hidden")}
    meta.update({
        "trained": header.get("trained", "?"),
        "finetuned": time.strftime("%Y-%m-%d %H:%M"),
        "finetune_version": int(header.get("finetune_version", 0)) + 1,
        "personal_examples": len(examples),
    })
    qsnet.save_qsn(a.out, new, meta)
    print(f"✅ {a.out}")


if __name__ == "__main__":
    main()
