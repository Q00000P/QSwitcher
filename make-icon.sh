#!/bin/bash
# Собирает QSwitcher.icns из PNG 1024x1024.
# Требует macOS (sips и iconutil входят в систему).
set -e
cd "$(dirname "$0")"

SRC="icon/QSwitcher-1024.png"
[ -f "$SRC" ] || { echo "❌ Нет $SRC"; exit 1; }

SET="icon/QSwitcher.iconset"
rm -rf "$SET"; mkdir -p "$SET"

for size in 16 32 128 256 512; do
    sips -z $size $size       "$SRC" --out "$SET/icon_${size}x${size}.png"      >/dev/null
    sips -z $((size*2)) $((size*2)) "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o icon/QSwitcher.icns
rm -rf "$SET"
echo "✅ icon/QSwitcher.icns готова"
echo "   Дальше ./make-app.sh подхватит её автоматически."
