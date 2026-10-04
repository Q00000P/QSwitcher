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
# === Манифест для сервера обновлений (тот же формат, что version-win.json) ===
TAG="v$VERSION"
REPO="Q00000P/QSwitcher"
cat > version-mac.json <<JSON
{
  "version": "$VERSION",
  "sha256": "$SHA",
  "url": "https://github.com/$REPO/releases/download/$TAG/$ZIP",
  "page": "https://github.com/$REPO/releases/tag/$TAG",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "📄 Манифест: version-mac.json"

# === Релиз на GitHub ===
# Нужен gh (brew install gh) и вход (gh auth login) — один раз.
# Описание — release-notes/<версия>.md (общее с виндой, её релиз собирает GitHub Actions).
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    NOTES="release-notes/$VERSION.md"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "🚀 Релиз $TAG уже есть — заменяю файлы"
    else
        echo "🚀 Создаю релиз $TAG"
        if [ -f "$NOTES" ]; then
            gh release create "$TAG" -R "$REPO" --target main --title "QSwitcher $VERSION" --notes-file "$NOTES"
        else
            gh release create "$TAG" -R "$REPO" --target main --title "QSwitcher $VERSION" --notes "QSwitcher $VERSION для macOS."
        fi
    fi
    gh release upload "$TAG" -R "$REPO" "$ZIP" version-mac.json --clobber \
        && echo "✅ Опубликовано: https://github.com/$REPO/releases/tag/$TAG"
else
    echo "Дальше:"
    echo "  1. Создай релиз $TAG на GitHub (или поставь gh: brew install gh && gh auth login — и перезапусти)"
    echo "  2. Прикрепи $ZIP и version-mac.json к релизу"
    echo "  3. Обнови cask: version, sha256, url"
fi
