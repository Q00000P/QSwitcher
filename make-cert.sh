#!/bin/bash
# Создаёт самоподписанный сертификат для подписи QSwitcher.
#
# ЗАЧЕМ. При ad-hoc подписи (codesign --sign -) идентичность приложения
# определяется хешем самого бинаря. Каждая пересборка даёт новый хеш, TCC считает
# это ДРУГИМ приложением, и права Accessibility слетают. С сертификатом
# идентичность привязана к нему, а не к содержимому — права держатся между сборками.
#
# ЧЕГО НЕ ДАЁТ. Для чужих маков ничего не меняется: Gatekeeper самоподписанный
# сертификат не знает так же как и ad-hoc. Помогает только локально.
#
# Запускать ОДИН РАЗ. Потом make-app.sh найдёт сертификат сам.

set -e

CERT_NAME="QSwitcher Self-Signed"
WORK_DIR="$HOME/.qswitcher-cert"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "🔐 Создаю самоподписанный сертификат для QSwitcher"
echo

# Уже есть?
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✅ Сертификат «$CERT_NAME» уже существует."
    echo "   Пересоздать? Сначала удали: security delete-certificate -c \"$CERT_NAME\""
    exit 0
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Срок 10 лет — чтобы не сломалось через год в самый неудобный момент
cat > openssl.cnf << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = QSwitcher Self-Signed

[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

echo "1/4 Генерирую ключ и сертификат (10 лет)…"
openssl req -x509 -newkey rsa:2048 \
    -keyout key.pem -out cert.pem \
    -days 3650 -nodes -config openssl.cnf 2>/dev/null

echo "2/4 Упаковываю в .p12…"
# ВАЖНО: openssl 3.x по умолчанию шифрует AES-256, а Keychain это не читает
# и импорт падает с «One or more parameters were not valid». Нужны старые
# алгоритмы PBE-SHA1-3DES, иначе сертификат в связку не попадёт.
openssl pkcs12 -export \
    -inkey key.pem -in cert.pem -out cert.p12 \
    -passout pass:qswitcher \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    || { echo "❌ Не удалось упаковать .p12"; exit 1; }

echo "3/4 Импортирую в связку ключей…"
# -T /usr/bin/codesign — разрешаем codesign пользоваться ключом без запроса
if ! security import cert.p12 -k "$KEYCHAIN" -P qswitcher -T /usr/bin/codesign -A; then
    echo
    echo "❌ Импорт в связку ключей не удался."
    echo "   Сделай через интерфейс — способ надёжнее:"
    echo "   Связка ключей → меню Certificate Assistant → Create a Certificate"
    echo "     Name: QSwitcher Self-Signed"
    echo "     Identity Type: Self Signed Root"
    echo "     Certificate Type: Code Signing"
    echo "     галка «Let me override defaults», срок 3650 дней"
    echo "   Потом двойной клик по сертификату → Trust → Code Signing: Always Trust"
    exit 1
fi

echo "4/4 Помечаю как доверенный для подписи кода…"
echo "    (система спросит пароль — это нормально)"
security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain cert.pem 2>/dev/null \
  || security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN" cert.pem \
  || echo "    ⚠️ Не удалось пометить доверенным — подпись обычно работает и так"

echo
echo "════════════════════════════════════════════════════════"
echo "✅ Готово. Сертификат: «$CERT_NAME»"
echo
echo "ВАЖНО — сохрани резервную копию:"
echo "   $WORK_DIR/cert.p12"
echo "Без неё после переустановки системы придётся выдавать"
echo "Accessibility заново. Положи рядом с бэкапом проекта."
echo
echo "Проверить что видно для подписи:"
echo "   security find-identity -v -p codesigning"
echo
echo "Дальше просто собирай: ./make-app.sh — он подхватит сертификат."
echo "ПЕРВЫЙ раз после перехода права Accessibility надо выдать заново"
echo "(идентичность приложения изменилась), дальше держатся."
echo "════════════════════════════════════════════════════════"
