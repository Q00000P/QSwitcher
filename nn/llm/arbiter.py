#!/usr/bin/env python3
"""qs-arbiter — LLM-арбитр коллизий для QSwitcher (модуль «Full»).

Отдельный процесс: приложение спрашивает его ТОЛЬКО когда профиль сказал
«не уверен». Протокол — Unix-сокет, по JSON-строке на запрос/ответ:

  запрос: {"typed": "HA", "swapped": "РФ", "left": ["сервер", "мой"],
           "right": [], "topic": [...до 40 слов...], "app": "chat"}
  ответ:  {"reading": "HA", "p": 1.0, "ms": 38, "raw": "HA"}
          reading = null — модель не решила (p=0).
  служебное: {"cmd": "info"} → {"model": "...", "size_mb": ..., "double": true}

Модель — любой GGUF: --model ключ из списка (скачается в nn/llm/models/) или путь.
Сегодня одна, завтра другая: перезапустил процесс с другой моделью — приложение
ничего не заметило. Замер там же:

  python3 nn/llm/arbiter.py --model qwen25-0.5b --bench nn/sem/my-phrases.txt
  python3 nn/llm/arbiter.py --model qwen25-0.5b            # сервер

Ответ разбирается по вхождению одного из двух вариантов. Мелкие модели тяготеют
к последнему варианту, поэтому спрашиваем ДВАЖДЫ с переставленными вариантами:
совпало — p=1.0, разошлось — молчим. Вдвое дольше (≈70 мс на M5), зато без
угадывания.
"""
import argparse, json, os, socket, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import MODELS, PROMPT, GLOSSARY_DEFAULT, fetch, parse_phrases, swap, log
HERE = os.path.dirname(os.path.abspath(__file__))

DEFAULT_SOCK = os.path.expanduser("~/Library/Application Support/QSwitcher/arbiter.sock")
GLOSSARY_USER = os.path.expanduser("~/Library/Application Support/QSwitcher/glossary.txt")

class Arbiter:
    def __init__(self, model_path, threads=4, double=True, glossary=None):
        from llama_cpp import Llama
        t0 = time.time()
        self.llm = Llama(model_path=model_path, n_ctx=768, n_threads=threads, verbose=False)
        self.model_path = model_path
        self.double = double
        self.glossary = glossary if glossary is not None else GLOSSARY_DEFAULT
        log(f"модель {os.path.basename(model_path)} загружена за {time.time()-t0:.1f} с")

    def ask_once(self, phrase, a, b):
        gl = ("Сокращения этого пользователя:\n" + self.glossary.strip() + "\n\n") if self.glossary.strip() else ""
        prompt = PROMPT.format(phrase=phrase, a=a, b=b, glossary=gl)
        r = self.llm(prompt, max_tokens=6, temperature=0, stop=["\n"])
        raw = r["choices"][0]["text"].strip()
        low = raw.lower()
        if a.lower() in low and b.lower() not in low: return a, raw
        if b.lower() in low and a.lower() not in low: return b, raw
        return None, raw

    def decide(self, typed, swapped, left, right=(), topic=()):
        # фраза — как на экране: соседи слева (ближний последним), слово, соседи справа
        phrase = " ".join(list(reversed(list(left))) + [typed] + list(right))
        t = time.time()
        r1, raw1 = self.ask_once(phrase, typed, swapped)
        if not self.double:
            ms = (time.time() - t) * 1000
            return {"reading": r1, "p": 1.0 if r1 else 0.0, "ms": round(ms), "raw": raw1}
        r2, raw2 = self.ask_once(phrase, swapped, typed)
        ms = (time.time() - t) * 1000
        if r1 and r1 == r2:
            return {"reading": r1, "p": 1.0, "ms": round(ms), "raw": raw1}
        return {"reading": None, "p": 0.0, "ms": round(ms), "raw": f"{raw1} | {raw2}"}

    def info(self):
        return {"model": os.path.basename(self.model_path),
                "size_mb": round(os.path.getsize(self.model_path) / 1e6), "double": self.double}

def resolve_model(key_or_path):
    if os.path.exists(key_or_path): return key_or_path
    if key_or_path in MODELS: return fetch(key_or_path, MODELS[key_or_path][1])
    sys.exit(f"модель не найдена: {key_or_path}; известные: {', '.join(MODELS)}")

def serve(arb, sock_path):
    if os.path.exists(sock_path): os.unlink(sock_path)
    os.makedirs(os.path.dirname(sock_path), exist_ok=True)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(sock_path); os.chmod(sock_path, 0o600); s.listen(4)
    log(f"слушаю {sock_path}")
    while True:
        conn, _ = s.accept()
        with conn:
            f = conn.makefile("rwb")
            for line in f:
                try:
                    q = json.loads(line.decode("utf-8"))
                    if q.get("cmd") == "info": ans = arb.info()
                    else:
                        ans = arb.decide(q["typed"], q["swapped"], q.get("left", []), q.get("right", []), q.get("topic", []))
                        log(f"  {ans['ms']:4d} мс  {' '.join(reversed(q.get('left', [])))} [{q['typed']}|{q['swapped']}] → {ans['reading']}")
                except Exception as e:
                    ans = {"reading": None, "p": 0.0, "ms": 0, "error": str(e)}
                f.write((json.dumps(ans, ensure_ascii=False) + "\n").encode("utf-8")); f.flush()

def load_dicts():
    """Словари приложения — чтобы отсеять строки, где второе чтение не слово."""
    out = {}
    for lang, name in (("ru", "ru.txt"), ("en", "en.txt")):
        for base in (os.path.join(HERE, "..", "..", "Sources", "QSwitcher", "Resources"),
                     os.path.expanduser("~/dev/QSwitcher/QSwitcher.app/Contents/Resources")):
            f = os.path.join(base, name)
            if os.path.exists(f):
                out[lang] = {w.strip().lower() for w in open(f, encoding="utf-8", errors="ignore") if w.strip()}
                break
        else:
            out[lang] = set()
    return out

def is_collision(a, b, dicts):
    """Оба чтения осмысленны? Только такие слова доходят до арбитра в приложении."""
    def known(w):
        lw = w.lower()
        if lw in dicts["ru"] or lw in dicts["en"]: return True
        return len(w) <= 4 and w == w.upper() and w != w.lower()   # аббревиатура капсом
    return known(a) and known(b)

def bench(arb, path, all_lines=False):
    text = open(path, encoding="utf-8").read()
    dicts = load_dicts()
    ok = total = silent = skipped = 0
    times = []
    for phrase, typed, expect in parse_phrases(text):
        if phrase.startswith("@"):
            phrase = phrase.split(" ", 1)[1] if " " in phrase else ""
        other = swap(typed)
        if not other or not expect: continue
        if not all_lines and not is_collision(typed, other, dicts):
            skipped += 1
            continue
        words = phrase.split()
        i = words.index(typed) if typed in words else len(words) - 1
        ans = arb.decide(typed, other, list(reversed(words[:i])), words[i+1:])
        times.append(ans["ms"]); total += 1
        got = ans["reading"] or "—"
        if ans["reading"] is None: silent += 1
        hit = (ans["reading"] or "").lower() == expect.lower()
        ok += hit
        log(f"  {ans['ms']:4d} мс  {phrase[:44]:44s} → {got:10s} {'✅' if hit else '❌ ждали ' + expect}")
    med = sorted(times)[len(times)//2] if times else 0
    log(f"ИТОГО {os.path.basename(arb.model_path)}: {ok}/{total} верно, "
        f"промолчал {silent}, медиана {med} мс"
        + (f", пропущено не-коллизий {skipped}" if skipped else ""))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="ключ из списка или путь к GGUF")
    ap.add_argument("--socket", default=DEFAULT_SOCK)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--single", action="store_true", help="спрашивать один раз (быстрее, но с уклоном)")
    ap.add_argument("--glossary", help="файл со словарём сокращений; по умолчанию " + GLOSSARY_USER)
    ap.add_argument("--bench", help="прогнать файл фраз и выйти")
    ap.add_argument("--all", action="store_true",
                    help="мерить все строки, а не только коллизии (в приложении арбитр видит только коллизии)")
    a = ap.parse_args()
    gl = None
    gpath = a.glossary or (GLOSSARY_USER if os.path.exists(GLOSSARY_USER) else None)
    if gpath: gl = open(gpath, encoding="utf-8").read()
    arb = Arbiter(resolve_model(a.model), a.threads, not a.single, gl)
    if a.bench: return bench(arb, a.bench, a.all)
    serve(arb, a.socket)

if __name__ == "__main__":
    main()
