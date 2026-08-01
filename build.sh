#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ ! -f "Sources/QSwitcher/Resources/ru.txt" ] || [ ! -f "Sources/QSwitcher/Resources/en.txt" ]; then
    echo "📚 Словарей нет, скачиваю..."
    ./fetch-dicts.sh
fi

swift build -c release
echo
echo "✅ Готово: $(pwd)/.build/release/QSwitcher"
echo "   Запустить: ./.build/release/QSwitcher"
echo "   Или собрать .app:  ./make-app.sh"
echo "   Или собрать .dmg:  ./make-dmg.sh"
