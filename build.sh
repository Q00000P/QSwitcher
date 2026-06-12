#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ ! -f "Sources/AutoSwitcher/Resources/ru.txt" ] || [ ! -f "Sources/AutoSwitcher/Resources/en.txt" ]; then
    echo "📚 Словарей нет, скачиваю..."
    ./fetch-dicts.sh
fi

swift build -c release
echo
echo "✅ Готово: $(pwd)/.build/release/AutoSwitcher"
echo "   Запустить: ./.build/release/AutoSwitcher"
echo "   Или собрать .app:  ./make-app.sh"
echo "   Или собрать .dmg:  ./make-dmg.sh"
