#!/bin/bash
# Скачивает большие словари RU и EN.
# Использует Python для обработки UTF-8 (BSD tr на macOS не умеет многобайтовые символы).
#
# Источники:
#   RU:  github.com/danakt/russian-words/russian.txt          (~1.5М словоформ)
#   RU:  github.com/danakt/russian-words/russian_surnames.txt (~250к фамилий)
#   EN:  github.com/dwyl/english-words/words_alpha.txt        (~466к словоформ)

set -e
cd "$(dirname "$0")"

OUT_DIR="Sources/AutoSwitcher/Resources"
mkdir -p "$OUT_DIR"

RU_URL="https://raw.githubusercontent.com/danakt/russian-words/master/russian.txt"
RU_SURNAMES_URL="https://raw.githubusercontent.com/danakt/russian-words/master/russian_surnames.txt"
EN_URL="https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

echo "📥 Качаю русские слова (~25 МБ)..."
curl -fsSL --retry 3 -o "$TMP/ru-raw.txt" "$RU_URL" || { echo "❌ Не скачалось"; exit 1; }

echo "📥 Качаю русские фамилии (~5 МБ)..."
curl -fsSL --retry 3 -o "$TMP/ru-surnames-raw.txt" "$RU_SURNAMES_URL" || {
    echo "⚠️  Фамилии не скачались, продолжаю без них"
    : > "$TMP/ru-surnames-raw.txt"
}

echo "📥 Качаю английские слова (~4 МБ)..."
curl -fsSL --retry 3 -o "$TMP/en-raw.txt" "$EN_URL" || { echo "❌ Не скачалось"; exit 1; }

echo "⚙️  Обрабатываю через Python (UTF-8 + дедупликация)..."

python3 << PYEOF
import re

def detect_decode(path):
    """Читаем файл с попыткой определения кодировки."""
    with open(path, 'rb') as f:
        raw = f.read()
    if not raw:
        return ""
    # Пробуем UTF-8
    try:
        text = raw.decode('utf-8')
        # Проверим что есть кириллица
        if re.search(r'[А-Яа-яёЁ]', text):
            return text
    except UnicodeDecodeError:
        pass
    # Пробуем CP1251
    try:
        text = raw.decode('cp1251')
        if re.search(r'[А-Яа-яёЁ]', text):
            return text
    except UnicodeDecodeError:
        pass
    # Fallback на latin-1 (всегда декодируется)
    return raw.decode('latin-1', errors='ignore')

# === Русский ===
ru_text = detect_decode("$TMP/ru-raw.txt")
ru_surnames_text = detect_decode("$TMP/ru-surnames-raw.txt")

ru_words = set()
ru_pattern = re.compile(r'^[а-яё]+$')
for line in (ru_text + "\n" + ru_surnames_text).split("\n"):
    w = line.strip().lower()
    if len(w) >= 2 and ru_pattern.match(w):
        ru_words.add(w)

with open("$OUT_DIR/ru.txt", "w", encoding="utf-8") as f:
    for w in sorted(ru_words):
        f.write(w + "\n")

# === Английский ===
with open("$TMP/en-raw.txt", "rb") as f:
    en_text = f.read().decode('utf-8', errors='ignore')

en_words = set()
en_pattern = re.compile(r'^[a-z]+$')
for line in en_text.split("\n"):
    w = line.strip().lower()
    if len(w) >= 2 and en_pattern.match(w):
        en_words.add(w)

with open("$OUT_DIR/en.txt", "w", encoding="utf-8") as f:
    for w in sorted(en_words):
        f.write(w + "\n")

print(f"   ru: {len(ru_words)} слов")
print(f"   en: {len(en_words)} слов")
PYEOF

RU_SIZE=$(du -h "$OUT_DIR/ru.txt" | cut -f1)
EN_SIZE=$(du -h "$OUT_DIR/en.txt" | cut -f1)
RU_COUNT=$(wc -l < "$OUT_DIR/ru.txt" | tr -d ' ')
EN_COUNT=$(wc -l < "$OUT_DIR/en.txt" | tr -d ' ')

echo
echo "✅ Готово:"
echo "   $OUT_DIR/ru.txt: $RU_COUNT слов ($RU_SIZE)"
echo "   $OUT_DIR/en.txt: $EN_COUNT слов ($EN_SIZE)"
echo
echo "Ожидаемые цифры: ru ~1.5М, en ~370к"
