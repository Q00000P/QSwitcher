# Собирает релизный QSwitcher.exe, подписывает сертификатом (если есть) и
# упаковывает в zip. Аналог ../make-release.sh на маке.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir = Join-Path $Root 'src\QSwitcher.App'

$Version = (Select-String -Path (Join-Path $AppDir 'Program.cs') -Pattern 'Version = "(.*)"').Matches[0].Groups[1].Value
Write-Host "🔢 Версия: $Version"

Write-Host "🔨 Публикация (single-file, self-contained)…"
Push-Location $AppDir
dotnet publish -c Release
Pop-Location

$PublishDir = Join-Path $AppDir 'bin\Release\net8.0-windows10.0.19041.0\win-x64\publish'
$ExePath = Join-Path $PublishDir 'QSwitcher.exe'
if (-not (Test-Path $ExePath)) { throw "Не нашёл $ExePath — publish не удался?" }

# === Подпись ===
# Тот же принцип что на маке: сертификат делает идентичность издателя
# стабильной между сборками. Ищем signtool.exe (часть Windows SDK).
$CertSubject = 'CN=QSwitcher Self-Signed'
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1

if ($cert) {
    $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*x64*' } | Select-Object -First 1 -ExpandProperty FullName

    if ($signtool) {
        Write-Host "🔏 Подписываю сертификатом «QSwitcher Self-Signed»…"
        & $signtool sign /sha1 $cert.Thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $ExePath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "⚠️  Подпись не удалась (код $LASTEXITCODE) — публикую неподписанным."
        }
        else {
            Write-Host "✅ Подписано."
        }
    }
    else {
        Write-Host "⚠️  signtool.exe не найден (нужен Windows SDK) — публикую неподписанным."
        Write-Host "    Поставь: winget install Microsoft.WindowsSDK"
    }
}
else {
    Write-Host "⚠️  Сертификат не найден — публикую неподписанным."
    Write-Host "   Разово запусти .\make-cert.ps1 чтобы SmartScreen не ругался на КАЖДУЮ сборку."
}

# === Упаковка ===
$Zip = Join-Path $Root "QSwitcher-win-$Version.zip"
Remove-Item $Zip -ErrorAction SilentlyContinue
Compress-Archive -Path $ExePath -DestinationPath $Zip -Force
$Sha = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLower()

Write-Host ""
Write-Host "════════════════════════════════════════"
Write-Host "✅ Релиз собран: $Zip"
Write-Host "   Версия: $Version"
Write-Host "   SHA256: $Sha"
Write-Host "════════════════════════════════════════"
Write-Host ""
Write-Host "Дальше:"
Write-Host "  gh release create win-$Version `"$Zip`" --title `"QSwitcher для Windows $Version`""
