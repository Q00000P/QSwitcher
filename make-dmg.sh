#!/bin/bash
set -e
cd "$(dirname "$0")"

# Сначала собираем .app
./make-app.sh

DMG="QSwitcher.dmg"
STAGING="dmg-staging"

rm -f "$DMG"
rm -rf "$STAGING"
mkdir "$STAGING"

cp -R QSwitcher.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "QSwitcher" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGING"

echo
echo "✅ Готово: $(pwd)/$DMG"
echo "   Двойной клик → перетащить QSwitcher.app в /Applications."
