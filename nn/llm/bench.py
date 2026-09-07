#!/usr/bin/env python3
"""
Замер маленьких локальных моделей как арбитра коллизий раскладки.

Задача модели крошечная: выбрать одно из двух чтений («ha» → HA или РФ) —
ответ в ОДИН токен. Это не разбор текста, как в «Соучастнике» (там сотни
токенов и потому 4–6 с), поэтому и время должно быть на порядки меньше.

  python3 -m pip install --user llama-cpp-python     # или: brew install llama.cpp
  python3 bench.py --list                            # какие модели умеет качать
  python3 bench.py                                   # скачать и прогнать все
  python3 bench.py --models qwen3-0.6b gemma3-270m
  python3 bench.py --phrases my.txt                  # свой список фраз

Формат фраз (как в приложении): «фраза => ожидание», цель — последнее слово
или в *звёздочках*.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(HERE, "models")

# Модели до ~1B в GGUF Q4 — то, что реально влезает в приложение.
MODELS = {
    "qwen3-0.6b": ("Qwen3 0.6B (Alibaba, лучший русский в весе)",
                   "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"),
    "qwen3-1.7b": ("Qwen3 1.7B (крупнее, если 0.6B не хватит)",
                   "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf"),
    "qwen25-0.5b": ("Qwen2.5 0.5B Instruct",
                    "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"),
    "qwen25-1.5b": ("Qwen2.5 1.5B Instruct",
                    "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"),
    "gemma3-270m": ("Gemma 3 270M (Google, самая мелкая)",
                    "https://huggingface.co/unsloth/gemma-3-270m-it-GGUF/resolve/main/gemma-3-270m-it-Q4_K_M.gguf"),
    "gemma3-1b": ("Gemma 3 1B",
                  "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf"),
    "smollm2-360m": ("SmolLM2 360M (HuggingFace, самая быстрая)",
                     "https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/SmolLM2-360M-Instruct-Q4_K_M.gguf"),
    "llama32-1b": ("Llama 3.2 1B (Meta)",
                   "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
    "lfm2-700m": ("LiquidAI LFM2 700M (под устройства)",
                  "https://huggingface.co/LiquidAI/LFM2-700M-GGUF/resolve/main/LFM2-700M-Q4_K_M.gguf"),
}

DEFAULT_PHRASES = """\
мой шлюз *ha* наружу => HA
настроил датчик *ha* дома => HA
перезагрузил *ha* и всё заработало => HA
конфиг *ha* поправил => HA
пингую *ha* с ноутбука => HA
шлюхи *ha* на трассе => РФ
гопники *ha* во дворе => РФ
граждане *ha* обязаны => РФ
живу в *ha* всю жизнь => РФ
армия *ha* провела учения => РФ
законы *ha* меняются => РФ
уехал из *ha* в прошлом году => РФ
мой сервер HA наружу идёт через IP *ha* => РФ
он *he* сказал что придёт => ру
мы *vs* они кто кого => мы
не *yt* знаю ответа => не
да *lf* конечно приходи => да
это *ntcn* на скорость => тест
"""

# Мелкие модели без образца ломают формат («Слово», «Понятие»), поэтому даём два
# примера прямо в промпте и просим ровно один вариант. Ответ разбираем по вхождению:
# что из двух встретилось — то и выбрано; ничего не встретилось — модель промолчала.
# Примеры чередуют стороны (иначе модель ловит паттерн «всегда второй вариант»)
# и показывают оба направления: и русское слово, набранное в EN, и наоборот.
PROMPT = """Ты помогаешь исправлять текст, набранный не в той раскладке клавиатуры.
{glossary}Во фразе одно слово могло быть набрано не в той раскладке. Выбери из двух
вариантов тот, который осмыслен в этой фразе. Ответь одним словом.

Фраза: настроил роутер lyc дома
Варианты: днс / lyc
Ответ: днс

Фраза: открыл файл через ыыр
Варианты: ыыр / ssh
Ответ: ssh

Фраза: hf работе много дел
Варианты: hf / на
Ответ: на

Фраза: поднял ыыр на сервере
Варианты: ssh / ыыр
Ответ: ssh

Фраза: {phrase}
Варианты: {a} / {b}
Ответ:"""

# Словарь пользователя: то, чего модель знать не может — свои сокращения и имена.
# Ровно та же роль, что у abbrev.txt для векторов, только здесь работает сразу.
GLOSSARY_DEFAULT = """HA — Home Assistant: умный дом, датчики, интеграции, автоматизация, свой сервер
РФ — Россия: страна, государство, граждане, законы
"""


def log(*a):
    print(*a, flush=True)


def fetch(name, url):
    os.makedirs(MODELS_DIR, exist_ok=True)
    dest = os.path.join(MODELS_DIR, name + ".gguf")
    if os.path.exists(dest) and os.path.getsize(dest) > 10 << 20:
        return dest
    part = dest + ".part"
    # Модели большие, соединение рвётся — качаем с докачкой (Range) и повторами.
    for attempt in range(1, 6):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        headers = {"User-Agent": "QSwitcher-bench/1.0"}
        if have:
            headers["Range"] = f"bytes={have}-"
            log(f"  докачиваю {name} с {have >> 20} МБ")
        else:
            log(f"  качаю {name}: {url}")
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=120) as r:
                total = r.headers.get("Content-Length")
                total = have + int(total) if total else 0
                mode = "ab" if (have and r.status == 206) else "wb"
                if mode == "wb":
                    have = 0
                with open(part, mode) as f:
                    done = have
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                        done += len(chunk)
                        if done % (100 << 20) < (1 << 20):
                            log(f"    {done >> 20} МБ" + (f" из {total >> 20}" if total else ""))
            if total and os.path.getsize(part) < total:
                log(f"  ⚠️  оборвалось на {os.path.getsize(part) >> 20} из {total >> 20} МБ — попытка {attempt}")
                continue
            os.replace(part, dest)
            return dest
        except Exception as e:  # noqa: BLE001
            log(f"  ⚠️  попытка {attempt}: {e}")
            time.sleep(2)
    return None


def parse_phrases(text):
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        expect = None
        if "=>" in line:
            line, expect = [x.strip() for x in line.split("=>", 1)]
        words = line.split()
        ti = len(words) - 1
        for k, w in enumerate(words):
            if len(w) > 2 and w.startswith("*") and w.endswith("*"):
                words[k] = w[1:-1]
                ti = k
        out.append((" ".join(words), words[ti], expect))
    return out


# Клавиши → второе чтение (сокращённая карта, хватает для теста)
RU_TO_EN = dict(zip("йцукенгшщзхъфывапролджэячсмитьбю", "qwertyuiop[]asdfghjkl;'zxcvbnm,."))
EN_TO_RU = {v: k for k, v in RU_TO_EN.items()}


def swap(word):
    out = []
    for ch in word:
        lo = ch.lower()
        m = RU_TO_EN.get(lo) or EN_TO_RU.get(lo)
        if not m:
            return None
        out.append(m.upper() if ch.isupper() else m)
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*", default=list(MODELS))
    ap.add_argument("--phrases")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--glossary", help="файл со своими сокращениями: «HA — Home Assistant: …»")
    ap.add_argument("--no-glossary", action="store_true", help="без словаря — проверить голую модель")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 8)
    a = ap.parse_args()

    if a.list:
        for k, (desc, url) in MODELS.items():
            log(f"  {k:14s} {desc}")
        return

    text = open(a.phrases, encoding="utf-8").read() if a.phrases else DEFAULT_PHRASES
    if a.no_glossary:
        glossary = ""
    elif a.glossary:
        glossary = open(a.glossary, encoding="utf-8").read()
    else:
        glossary = GLOSSARY_DEFAULT
    log("словарь в промпте:\n" + (glossary or "  (нет)"))
    phrases = parse_phrases(text)
    log(f"фраз: {len(phrases)}\n")

    try:
        from llama_cpp import Llama
    except ImportError:
        log("нужен llama-cpp-python:  python3 -m pip install --user llama-cpp-python")
        return 2

    results = []
    for key in a.models:
        if key not in MODELS:
            log(f"неизвестная модель: {key}")
            continue
        desc, url = MODELS[key]
        path = fetch(key, url)
        if not path:
            continue
        size_mb = os.path.getsize(path) / 1e6
        log(f"\n=== {key} — {desc}, {size_mb:.0f} МБ ===")
        t0 = time.time()
        llm = Llama(model_path=path, n_ctx=512, n_threads=a.threads, verbose=False)
        log(f"  загрузка {time.time() - t0:.1f} с")
        ok = 0
        total = 0
        times = []
        for idx, (phrase, typed, expect) in enumerate(phrases):
            other = swap(typed)
            if not other:
                continue
            gl = ("Сокращения этого пользователя:\n" + glossary.strip() + "\n\n") if glossary else ""
            # Порядок вариантов чередуем: мелкие модели тяготеют к последнему,
            # и при постоянном порядке это решает за них.
            a_var, b_var = (typed, other) if (idx % 2 == 0) else (other, typed)
            prompt = PROMPT.format(phrase=phrase, a=a_var, b=b_var, glossary=gl)
            t = time.time()
            r = llm(prompt, max_tokens=6, temperature=0, stop=["\n"])
            dt = (time.time() - t) * 1000
            times.append(dt)
            raw = r["choices"][0]["text"].strip()
            low = raw.lower()
            # что из двух вариантов встретилось в ответе — то и выбрано
            if typed.lower() in low and other.lower() not in low:
                answer = typed
            elif other.lower() in low and typed.lower() not in low:
                answer = other
            else:
                answer = "?" + raw[:12]
            mark = ""
            if expect:
                total += 1
                hit = answer.lower() == expect.lower()
                ok += hit
                mark = "✅" if hit else f"❌ ждали {expect}"
            log(f"  {dt:6.0f} мс  {phrase[:42]:42s} → {answer:12s} {mark}")
        med = sorted(times)[len(times) // 2] if times else 0
        log(f"  ИТОГО {key}: {ok}/{total} верно, медиана {med:.0f} мс, размер {size_mb:.0f} МБ")
        results.append((key, ok, total, med, size_mb))
        del llm

    log("\n=== сводка ===")
    for key, ok, total, med, size in sorted(results, key=lambda x: (-x[1], x[3])):
        log(f"  {key:14s} {ok}/{total} верно   {med:5.0f} мс   {size:4.0f} МБ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
