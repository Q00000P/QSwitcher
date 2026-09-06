#!/usr/bin/env python3
"""
Обучение семантических векторов (fastText skip-gram с подсловами, gensim) на
data/corpus.txt и экспорт в компактный файл QSV1 для приложения.

  python3 -m pip install --user gensim
  python3 train_vectors.py                 # → qsvec.bin (~10–15 МБ)
  python3 train_vectors.py --dim 64 --epochs 5 --vocab 150000

Почему fastText: вектор есть у любого слова — незнакомое и с опечаткой собирается
из своих кусочков (n-грамм 3..5 символов). RU и EN учатся в одном пространстве:
корпус смешанный, а пары переводов Tatoeba лежат в одной строке.

Формат QSV1 (little-endian):
  "QSV1" | u32 hlen | JSON-заголовок | словарь | векторы слов | векторы n-грамм
  заголовок: dim, vocab, buckets, minn, maxn, hash="fasttext-fnv1a"
  словарь:   vocab раз [u16 len, utf8]  — по убыванию частоты
  векторы:   vocab × (float32 scale + dim × int8)   — вектор = scale · int8
  n-граммы:  buckets × (float32 scale + dim × int8)
Вектор слова: есть в словаре → строка; нет → среднее строк его n-грамм
(n-граммы считаются от "<слово>", хэш fastText = FNV-1a по байтам UTF-8 с
приведением байта к знаковому int8, индекс = hash % buckets).
"""
import argparse
import json
import os
import struct
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")


def log(*a):
    print(*a, flush=True)


class Corpus:
    def __init__(self, path):
        self.path = path

    def __iter__(self):
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                yield line.split()


def quantize(mat):
    """Построчно: scale = max|x|/127, int8 = round(x/scale)."""
    scale = np.abs(mat).max(axis=1) / 127.0
    scale[scale == 0] = 1.0
    q = np.clip(np.round(mat / scale[:, None]), -127, 127).astype(np.int8)
    return scale.astype(np.float32), q


def export(path, model, vocab_limit):
    wv = model.wv
    words = wv.index_to_key[:vocab_limit]
    dim = wv.vector_size
    vec = np.stack([wv.get_vector(w, norm=False) for w in words]).astype(np.float32)
    ng = wv.vectors_ngrams.astype(np.float32)
    s1, q1 = quantize(vec)
    s2, q2 = quantize(ng)
    header = {
        "format": 1, "dim": dim, "vocab": len(words), "buckets": int(ng.shape[0]),
        "minn": int(wv.min_n), "maxn": int(wv.max_n), "hash": "fasttext-fnv1a",
        "trained": time.strftime("%Y-%m-%d %H:%M"), "quant": "int8-row-scale",
    }
    hb = json.dumps(header, ensure_ascii=False).encode("utf-8")
    with open(path, "wb") as f:
        f.write(b"QSV1")
        f.write(struct.pack("<I", len(hb)))
        f.write(hb)
        for w in words:
            b = w.encode("utf-8")
            f.write(struct.pack("<H", len(b)))
            f.write(b)
        for s, q in ((s1, q1), (s2, q2)):
            for i in range(q.shape[0]):
                f.write(struct.pack("<f", float(s[i])))
                f.write(q[i].tobytes())
    return header


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(DATA, "corpus.txt"))
    ap.add_argument("--out", default=os.path.join(HERE, "qsvec.bin"))
    ap.add_argument("--dim", type=int, default=64)
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--vocab", type=int, default=150_000, help="слов в экспорте (по частоте)")
    ap.add_argument("--buckets", type=int, default=200_000, help="корзин n-грамм (размер файла!)")
    ap.add_argument("--min-count", type=int, default=5)
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    a = ap.parse_args()

    from gensim.models import FastText
    t0 = time.time()
    corpus = Corpus(a.corpus)
    log(f"обучение: dim={a.dim}, epochs={a.epochs}, buckets={a.buckets}, workers={a.workers}")
    model = FastText(vector_size=a.dim, window=5, min_count=a.min_count, sg=1, negative=10,
                     min_n=3, max_n=5, bucket=a.buckets, workers=a.workers, epochs=a.epochs)
    model.build_vocab(corpus)
    log(f"  словарь: {len(model.wv.index_to_key)} слов, {time.time() - t0:.0f}с")
    model.train(corpus, total_examples=model.corpus_count, epochs=a.epochs)
    log(f"  обучено за {time.time() - t0:.0f}с")
    model.save(os.path.join(DATA, "fasttext.model"))
    h = export(a.out, model, a.vocab)
    log(f"✅ {a.out}: {os.path.getsize(a.out) / 1e6:.1f} МБ, {h['vocab']} слов, {h['buckets']} корзин, dim {h['dim']}")


if __name__ == "__main__":
    main()
