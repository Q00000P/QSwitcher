# Создаёт самоподписанный сертификат для подписи QSwitcher.exe.
#
# ЗАЧЕМ. Без подписи каждая пересборка — новый неопознанный файл, и
# SmartScreen ругается на КАЖДЫЙ билд заново. С сертификатом (даже
# самоподписанным) Windows Defender видит одного и того же издателя между
# сборками, и если добавить сертификат в Доверенные издатели — предупреждение
# на этой машине пропадает.
#
# ЧЕГО НЕ ДАЁТ. На ЧУЖИХ машинах SmartScreen самоподписанный сертификат не
# знает точно так же, как не знает Gatekeeper на маке без Apple-нотаризации.
# Тем, кто качает релиз с GitHub, предупреждение всё равно покажется один раз —
# это нормально для опенсорсной утилиты без платного Authenticode-сертификата
# (тот стоит денег и требует юрлицо). Помогает только на этой машине.
#
# Запускать ОДИН РАЗ. Требует PowerShell от администратора (запись в
# LocalMachine\TrustedPublisher) — без прав администратора сертификат
# всё равно подпишет файл, просто SmartScreen на этой машине не замолчит.

$ErrorActionPreference = 'Stop'
$CertSubject = 'CN=QSwitcher Self-Signed'
$WorkDir = Join-Path $env:USERPROFILE '.qswitcher-cert'

Write-Host "🔐 Создаю самоподписанный сертификат для QSwitcher"
Write-Host ""

$existing = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $CertSubject }
if ($existing) {
    Write-Host "✅ Сертификат уже существует (отпечаток $($existing[0].Thumbprint))."
    Write-Host "   Пересоздать? Сначала удали: Remove-Item Cert:\CurrentUser\My\$($existing[0].Thumbprint)"
    exit 0
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

Write-Host "1/3 Генерирую ключ и сертификат (10 лет)…"
$cert = New-SelfSignedCertificate `
    -Subject $CertSubject `
    -Type CodeSigningCert `
    -KeyUsage DigitalSignature `
    -KeyAlgorithm RSA -KeyLength 2048 `
    -NotAfter (Get-Date).AddYears(10) `
    -CertStoreLocation Cert:\CurrentUser\My

Write-Host "2/3 Сохраняю резервную копию (.pfx)…"
$pwd = ConvertTo-SecureString -String 'qswitcher' -Force -AsPlainText
$pfxPath = Join-Path $WorkDir 'cert.pfx'
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pwd | Out-Null

Write-Host "3/3 Добавляю в Доверенные корневые и Доверенные издатели…"
Write-Host "    (если откажет — перезапусти PowerShell от администратора)"
try {
    $rootStore = Get-Item Cert:\LocalMachine\Root
    $rootStore.Open('ReadWrite')
    $rootStore.Add($cert)
    $rootStore.Close()

    $pubStore = Get-Item Cert:\LocalMachine\TrustedPublisher
    $pubStore.Open('ReadWrite')
    $pubStore.Add($cert)
    $pubStore.Close()
    Write-Host "    ✅ Добавлено в LocalMachine — SmartScreen на этой машине замолчит."
}
catch {
    Write-Host "    ⚠️  Нет прав администратора — добавляю только в CurrentUser."
    Write-Host "        SmartScreen может продолжать спрашивать. Чтобы исправить:"
    Write-Host "        запусти PowerShell от администратора и повтори make-cert.ps1"
    $rootStoreU = Get-Item Cert:\CurrentUser\Root
    $rootStoreU.Open('ReadWrite')
    $rootStoreU.Add($cert)
    $rootStoreU.Close()
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════"
Write-Host "✅ Готово. Сертификат: «QSwitcher Self-Signed»"
Write-Host "   Отпечаток: $($cert.Thumbprint)"
Write-Host ""
Write-Host "ВАЖНО — сохрани резервную копию:"
Write-Host "   $pfxPath  (пароль: qswitcher)"
Write-Host "Без неё после переустановки системы сертификат придётся"
Write-Host "создавать заново. Положи рядом с бэкапом проекта."
Write-Host ""
Write-Host "Дальше просто собирай: .\make-release.ps1 — он подхватит сертификат."
Write-Host "════════════════════════════════════════════════════════"
