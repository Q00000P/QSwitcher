#!/usr/bin/env python3
"""
Пишет qsnet-selftest.json рядом с весами — набор случаев с эталонными
вероятностями. Клиенты (Swift/C#) при загрузке прогоняют его и выключают сеть,
если их порт расходится с эталоном больше чем на 1e-3.

  python3 selftest.py            # nn/qsnet.bin → nn/qsnet-selftest.json
  python3 selftest.py путь/к/qsnet.bin
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsnet  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "qsnet.bin")
    header, params = qsnet.load_qsn(path)
    net = qsnet.QSNet(header, params)
    rng = random.Random(7)
    cases = []
    fixed = [
        ("ghbdtn", "", "other", "en"), ("hello", "", "other", "en"), ("lyc", "прописал в конфиге", "chat", "ru"),
        ("dns", "cat /etc/resolv.conf", "terminal", "en"), ("yt", "я этого", "chat", "en"),
        ("he", "а он", "chat", "ru"), ("`;", "", "other", "ru"), ("'nj", "и", "browser", "ru"),
        ("[jhjij", "", "code", "en"), ("ntcn", "run the", "terminal", "en"),
    ]
    for keys, ctx, app, lay in fixed:
        cases.append((keys, qsnet.ctx_from_text(ctx), app, lay))
    for _ in range(40):  # случайные клавиши/контексты — ловят ошибки хэша и порядка входа
        keys = "".join(rng.choice(qsnet.KEYS) for _ in range(rng.randint(1, 12)))
        ctx = []
        for _ in range(rng.randint(0, 3)):
            if rng.random() < 0.2:
                ctx.append((None, rng.choice(qsnet.CTX_FLAGS)))
            else:
                ctx.append(("".join(rng.choice(qsnet.KEYS) for _ in range(rng.randint(1, 8))),
                            rng.choice(qsnet.CTX_FLAGS)))
        cases.append((keys, ctx, rng.choice(qsnet.APPS), rng.choice(qsnet.LANGS)))
    out = []
    for keys, ctx, app, lay in cases:
        p = net.p_ru(keys, ctx, app, lay)
        out.append({"keys": keys, "ctx": [[k, f] for k, f in ctx], "app": app, "layout": lay, "p": round(p, 6)})
    dest = os.path.join(os.path.dirname(path), "qsnet-selftest.json")
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=0)
    print(f"✅ {dest}: {len(out)} случаев")


if __name__ == "__main__":
    main()
