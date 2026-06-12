#!/bin/bash
set -e
cd "$(dirname "$0")"

# === Инкремент номера билда ===
# Хранится в .build_number, увеличивается на 1 при каждой сборке.
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
VERSION_FILE="Sources/AutoSwitcher/Version.swift"
cat > "$VERSION_FILE" <<VEREOF
import Foundation

/// Информация о версии. BuildInfo переписывается make-app.sh при каждой сборке.
enum AppVersion {
    static let version = "0.7"
    static let build = BuildInfo.number
    static let buildDate = BuildInfo.date

    static var fullString: String {
        return "AutoSwitcher \\(version) (билд \\(build))"
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
if [ ! -f "Sources/AutoSwitcher/Resources/ru.txt" ] || [ ! -f "Sources/AutoSwitcher/Resources/en.txt" ]; then
    echo "📚 Словарей нет, скачиваю..."
    ./fetch-dicts.sh
fi

# Универсальный бинарь: arm64 (Apple Silicon) + x86_64 (Intel)
# Собираем для обеих архитектур и склеиваем lipo'ом.
echo "🔨 Сборка для arm64..."
swift build -c release --arch arm64

echo "🔨 Сборка для x86_64..."
swift build -c release --arch x86_64

ARM_BIN=".build/arm64-apple-macosx/release/AutoSwitcher"
X86_BIN=".build/x86_64-apple-macosx/release/AutoSwitcher"

if [ ! -f "$ARM_BIN" ] || [ ! -f "$X86_BIN" ]; then
    echo "⚠️ Один из бинарей не собрался, fallback на single-arch"
    swift build -c release
    UNIVERSAL_BIN=".build/release/AutoSwitcher"
else
    echo "🔗 Склеиваю универсальный бинарь..."
    lipo -create -output .build/AutoSwitcher-universal "$ARM_BIN" "$X86_BIN"
    UNIVERSAL_BIN=".build/AutoSwitcher-universal"
    echo "   Архитектуры: $(lipo -archs $UNIVERSAL_BIN)"
fi

APP="AutoSwitcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$UNIVERSAL_BIN" "$APP/Contents/MacOS/AutoSwitcher"

# Ресурсы из bundle (если SwiftPM сделал)
for arch in arm64 x86_64; do
    BUNDLE_RES=$(find .build/${arch}-apple-macosx/release -name "AutoSwitcher_AutoSwitcher.bundle" -type d 2>/dev/null | head -1)
    if [ -n "$BUNDLE_RES" ]; then
        cp -R "$BUNDLE_RES" "$APP/Contents/Resources/" 2>/dev/null || true
        break
    fi
done

# Прямое копирование данных (надёжнее всего)
cp Sources/AutoSwitcher/Resources/*.txt  "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/AutoSwitcher/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AutoSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>local.AutoSwitcher</string>
    <key>CFBundleName</key>
    <string>AutoSwitcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3</string>
    <key>CFBundleVersion</key>
    <string>3</string>
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
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo
echo "✅ Готово: $(pwd)/$APP"
echo "   Билд: #$BUILD_NUM ($BUILD_DATE)"
echo "   Архитектуры: $(lipo -archs $APP/Contents/MacOS/AutoSwitcher 2>/dev/null || echo 'не определены')"
echo "   Минимум macOS: 11.0 (Big Sur)"
