#!/usr/bin/env python3
"""
Корпус для семантических векторов QSwitcher (RU + EN в одном пространстве).

Что тянем (всё открытое, качается один раз в nn/sem/data/):
  * OpenSubtitles (OPUS, моноязычные ru/en) — живая разговорная речь, много тем;
  * Tatoeba ru/en + links — параллельные пары: русское и английское предложения
    склеиваются в одну строку, чтобы пространства двух языков выровнялись;
  * Википедия, выборка статей (ru/en через API dumps.wikimedia "cirrus"? — нет:
    берём готовые извлечённые абзацы из wikimedia "text" экспорта не проще; здесь
    используем OPUS Wikipedia моно ru/en — тот же формат, что субтитры);
  * личные тексты: --telegram <export.json> (экспорт чата из Telegram Desktop),
    --extra <файл.txt> — по абзацу на строку. Личные строки идут с весом
    (повторяются --personal-weight раз): темы пользователя — главное.

Результат: data/corpus.txt — по строке на «документ» (предложение/абзац),
токены в нижнем регистре, разделены пробелами; кириллица и латиница как есть.
"""
import argparse
import bz2
import gzip
import io
import json
import os
import random
import re
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

SOURCES = {
    "subs-ru": "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/ru.txt.gz",
    "subs-en": "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/en.txt.gz",
    "wiki-ru": "https://object.pouta.csc.fi/OPUS-wikimedia/v20230407/mono/ru.txt.gz",
    "wiki-en": "https://object.pouta.csc.fi/OPUS-wikimedia/v20230407/mono/en.txt.gz",
    "tatoeba-ru": "https://downloads.tatoeba.org/exports/per_language/rus/rus_sentences.tsv.bz2",
    "tatoeba-en": "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2",
    "tatoeba-links": "https://downloads.tatoeba.org/exports/links.tar.bz2",
    # Готовые выровненные пары en-ru (moses: два файла в zip, строка к строке).
    # Надёжнее и на порядок больше, чем собирать пары через links.csv.
    "para-enru": "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/moses/en-ru.txt.zip",
    # --tech: технические базы. Stack Exchange (CC BY-SA): вопросы/ответы про сети,
    # серверы, Linux — наш словарь на обоих языках. OPUS KDE4/GNOME/Ubuntu —
    # переводы интерфейсов и документации ru↔en: термины встают парами.
    "se-ru": "https://archive.org/download/stackexchange/ru.stackoverflow.com.7z",
    "se-serverfault": "https://archive.org/download/stackexchange/serverfault.com.7z",
    "se-unix": "https://archive.org/download/stackexchange/unix.stackexchange.com.7z",
    # --domains: широкие параллельные корпуса ru↔en (экономика/финансы/политика,
    # наука/общество/образование, право/государство) — темы и выравнивание терминов.
    "news-enru": "https://object.pouta.csc.fi/OPUS-News-Commentary/v16/moses/en-ru.txt.zip",
    "ted-enru": "https://object.pouta.csc.fi/OPUS-TED2020/v1/moses/en-ru.txt.zip",
    "un-enru": "https://object.pouta.csc.fi/OPUS-MultiUN/v1/moses/en-ru.txt.zip",
    "kde-enru": "https://object.pouta.csc.fi/OPUS-KDE4/v2/moses/en-ru.txt.zip",
    "gnome-enru": "https://object.pouta.csc.fi/OPUS-GNOME/v1/moses/en-ru.txt.zip",
    "ubuntu-enru": "https://object.pouta.csc.fi/OPUS-Ubuntu/v14.10/moses/en-ru.txt.zip",
}

# Тематический фильтр: строка считается технической, если в ней есть такое слово.
TECH = re.compile(r"\b(сервер\w*|сет[ьи]\w*|роутер\w*|маршрутизат\w*|протокол\w*|шлюз\w*|конфиг\w*|"
                  r"настройк\w*|устано\w*|скрипт\w*|программ\w*|компьютер\w*|операционн\w*|linux|windows|"
                  r"ubuntu|debian|docker|nginx|dns|ip|vpn|ssh|http\w*|api|json|wifi|wi-fi|порт\w*|пакет\w*|"
                  r"баз\w* данных|файл\w*|терминал\w*|команд\w*|провайдер\w*|трафик\w*|firewall|"
                  r"server\w*|network\w*|router\w*|gateway\w*|protocol\w*|config\w*|install\w*|script\w*|"
                  r"software|hardware|kernel|daemon|packet\w*|firmware|database\w*|terminal|command\w*|"
                  r"traffic|bandwidth|latency|proxy|certificate\w*|encrypt\w*|password\w*|login|"
                  r"смартфон\w*|телефон\w*|прошивк\w*|датчик\w*|автоматизац\w*|умн\w* дом\w*|"
                  r"электр\w*|напряжен\w*|провод\w*|розетк\w*|автомобил\w*|двигател\w*|колес\w*)\b",
                  re.I)


# Области для тематических выборок: из каждой — своя квота, чтобы ни одна не
# задавила остальные. База должна быть общей: семья, школа, деньги, здоровье,
# дом, авто, спорт, путешествия — а не IT-уклон.
DOMAINS = {
    "it": TECH,
    "finance": re.compile(r"\b(банк\w*|кредит\w*|ипотек\w*|налог\w*|бюджет\w*|инвест\w*|акци[ия]\w*|облигаци\w*|"
                          r"процент\w*|вклад\w*|зарплат\w*|валют\w*|рубл\w*|доллар\w*|курс\w*|биржа|бирж\w*|"
                          r"страхов\w*|пенси\w*|финанс\w*|экономик\w*|инфляци\w*|дивиденд\w*|"
                          r"bank\w*|credit|loan\w*|mortgage|tax\w*|budget\w*|invest\w*|stock\w*|bond\w*|"
                          r"interest|salary|currenc\w*|dollar\w*|insurance|pension\w*|financ\w*|econom\w*|inflation|dividend\w*)\b", re.I),
    "health": re.compile(r"\b(врач\w*|больниц\w*|болезн\w*|лечени\w*|лекарств\w*|таблетк\w*|диагноз\w*|симптом\w*|"
                         r"здоровь\w*|температур\w*|давлени\w*|прививк\w*|аллерги\w*|витамин\w*|диет\w*|"
                         r"doctor\w*|hospital\w*|disease\w*|treatment\w*|medicine|medication\w*|diagnos\w*|symptom\w*|"
                         r"health\w*|fever|vaccine\w*|allerg\w*|vitamin\w*|diet\w*)\b", re.I),
    "family": re.compile(r"\b(ребён\w*|ребен\w*|дет[иейям]\w*|сын\w*|доч\w*|школ\w*|урок\w*|учител\w*|учеб\w*|"
                         r"домашн\w* задан\w*|садик\w*|мам[аыуе]|пап[аыуе]|бабушк\w*|дедушк\w*|семь[яией]\w*|"
                         r"каникул\w*|оценк\w*|экзамен\w*|"
                         r"child\w*|kids?|son|daughter\w*|school\w*|lesson\w*|teacher\w*|homework|kindergarten|"
                         r"mom|dad|grandm\w*|grandp\w*|famil\w*|holiday\w*|grade\w*|exam\w*)\b", re.I),
    "home": re.compile(r"\b(квартир\w*|ремонт\w*|кухн\w*|готови\w*|рецепт\w*|уборк\w*|стирк\w*|холодильник\w*|"
                       r"мебел\w*|покупк\w*|магазин\w*|доставк\w*|продукт\w*|ужин\w*|завтрак\w*|обед\w*|"
                       r"apartment\w*|repair\w*|kitchen\w*|cook\w*|recipe\w*|cleaning|laundry|fridge\w*|"
                       r"furniture|shopping|store|delivery|grocer\w*|dinner|breakfast|lunch)\b", re.I),
    "auto": re.compile(r"\b(автомобил\w*|машин[аыуе]\w*|двигател\w*|колес\w*|тормоз\w*|бензин\w*|дорог[аиу]\w*|"
                       r"водител\w*|парковк\w*|штраф\w*|пробк\w*|шин\w*|"
                       r"car|cars|engine\w*|wheel\w*|brake\w*|gasoline|fuel|road\w*|driver\w*|parking|traffic jam|tire\w*)\b", re.I),
    "sport": re.compile(r"\b(футбол\w*|хокке\w*|матч\w*|тренировк\w*|спортзал\w*|бег\w*|плаван\w*|команд[аы] выиграл\w*|"
                        r"чемпионат\w*|тренер\w*|гол\w*|"
                        r"football|soccer|hockey|match\w*|training|gym|running|swimming|championship\w*|coach\w*|goal\w*)\b", re.I),
    "travel": re.compile(r"\b(путешеств\w*|отпуск\w*|отел\w*|гостиниц\w*|билет\w*|самолёт\w*|самолет\w*|аэропорт\w*|"
                         r"виз[аыу]\w*|турист\w*|поезд\w*|вокзал\w*|"
                         r"travel\w*|vacation\w*|hotel\w*|ticket\w*|airplane|flight\w*|airport\w*|visa|tourist\w*|train|station)\b", re.I),
    "law": re.compile(r"\b(закон\w*|суд[аеы]?|правительств\w*|государств\w*|граждан\w*|полици\w*|договор\w*|"
                      r"юрист\w*|адвокат\w*|штраф\w*|паспорт\w*|"
                      r"law|laws|court\w*|government\w*|state|citizen\w*|police|contract\w*|lawyer\w*|attorney\w*|passport\w*)\b", re.I),
    "culture": re.compile(r"\b(фильм\w*|сериал\w*|музык\w*|концерт\w*|книг[аиу]\w*|роман\w*|актёр\w*|актер\w*|"
                          r"режиссёр\w*|альбом\w*|песн[яией]\w*|театр\w*|"
                          r"movie\w*|film\w*|series|music\w*|concert\w*|book\w*|novel\w*|actor\w*|director\w*|album\w*|song\w*|theat\w*)\b", re.I),
}


def stream_gz_lines_filtered(path, limit_general, limit_per_domain, scan_limit):
    """Из большого потока: первые limit_general строк — как есть, дальше сканируем до
    scan_limit и раскладываем по областям (DOMAINS), у каждой своя квота.
    Даёт (токены, область|None)."""
    n = scanned = 0
    quota = {d: 0 for d in DOMAINS}
    with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as f:
        for line in f:
            scanned += 1
            if scanned > scan_limit and n >= limit_general:
                return
            toks = tokenize(line)
            if not (3 <= len(toks) <= 60):
                continue
            if n < limit_general:
                n += 1
                yield toks, None
                continue
            for d, rx in DOMAINS.items():
                if quota[d] < limit_per_domain and rx.search(line):
                    quota[d] += 1
                    yield toks, d
                    break
            if n >= limit_general and all(q >= limit_per_domain for q in quota.values()):
                return


HTML_TAG = re.compile(r"<[^>]+>")
CODE_HTML = re.compile(r"<code>.*?</code>|<pre>.*?</pre>", re.S)


def stackexchange_posts(name, limit):
    """Posts.xml из дампа Stack Exchange: тело поста без HTML и кода, по абзацам."""
    import html
    import xml.etree.ElementTree as ET
    p = fetch(name, SOURCES[name])
    if not p:
        return
    outdir = os.path.join(DATA, name)
    posts = os.path.join(outdir, "Posts.xml")
    if not os.path.exists(posts):
        os.makedirs(outdir, exist_ok=True)
        try:
            import py7zr
        except ImportError:
            log("  ⚠️  нужен py7zr: python3 -m pip install --user py7zr")
            return
        log(f"  распаковываю {name}/Posts.xml…")
        with py7zr.SevenZipFile(p, "r") as z:
            z.extract(path=outdir, targets=["Posts.xml"])
    n = 0
    for _, el in ET.iterparse(posts, events=("end",)):
        if el.tag != "row":
            continue
        body = el.get("Body") or ""
        el.clear()
        body = CODE_HTML.sub(" ", body)
        body = html.unescape(HTML_TAG.sub(" ", body))
        for para in re.split(r"\n\s*\n|(?<=[.!?])\s+(?=[A-ZА-Я])", body):
            toks = tokenize(para)
            if 4 <= len(toks) <= 80:
                yield toks
                n += 1
                if n >= limit:
                    return


def load_moses_pairs(name, limit):
    """Параллельные пары из moses-zip OPUS (файлы .en/.ru строка к строке)."""
    p = fetch(name, SOURCES[name])
    if not p:
        return []
    pairs = []
    try:
        with zipfile.ZipFile(p) as z:
            en_name = next(n for n in z.namelist() if n.endswith(".en"))
            ru_name = next(n for n in z.namelist() if n.endswith(".ru"))
            with z.open(en_name) as fe, z.open(ru_name) as fr:
                fe = io.TextIOWrapper(fe, encoding="utf-8", errors="ignore")
                fr = io.TextIOWrapper(fr, encoding="utf-8", errors="ignore")
                for en_line, ru_line in zip(fe, fr):
                    if len(tokenize(ru_line)) >= 2 and len(tokenize(en_line)) >= 2:
                        pairs.append((ru_line, en_line))
                        if len(pairs) >= limit:
                            break
    except Exception as e:  # noqa: BLE001
        log(f"  ⚠️  {name} не прочитался: {e}")
    return pairs

TOKEN = re.compile(r"[a-zA-Zа-яА-ЯёЁ][a-zA-Zа-яА-ЯёЁ'\-]*")


def log(*a):
    print(*a, flush=True)


def fetch(name, url, tries=3):
    """Качает с докачкой (Range) и проверкой полноты по Content-Length: оборванный
    архив тихо ломает всё дальше по конвейеру, поэтому недокачанное не принимаем."""
    ext = ".tar.bz2" if url.endswith(".tar.bz2") else os.path.splitext(url)[1]
    dest = os.path.join(DATA, name + ext)
    part = dest + ".part"
    if os.path.exists(dest) and os.path.getsize(dest) > 1024:
        return dest
    for attempt in range(1, tries + 1):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        headers = {"User-Agent": "QSwitcher-sem/1.0"}
        if have:
            headers["Range"] = f"bytes={have}-"
            log(f"  докачиваю {name} с {have >> 20} МБ")
        else:
            log(f"  качаю {name}: {url}")
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=180) as r:
                total = r.headers.get("Content-Length")
                total = have + int(total) if total else None
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
            size = os.path.getsize(part)
            if total and size < total:
                log(f"  ⚠️  {name}: получено {size >> 20} из {total >> 20} МБ — попытка {attempt}")
                continue
            os.replace(part, dest)
            return dest
        except Exception as e:  # noqa: BLE001
            log(f"  ⚠️  {name} не скачался (попытка {attempt}): {e}")
    return None


def tokenize(line):
    return [t.lower() for t in TOKEN.findall(line)]


def stream_gz_lines(path, limit):
    n = 0
    with gzip.open(path, "rt", encoding="utf-8", errors="ignore") as f:
        for line in f:
            toks = tokenize(line)
            if 3 <= len(toks) <= 60:
                yield toks
                n += 1
                if n >= limit:
                    return


def load_parallel_pairs(limit):
    """Выровненные пары en-ru из OPUS (moses zip: en-ru.en и en-ru.ru, строка к строке).
    Пара кладётся в одну строку корпуса — так слова обоих языков становятся
    соседями по контексту, и пространства RU/EN выравниваются."""
    p = fetch("para-enru", SOURCES["para-enru"])
    if not p:
        return []
    pairs = []
    try:
        with zipfile.ZipFile(p) as z:
            en_name = next(n for n in z.namelist() if n.endswith(".en"))
            ru_name = next(n for n in z.namelist() if n.endswith(".ru"))
            with z.open(en_name) as fe, z.open(ru_name) as fr:
                fe = io.TextIOWrapper(fe, encoding="utf-8", errors="ignore")
                fr = io.TextIOWrapper(fr, encoding="utf-8", errors="ignore")
                for en_line, ru_line in zip(fe, fr):
                    pairs.append((ru_line, en_line))
                    if len(pairs) >= limit:
                        break
    except Exception as e:  # noqa: BLE001
        log(f"  ⚠️  параллельный корпус не прочитался: {e}")
    return pairs


def load_tatoeba_pairs(limit):
    """Пары (ru, en) через links.csv — склеиваются в одну строку для выравнивания."""
    ru_p = fetch("tatoeba-ru", SOURCES["tatoeba-ru"])
    en_p = fetch("tatoeba-en", SOURCES["tatoeba-en"])
    ln_p = fetch("tatoeba-links", SOURCES["tatoeba-links"])
    if not (ru_p and en_p and ln_p):
        return []
    ru, en = {}, {}
    for path, store in ((ru_p, ru), (en_p, en)):
        with bz2.open(path, "rt", encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3:
                    store[int(p[0])] = p[2]
    import tarfile
    pairs = []
    with tarfile.open(ln_p, "r:bz2") as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith("links.csv"))
        f = io.TextIOWrapper(tar.extractfile(member), encoding="utf-8")
        for line in f:
            a, b = line.rstrip("\n").split("\t")[:2]
            a, b = int(a), int(b)
            if a in ru and b in en:
                pairs.append((ru[a], en[b]))
                if len(pairs) >= limit:
                    break
    return pairs


def telegram_export(path):
    """Telegram Desktop → Export chat history → JSON (result.json)."""
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    msgs = d.get("messages", []) if isinstance(d, dict) else []
    if not msgs and isinstance(d, dict):
        for chat in d.get("chats", {}).get("list", []):
            msgs += chat.get("messages", [])
    out = []
    for m in msgs:
        t = m.get("text", "")
        if isinstance(t, list):
            t = "".join(x if isinstance(x, str) else x.get("text", "") for x in t)
        toks = tokenize(t)
        if len(toks) >= 2:
            out.append(toks)
    return out


CODE_BLOCK = re.compile(r"```.*?```", re.S)


def _paragraphs(text):
    text = CODE_BLOCK.sub(" ", text or "")
    out = []
    for para in re.split(r"\n\s*\n|\n(?=[#*\-] )", text):
        toks = tokenize(para)
        if len(toks) >= 3:
            out.append(toks)
    return out


def chatgpt_export(path):
    """ChatGPT → Settings → Data controls → Export data → conversations.json.
    Каждая беседа — дерево узлов mapping{id: {message: {author.role, content.parts}}}."""
    with open(path, encoding="utf-8") as f:
        convs = json.load(f)
    out = []
    for conv in convs if isinstance(convs, list) else []:
        for node in (conv.get("mapping") or {}).values():
            msg = node.get("message") or {}
            if (msg.get("author") or {}).get("role") not in ("user", "assistant"):
                continue
            parts = (msg.get("content") or {}).get("parts") or []
            text = " ".join(p for p in parts if isinstance(p, str))
            out += _paragraphs(text)
    return out


def claude_export(path):
    """Claude.ai → Settings → Privacy → Export data → conversations.json:
    список бесед с chat_messages[].text (sender human/assistant)."""
    with open(path, encoding="utf-8") as f:
        convs = json.load(f)
    out = []
    for conv in convs if isinstance(convs, list) else []:
        for m in conv.get("chat_messages") or []:
            text = m.get("text") or " ".join(
                c.get("text", "") for c in (m.get("content") or []) if isinstance(c, dict))
            out += _paragraphs(text)
    return out


def markdown_export(path):
    """Папка или файл .md/.txt (Perplexity и прочее, сохранённое руками) — по абзацам."""
    files = []
    if os.path.isdir(path):
        for dp, _, fn in os.walk(path):
            files += [os.path.join(dp, n) for n in fn if n.lower().endswith((".md", ".txt"))]
    else:
        files = [path]
    out = []
    for fp in files:
        with open(fp, encoding="utf-8", errors="ignore") as f:
            out += _paragraphs(f.read())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subs", type=int, default=3_000_000, help="строк субтитров на язык")
    ap.add_argument("--wiki", type=int, default=1_500_000, help="строк википедии на язык")
    ap.add_argument("--pairs", type=int, default=1_500_000, help="параллельных пар (OPUS moses en-ru)")
    ap.add_argument("--telegram", action="append", default=[], help="result.json экспорта Telegram")
    ap.add_argument("--extra", action="append", default=[], help="свой текст, по абзацу на строку")
    ap.add_argument("--chatgpt", action="append", default=[], help="conversations.json экспорта ChatGPT")
    ap.add_argument("--claude", action="append", default=[], help="conversations.json экспорта Claude.ai")
    ap.add_argument("--md", action="append", default=[], help="папка/файл .md/.txt (Perplexity и т.п.)")
    ap.add_argument("--personal-weight", type=int, default=5, help="сколько раз повторить личные строки")
    ap.add_argument("--domains", "--tech", action="store_true", dest="domains",
                    help="широкая база по областям: тематические выборки (IT, финансы, здоровье, семья/школа, дом, "
                         "авто, спорт, путешествия, право, культура) из субтитров и Википедии, Stack Exchange, "
                         "OPUS News/TED/UN/KDE/GNOME/Ubuntu; тематические строки ×2")
    ap.add_argument("--domain-lines", type=int, default=400_000, help="строк на область из каждого потока")
    ap.add_argument("--scan", type=int, default=40_000_000, help="сколько строк потока сканировать под фильтры")
    ap.add_argument("--se-lines", type=int, default=1_200_000, help="абзацев из каждого дампа Stack Exchange")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    random.seed(a.seed)
    os.makedirs(DATA, exist_ok=True)
    out_path = os.path.join(DATA, "corpus.txt")
    total = 0
    with open(out_path, "w", encoding="utf-8") as out:
        def emit(toks, times=1):
            nonlocal total
            line = " ".join(toks) + "\n"
            for _ in range(times):
                out.write(line)
                total += 1

        for name, limit in (("subs-ru", a.subs), ("subs-en", a.subs), ("wiki-ru", a.wiki), ("wiki-en", a.wiki)):
            p = fetch(name, SOURCES[name])
            if not p:
                continue
            n = 0
            per_domain = {}
            if a.domains:
                # общая выборка + тематические выборки по областям (×2 каждая)
                for toks, dom in stream_gz_lines_filtered(p, limit, a.domain_lines, a.scan):
                    emit(toks, 2 if dom else 1)
                    if dom:
                        per_domain[dom] = per_domain.get(dom, 0) + 1
                    else:
                        n += 1
            else:
                for toks in stream_gz_lines(p, limit):
                    emit(toks)
                    n += 1
            log(f"  {name}: {n} строк" + ("; " + ", ".join(f"{d} {c}" for d, c in sorted(per_domain.items())) if per_domain else ""))

        if a.domains:
            for name in ("se-ru", "se-serverfault", "se-unix"):
                n = 0
                for toks in stackexchange_posts(name, a.se_lines):
                    emit(toks, 2)
                    n += 1
                log(f"  {name}: {n} абзацев (×2)")
            for name, lim in (("news-enru", 300_000), ("ted-enru", 400_000), ("un-enru", 300_000),
                              ("kde-enru", 300_000), ("gnome-enru", 200_000), ("ubuntu-enru", 200_000)):
                pairs = load_moses_pairs(name, lim)
                for ru, en in pairs:
                    emit(tokenize(ru) + tokenize(en), 2)
                log(f"  {name}: {len(pairs)} пар (×2)")

        pairs = load_parallel_pairs(a.pairs)
        if len(pairs) < a.pairs // 10:
            log("  параллельного корпуса мало — добираю парами Tatoeba")
            pairs += load_tatoeba_pairs(a.pairs - len(pairs))
        if not pairs:
            log("  ⚠️  ПАР НЕТ: RU и EN окажутся в разных пространствах, "
                "сравнение тем между языками работать не будет")
        for ru, en in pairs:
            # Одна строка на пару: русское и английское предложение рядом — так их
            # слова становятся соседями по контексту и пространства выравниваются.
            emit(tokenize(ru) + tokenize(en))
        log(f"  параллельных пар: {len(pairs)}")

        personal = []
        for p in a.telegram:
            personal += telegram_export(p)
        for p in a.extra:
            with open(p, encoding="utf-8", errors="ignore") as f:
                personal += [tokenize(l) for l in f if len(tokenize(l)) >= 2]
        for p in a.chatgpt:
            n = len(personal); personal += chatgpt_export(p); log(f"  chatgpt {p}: {len(personal) - n} абзацев")
        for p in a.claude:
            n = len(personal); personal += claude_export(p); log(f"  claude {p}: {len(personal) - n} абзацев")
        for p in a.md:
            n = len(personal); personal += markdown_export(p); log(f"  md {p}: {len(personal) - n} абзацев")
        for toks in personal:
            emit(toks, a.personal_weight)
        log(f"  личных строк: {len(personal)} ×{a.personal_weight}")
    log(f"✅ {out_path}: {total} строк")


if __name__ == "__main__":
    main()
