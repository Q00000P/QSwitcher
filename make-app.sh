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
APP_WAVE="wave53"

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

# Веса сети-детектора: nn/qsnet.bin (обучается nn/train.py) → ресурсы бандла.
# Нет весов — приложение работает на словарях, сборка не ломается.
if [ -f "nn/qsnet.bin" ]; then
    cp nn/qsnet.bin Sources/QSwitcher/Resources/qsnet.bin
    [ -f "nn/qsnet-selftest.json" ] && cp nn/qsnet-selftest.json Sources/QSwitcher/Resources/qsnet-selftest.json
    [ -f "nn/qsnet-replay.json" ] && cp nn/qsnet-replay.json Sources/QSwitcher/Resources/qsnet-replay.json
    echo "🧠 Веса сети: nn/qsnet.bin ($(du -h nn/qsnet.bin | cut -f1))"
else
    echo "⚠️  nn/qsnet.bin нет — сеть будет выключена (python3 nn/train.py)"
fi
# Семантические векторы: nn/sem/qsvec.bin (python3 nn/sem/train_vectors.py)
if [ -f "nn/sem/qsvec.bin" ]; then
    cp nn/sem/qsvec.bin Sources/QSwitcher/Resources/qsvec.bin
    [ -f "nn/sem/qsvec-topics.json" ] && cp nn/sem/qsvec-topics.json Sources/QSwitcher/Resources/qsvec-topics.json
    echo "🧭 Векторы: nn/sem/qsvec.bin ($(du -h nn/sem/qsvec.bin | cut -f1))"
else
    echo "⚠️  nn/sem/qsvec.bin нет — семантика будет выключена"
fi

# N-граммы языка: nn/ngram/qsngram.bin (python3 nn/ngram/build.py)
if [ -f "nn/ngram/qsngram.bin" ]; then
    cp nn/ngram/qsngram.bin Sources/QSwitcher/Resources/qsngram.bin
    echo "🔡 N-граммы: nn/ngram/qsngram.bin ($(du -h nn/ngram/qsngram.bin | cut -f1))"
else
    echo "⚠️  nn/ngram/qsngram.bin нет — n-граммы будут выключены (python3 nn/ngram/build.py)"
fi

# Ядро 5: символьная модель языка nn/lm/qschar.bin (python3 nn/lm/charlm.py train)
# и эталон самопроверки порта nn/lm/core5-selftest.json (python3 nn/lm/make_selftest.py)
if [ -f "nn/lm/qschar.bin" ]; then
    cp nn/lm/qschar.bin Sources/QSwitcher/Resources/qschar.bin
    [ -f "nn/lm/core5-selftest.json" ] && cp nn/lm/core5-selftest.json Sources/QSwitcher/Resources/core5-selftest.json
    echo "🔤 Символьная модель: nn/lm/qschar.bin ($(du -h nn/lm/qschar.bin | cut -f1))"
else
    echo "⚠️  nn/lm/qschar.bin нет — ядро 5 будет без символьной модели (python3 nn/lm/charlm.py train)"
fi

# Если словарей нет — скачиваем
if [ ! -f "Sources/QSwitcher/Resources/ru.txt" ] || [ ! -f "Sources/QSwitcher/Resources/en.txt" ]; then
    echo "📚 Словарей нет, скачиваю..."
    ./fetch-dicts.sh
fi

# Универсальный бинарь: arm64 (Apple Silicon) + x86_64 (Intel).
# Каждую архитектуру собираем отдельно и СРАЗУ забираем результат. Новый SwiftPM
# (swiftbuild, Xcode 27 / macOS 27) кладёт обе в один .build/out/Products/Release —
# вторая сборка затирает первую, а старые .build/<arch>-apple-macosx/release больше
# не обновляются: оттуда в .app попадал бинарь от 10 сентября, свежий код молча
# не доезжал. Где лежит результат, спрашиваем у самого SwiftPM (--show-bin-path)
# и проверяем архитектуру lipo.
BIN_DIR=""
build_arch() {
    local arch=$1 dir
    echo "🔨 Сборка для $arch..."
    swift build -c release --arch "$arch" || return 1
    dir=$(swift build -c release --arch "$arch" --show-bin-path) || return 1
    # Version.swift переписан в начале скрипта — бинарь обязан быть новее .build_number,
    # иначе это не результат этой сборки
    if [ ! "$dir/QSwitcher" -nt "$BUILD_FILE" ]; then
        echo "⚠️  $dir/QSwitcher не пересобран (старше начала сборки)"
        return 1
    fi
    cp "$dir/QSwitcher" ".build/QSwitcher-$arch" || return 1
    if [ "$(lipo -archs ".build/QSwitcher-$arch" 2>/dev/null)" != "$arch" ]; then
        echo "⚠️  $dir/QSwitcher — не $arch ($(lipo -archs ".build/QSwitcher-$arch" 2>/dev/null))"
        return 1
    fi
    [ -z "$BIN_DIR" ] && BIN_DIR="$dir"
    return 0
}
rm -f .build/QSwitcher-arm64 .build/QSwitcher-x86_64 .build/QSwitcher-universal
ARM_OK=0; X86_OK=0
build_arch arm64 && ARM_OK=1
build_arch x86_64 && X86_OK=1

if [ "$ARM_OK" = 1 ] && [ "$X86_OK" = 1 ]; then
    echo "🔗 Склеиваю универсальный бинарь..."
    lipo -create -output .build/QSwitcher-universal .build/QSwitcher-arm64 .build/QSwitcher-x86_64
    UNIVERSAL_BIN=".build/QSwitcher-universal"
    echo "   Архитектуры: $(lipo -archs $UNIVERSAL_BIN)"
elif [ "$ARM_OK" = 1 ]; then
    echo "⚠️  x86_64 не собрался — только arm64"
    UNIVERSAL_BIN=".build/QSwitcher-arm64"
else
    echo "⚠️  Сборка по архитектурам не удалась, fallback на single-arch"
    swift build -c release
    BIN_DIR=$(swift build -c release --show-bin-path)
    UNIVERSAL_BIN="$BIN_DIR/QSwitcher"
fi
# Страховка от устаревшего бинаря (fallback-ветка): он обязан быть новее начала сборки
if [ ! "$UNIVERSAL_BIN" -nt "$BUILD_FILE" ]; then
    echo "❌ $UNIVERSAL_BIN старше начала сборки — это не свежий бинарь. Останавливаюсь."
    exit 1
fi

APP="QSwitcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$UNIVERSAL_BIN" "$APP/Contents/MacOS/QSwitcher"

# Ресурсы из bundle (если SwiftPM сделал) — рядом с бинарём этой сборки
BUNDLE_RES=$(find "${BIN_DIR:-.build/release}" -maxdepth 1 -name "QSwitcher_QSwitcher.bundle" -type d 2>/dev/null | head -1)
if [ -n "$BUNDLE_RES" ]; then
    cp -R "$BUNDLE_RES" "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Прямое копирование данных (надёжнее всего)
cp Sources/QSwitcher/Resources/*.txt  "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/QSwitcher/Resources/*.json "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/QSwitcher/Resources/*.bin  "$APP/Contents/Resources/" 2>/dev/null || true

# Иконка (если собрана через ./make-icon.sh)
if [ -f "icon/QSwitcher.icns" ]; then
    cp icon/QSwitcher.icns "$APP/Contents/Resources/"
    echo "🎨 Иконка подключена"
else
    echo "ℹ️  Иконки нет — запусти ./make-icon.sh чтобы собрать"
fi

# Синхронизация через Google Drive: client id и secret Desktop-клиента Google — ТОЛЬКО из
# переменных окружения QS_GOOGLE_CLIENT_ID / QS_GOOGLE_CLIENT_SECRET (в репозитории их нет).
# Нет переменных — Google Drive в этой сборке недоступен, WebDAV работает.
# Не видны в этом процессе (dev-watch запущен раньше, чем их задали) — спросить zsh: он читает
# ~/.zshenv при каждом запуске, там их и держать.
if { [ -z "${QS_GOOGLE_CLIENT_ID:-}" ] || [ -z "${QS_GOOGLE_CLIENT_SECRET:-}" ]; } && [ -x /bin/zsh ]; then
    QS_GOOGLE_CLIENT_ID=$(/bin/zsh -c 'printf "%s" "$QS_GOOGLE_CLIENT_ID"' 2>/dev/null </dev/null || true)
    QS_GOOGLE_CLIENT_SECRET=$(/bin/zsh -c 'printf "%s" "$QS_GOOGLE_CLIENT_SECRET"' 2>/dev/null </dev/null || true)
fi
GOOGLE_KEYS=""
if [ -n "${QS_GOOGLE_CLIENT_ID:-}" ] && [ -n "${QS_GOOGLE_CLIENT_SECRET:-}" ]; then
    GOOGLE_KEYS="    <key>QSGoogleClientID</key>
    <string>${QS_GOOGLE_CLIENT_ID}</string>
    <key>QSGoogleClientSecret</key>
    <string>${QS_GOOGLE_CLIENT_SECRET}</string>"
    echo "🔑 Google Drive: ключ из переменных окружения"
else
    echo "ℹ️  QS_GOOGLE_CLIENT_ID / QS_GOOGLE_CLIENT_SECRET не заданы (~/.zshenv) — Google Drive в этой сборке недоступен (WebDAV работает)"
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
${GOOGLE_KEYS}
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
