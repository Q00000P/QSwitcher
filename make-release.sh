#!/bin/bash
# Собирает релизный .zip приложения и считает sha256 для Homebrew cask.
set -e
cd "$(dirname "$0")"

# Собираем .app (универсальный, с инкрементом билда)
./make-app.sh

VERSION=$(grep 'static let version' Sources/QSwitcher/Version.swift | head -1 | sed 's/.*"\(.*\)".*/\1/')
ZIP="QSwitcher-${VERSION}.zip"

rm -f "$ZIP"
# ditto сохраняет ресурс-форки и права, правильно пакует .app для macOS
ditto -c -k --keepParent QSwitcher.app "$ZIP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

echo
echo "════════════════════════════════════════"
echo "✅ Релиз собран: $ZIP"
echo "   Версия: $VERSION"
echo "   SHA256: $SHA"
echo "════════════════════════════════════════"
echo
echo "Для cask-формулы:"
echo "   version \"$VERSION\""
echo "   sha256 \"$SHA\""
echo
echo "Дальше:"
echo "  1. Создай релиз v$VERSION на GitHub"
echo "  2. Прикрепи $ZIP к релизу"
echo "  3. Обнови cask: version, sha256, url"
