#!/usr/bin/env python3
"""
Делает qsnet-replay.json — набор общих примеров, который подмешивается при
дообучении в приложении, чтобы личные слова добавлялись, а не вытесняли всё
остальное («забывание»). Берётся из nn/data (после prepare_data.py).

  python3 replay.py            # → nn/qsnet-replay.json (2000 примеров)
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsnet  # noqa: E402
import train  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    rng = random.Random(3)
    lines = train.load_corpus(os.path.join(train.DATA, "corpus.tsv"))
    words = train.load_words(os.path.join(train.DATA, "words.tsv"))
    rng.shuffle(lines)
    sampler = train.Sampler(lines[:60000], words, rng, train=False)
    out = []
    for keys, ctx, app, lay, label, w in sampler.sample(n):
        out.append({"keys": keys, "ctx": [[k, f] for k, f in ctx], "app": qsnet.APPS[app],
                    "layout": lay, "label": "ru" if label == 1 else "en"})
    dest = os.path.join(HERE, "qsnet-replay.json")
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(f"✅ {dest}: {len(out)} примеров, {os.path.getsize(dest) // 1024} КБ")


if __name__ == "__main__":
    main()
