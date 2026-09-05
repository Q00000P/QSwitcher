#!/bin/bash
set -e
cd "$(dirname "$0")"

# === Инкремент номера билда ===
# Хранится в .build_number, увеличивается на 1 при каждой сборке.
# Версия приложения — ЕДИНСТВЕННЫЙ источник правды.
# Раньше она дублировалась в Version.swift и в Info.plist, причём в plist была
# захардкожена и никогда не обновлялась: система показывала 0.3 независимо
# от реальной версии, и то же самое попадало в отчёты о падениях.
APP_VERSION="4.0"
# Метка волны разработки — видна в логе запуска и в «О программе».
APP_WAVE="wave5"

BUILD_FILE=".build_number"
if [ -f "$BUILD_FILE" ]; then
    BUILD_NUM=$(cat "$BUILD_FILE")
else
    BUILD_NUM=0
fi
BUILD_NUM=$((BUILD_NUM + 1))
echo "$BUILD_NUM" > "$BUILD_FILE"
BUILD_DATE=$(date "+%Y-%m-%d %H:%M")

# Подставляем в Version.swift
VERSION_FILE="Sources/QSwitcher/Version.swift"
cat > "$VERSION_FILE" <<VEREOF
import Foundation

/// Информация о версии. BuildInfo переписывается make-app.sh при каждой сборке.
enum AppVersion {
    static let version = "$APP_VERSION"
    static let build = BuildInfo.number
    static let buildDate = BuildInfo.date
    /// Метка волны разработки (задаётся в make-app.sh).
    static let wave = "$APP_WAVE"

    static var fullString: String {
        return "QSwitcher \\(version) (\\(wave), билд \\(build))"
    }
}

/// Автогенерируется make-app.sh — не редактировать руками.
enum BuildInfo {
    static let number = "$BUILD_NUM"
    static let date = "$BUILD_DATE"
}
VEREOF

echo "🔢 Билд #$BUILD_NUM ($BUILD_DATE)"

# Если словарей нет — скачиваем
if [ ! -f "Sources/QSwitcher/Resources/ru.txt" ] || [ ! -f "Sources/QSwitcher/Resources/en.txt" ]; then
    echo "📚 Словарей нет, скачиваю..."
    ./fetch-dicts.sh
fi

# Универсальный бинарь: arm64 (Apple Silicon) + x86_64 (Intel)
# Собираем для обеих архитектур и склеиваем lipo'ом.
echo "🔨 Сборка для arm64..."
swift build -c release --arch arm64

echo "🔨 Сборка для x86_64..."
swift build -c release --arch x86_64

ARM_BIN=".build/arm64-apple-macosx/release/QSwitcher"
X86_BIN=".build/x86_64-apple-macosx/release/QSwitcher"

if [ ! -f "$ARM_BIN" ] || [ ! -f "$X86_BIN" ]; then
    echo "⚠️ Один из бинарей не собрался, fallback на single-arch"
    swift build -c release
    UNIVERSAL_BIN=".build/release/QSwitcher"
else
    echo "🔗 Склеиваю универсальный бинарь..."
    lipo -create -output .build/QSwitcher-universal "$ARM_BIN" "$X86_BIN"
    UNIVERSAL_BIN=".build/QSwitcher-universal"
    echo "   Архитектуры: $(lipo -archs $UNIVERSAL_BIN)"
fi

APP="QSwitcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$UNIVERSAL_BIN" "$APP/Contents/MacOS/QSwitcher"

# Ресурсы из bundle (если SwiftPM сделал)
for arch in arm64 x86_64; do
    BUNDLE_RES=$(find .build/${arch}-apple-macosx/release -name "QSwitcher_QSwitcher.bundle" -type d 2>/dev/null | head -1)
    if [ -n "$BUNDLE_RES" ]; then
        cp -R "$BUNDLE_RES" "$APP/Contents/Resources/" 2>/dev/null || true
        break
    fi
done

# Прямое копирование данных (надёжнее всего)
cp Sources/QSwitcher/Resources/*.txt  "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/QSwitcher/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || true

# Иконка (если собрана через ./make-icon.sh)
if [ -f "icon/QSwitcher.icns" ]; then
    cp icon/QSwitcher.icns "$APP/Contents/Resources/"
    echo "🎨 Иконка подключена"
else
    echo "ℹ️  Иконки нет — запусти ./make-icon.sh чтобы собрать"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>QSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>local.QSwitcher</string>
    <key>CFBundleIconFile</key>
    <string>QSwitcher</string>
    <key>CFBundleName</key>
    <string>QSwitcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUM</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSFaceIDUsageDescription</key>
    <string>Подтверждение для изменения настроек защищённого лога и доступа к нему.</string>
</dict>
</plist>
EOF

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Ad-hoc подпись. Для Secure Enclave / Keychain при локальной (ad-hoc) подписи
# НЕЛЬЗЯ указывать keychain-access-groups с произвольным именем — это ломает запуск
# (нужен Team ID). Enclave-ключи работают и без явной группы: они привязаны к
# подписи приложения. Подписываем без entitlements.
# Подпись. Если есть самоподписанный сертификат — подписываем им: тогда
# идентичность приложения стабильна между сборками и права Accessibility
# не слетают. Иначе откатываемся на ad-hoc (права будут слетать каждый билд).
CERT_NAME="QSwitcher Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --deep --sign "$CERT_NAME" "$APP" 2>/dev/null \
        && echo "🔏 Подписано сертификатом «$CERT_NAME» (права не слетят)" \
        || { codesign --force --deep --sign - "$APP" 2>/dev/null || true; \
             echo "⚠️  Подпись сертификатом не удалась — ad-hoc"; }
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "🔏 Ad-hoc подпись. Права Accessibility будут слетать каждую пересборку."
    echo "   Разово запусти ./make-cert.sh чтобы это прекратилось."
fi

echo
echo "✅ Готово: $(pwd)/$APP"
echo "   Билд: #$BUILD_NUM ($BUILD_DATE)"
echo "   Архитектуры: $(lipo -archs $APP/Contents/MacOS/QSwitcher 2>/dev/null || echo 'не определены')"
echo "   Минимум macOS: 11.0 (Big Sur)"
