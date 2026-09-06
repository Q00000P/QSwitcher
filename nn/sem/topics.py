#!/usr/bin/env python3
"""
Темы из векторов: кластеризация словаря (k-means по косинусу) → qsvec-topics.json.

Каждая тема — реальная группа слов из корпуса («сеть/сервер/доступ»,
«государство/закон/граждане», «люди/отношения/ругань», «авто», «электрика»…),
имя — из её самых частых слов. Приложение раскладывает любое слово по темам за k
умножений; профиль копит по чтению гистограмму тем — обобщение по осмысленным
осям, а не «предмет / не предмет».

  python3 topics.py                # qsvec.bin → qsvec-topics.json (k=96)
  python3 topics.py --k 128 --words 60000
  python3 topics.py --show          # напечатать темы
  python3 topics.py --word шлюз     # распределение слова по темам

Формат qsvec-topics.json: {"k", "dim", "tau", "names": [...], "top": [[слова…]…],
"centers": [[dim float]…]} — центры единичной длины, в очищенном пространстве.
Имена можно править руками в файле, центры не трогать.
"""
import argparse
import json
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsvec  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TAU = 8.0   # резкость распределения по темам: softmax(tau · cos)


def kmeans_cos(X, k, iters=25, seed=3):
    rng = np.random.default_rng(seed)
    C = X[rng.choice(len(X), k, replace=False)].copy()
    for _ in range(iters):
        sims = X @ C.T
        a = sims.argmax(axis=1)
        for j in range(k):
            m = X[a == j]
            if len(m):
                c = m.mean(axis=0)
                C[j] = c / (np.linalg.norm(c) + 1e-9)
            else:
                C[j] = X[rng.integers(len(X))]
    return C, a


def assign(model, centers, word, tau=TAU):
    v = model.centered(word)
    s = centers @ v
    p = np.exp(tau * (s - s.max()))
    return p / p.sum()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vectors", default=os.path.join(HERE, "qsvec.bin"))
    ap.add_argument("--out", default=os.path.join(HERE, "qsvec-topics.json"))
    ap.add_argument("--k", type=int, default=96)
    ap.add_argument("--words", type=int, default=60000, help="сколько частотных слов кластеризовать")
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--word")
    a = ap.parse_args()
    m = qsvec.QSVec(a.vectors)

    if a.show or a.word:
        with open(a.out, encoding="utf-8") as f:
            t = json.load(f)
        C = np.array(t["centers"], np.float32)
        if a.word:
            p = assign(m, C, a.word, t.get("tau", TAU))
            print(f"{a.word}:")
            for i in np.argsort(-p)[:5]:
                print(f"  {p[i]:.2f}  {t['names'][i]}")
        else:
            for i, (n, top) in enumerate(zip(t["names"], t["top"])):
                print(f"{i:3d}  {n:28s} {' '.join(top)}")
        return

    n = min(a.words, len(m.words))
    X = m.vec_c[:n].astype(np.float32)
    stop = {w for w in m.words[:n] if w in qsvec.STOP or len(w) < 3}
    keep = np.array([w not in stop for w in m.words[:n]])
    Xk = X[keep]
    words = [w for w, k in zip(m.words[:n], keep) if k]
    print(f"кластеризую {len(Xk)} слов на {a.k} тем…", flush=True)
    C, asg = kmeans_cos(Xk, a.k)
    # Отбрасываем кластеры-мусор: служебные слова, местоимения, формы глаголов,
    # числительные — они про грамматику, а не про тему.
    JUNK = re.compile(r"^(?:[a-z]+ing|[a-z]+ed|[a-z]+n't|[а-я]+(?:ся|сь|ли|ла|ло|ть|ешь|ете|ишь|ите|ому|ему|ого|его|ыми|ими)|"
                      r"этот|этого|этому|один|одна|одно|такой|самый|самой|новый|новое|нового|первый|первое|своему|моему|"
                      r"всему|which|would|could|should|still|never|must|more|much|dear|very|only|also)$")
    names, tops, centers = [], [], []
    for j in range(a.k):
        idx = np.where(asg == j)[0]
        if len(idx) < 30:
            continue
        idx = sorted(idx, key=lambda i: i)[:40]                        # самые частые (индекс = частота)
        idx = sorted(idx, key=lambda i: -float(Xk[i] @ C[j]))[:8]      # из них — ближайшие к центру
        top = [words[i] for i in idx]
        if sum(1 for w in top if JUNK.match(w) or w in qsvec.STOP) >= 4:
            continue
        tops.append(top)
        names.append("/".join(top[:3]))
        centers.append(C[j])
    out = {"k": len(centers), "dim": m.h["dim"], "tau": TAU, "names": names, "top": tops,
           "centers": [[round(float(x), 5) for x in c] for c in centers]}
    log_dropped = a.k - len(centers)
    print(f"тем-мусора отброшено: {log_dropped}")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    print(f"✅ {a.out}: {len(centers)} тем, {os.path.getsize(a.out) // 1024} КБ")
    for j in range(min(len(centers), 12)):
        print(f"  {names[j]:28s} {' '.join(tops[j])}")


if __name__ == "__main__":
    main()
