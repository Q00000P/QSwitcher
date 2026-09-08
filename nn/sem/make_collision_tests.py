#!/usr/bin/env python3
"""Тестовый набор коллизий из ЖИВОГО корпуса, а не из шаблонов.

Вход: collisions.tsv (клавиши, чтение_RU, чтение_EN, …) — список пар.
Корпус: nn/sem/data/corpus.txt.

Для каждой пары ищем реальные предложения, где встречается одно из чтений как
отдельное слово, вырезаем окно вокруг него и выдаём ДВЕ строки: слово как есть
(набрано верно) и слово, набранное в чужой раскладке. Ожидание в обоих случаях —
правильное чтение. Никаких выдуманных контекстов.

Пары, у которых в корпусе нет ни одного вхождения хотя бы одного чтения,
выбрасываются с пометкой — там и тестировать нечего.

    python3 nn/sem/make_collision_tests.py --tsv nn/sem/collisions.tsv \
        --out nn/sem/collision-phrases.txt --per-side 4 --window 7
"""
import argparse, os, random, re, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "data", "corpus.txt")
RU_TO_EN = dict(zip("йцукенгшщзхъфывапролджэячсмитьбю", "qwertyuiop[]asdfghjkl;'zxcvbnm,."))
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}
TOKEN = re.compile(r"[а-яёa-z0-9]+", re.I)

def swap(word):
    out = []
    for ch in word:
        lo = ch.lower()
        m = RU_TO_EN.get(lo) or EN_TO_RU.get(lo)
        if not m: return None
        out.append(m.upper() if ch.isupper() else m)
    return "".join(out)

def load_pairs(path):
    pairs = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 3 or p[0] == "клавиши_EN": continue
            ru, en = p[1].strip(), p[2].strip()
            if not ru or not en: continue
            if swap(ru.lower()) != en.lower():
                print(f"  ! пара не по клавишам, пропуск: {ru} / {en}")
                continue
            pairs.append((ru, en))
    return pairs

def scan(corpus, wanted, per_side, window, limit):
    """Один проход по корпусу: окна вокруг каждого искомого слова.

    Токенизируем строку и берём пересечение множеств — 320 подстрочных проверок
    на строку превратили бы проход по 34 млн строк в часы.
    """
    found = defaultdict(list)
    need = {w.lower() for w in wanted}
    cap = per_side * 40
    n = 0
    with open(corpus, encoding="utf-8", errors="ignore") as f:
        for line in f:
            n += 1
            if limit and n > limit: break
            if n % 2000000 == 0: print(f"  строк {n:,}", flush=True)
            toks = TOKEN.findall(line)
            if len(toks) < 4 or len(toks) > 40: continue
            low = [t.lower() for t in toks]
            hits = need.intersection(low)
            if not hits: continue
            for w in hits:
                if len(found[w]) >= cap: continue
                i = low.index(w)
                lo = max(0, i - window // 2); hi = min(len(toks), lo + window)
                found[w].append((toks[lo:hi], i - lo))
    return found

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", default=os.path.join(HERE, "collisions.tsv"))
    ap.add_argument("--corpus", default=CORPUS)
    ap.add_argument("--out", default=os.path.join(HERE, "collision-phrases.txt"))
    ap.add_argument("--per-side", type=int, default=4, help="фраз на каждое чтение")
    ap.add_argument("--train-out", help="файл примеров для профиля (окна, НЕ попавшие в тест)")
    ap.add_argument("--train-per-side", type=int, default=20, help="примеров на чтение для профиля")
    ap.add_argument("--window", type=int, default=7)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    random.seed(a.seed)
    pairs = load_pairs(a.tsv)
    print(f"пар в списке: {len(pairs)}")
    wanted = {w for ru, en in pairs for w in (ru, en)}
    print(f"ищу {len(wanted)} слов в корпусе…", flush=True)
    # берём с запасом: часть окон уйдёт в тест, остальные — в обучение профиля
    need_each = a.per_side + (a.train_per_side if a.train_out else 0)
    found = scan(a.corpus, wanted, need_each, a.window, a.limit)

    lines, train, dropped, kept = [], [], [], 0
    for ru, en in pairs:
        got, rest = {}, {}
        for reading in (ru, en):
            cands = found.get(reading.lower(), [])
            random.shuffle(cands)
            got[reading] = cands[:a.per_side]
            rest[reading] = cands[a.per_side:a.per_side + a.train_per_side]
        if not got[ru] or not got[en]:
            miss = [r for r in (ru, en) if not got[r]]
            dropped.append((ru, en, ", ".join(miss)))
            continue
        kept += 1
        # Примеры для профиля — ДРУГИЕ вхождения, чтобы обучение не совпало с тестом.
        # Строка формата окна обучения: «слова *цель* [вес]».
        if a.train_out:
            train.append(f"# {ru} / {en}")
            for reading in (ru, en):
                for toks, i in rest[reading]:
                    w = list(toks); w[i] = f"*{reading}*"
                    train.append(" ".join(w))
        lines.append(f"# {ru} / {en}")
        for reading in (ru, en):
            other = swap(reading)
            for toks, i in got[reading]:
                for target in (reading, other):          # набрано верно и в чужой раскладке
                    w = list(toks)
                    w[i] = f"*{target}*"
                    lines.append(" ".join(w) + f" => {reading}")
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("# Сгенерировано из корпуса: nn/sem/make_collision_tests.py\n")
        f.write("# Каждая пара: реальные предложения, слово набрано верно и в чужой раскладке.\n")
        f.write("\n".join(lines) + "\n")
    print(f"\nпар с контекстами: {kept}, строк: {len(lines)} → {a.out}")
    if a.train_out:
        with open(a.train_out, "w", encoding="utf-8") as f:
            f.write("# Примеры профиля из корпуса (вхождения, не попавшие в тест).\n")
            f.write("# Обучение: QSwitcher --train <этот файл>\n")
            f.write("\n".join(train) + "\n")
        print(f"примеров для профиля: {sum(1 for l in train if not l.startswith('#'))} → {a.train_out}")
    if dropped:
        print(f"выброшено {len(dropped)} пар (чтения нет в корпусе):")
        for ru, en, miss in dropped[:40]:
            print(f"  {ru} / {en} — нет: {miss}")
        if len(dropped) > 40: print(f"  … ещё {len(dropped) - 40}")

if __name__ == "__main__":
    main()
