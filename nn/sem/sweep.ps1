# Сетка параметров ядра 5 на винде: CoreTheta (порог свапа) x CorePi (смена языка).
# Оба читаются из %APPDATA%\QSwitcher\config.json при старте прогона, пересборка не нужна.
# В конце конфиг возвращается как был. Эталон подбора — nn/lm/eval_phrases.py (--set theta=…),
# здесь — проверка, что на винде собранный exe даёт то же.
#   powershell -File nn\sem\sweep.ps1 [-Test nn\sem\scan-phrases.txt] [-Exe C:\path\QSwitcher.exe]
# Смотреть: строку, где «испортил» минимален при «верно» не ниже нынешнего (θ 2.0, π 0.04).
param(
    [string]$Test = "nn\sem\scan-phrases.txt",
    [string]$Exe = "windows\publish\QSwitcher.exe"
)
$ErrorActionPreference = "Stop"
$cfg = Join-Path $env:APPDATA "QSwitcher\config.json"
$report = Join-Path $env:APPDATA "QSwitcher\test-report.txt"
$out = Join-Path $env:TEMP "qs-sweep-out.txt"
if (-not (Test-Path $cfg)) { Write-Error "нет $cfg — запусти QSwitcher один раз" }
if (-not (Test-Path $Test)) { Write-Error "нет $Test" }
if (-not (Test-Path $Exe)) { Write-Error "нет $Exe" }
$Test = (Resolve-Path $Test).Path
$backup = Get-Content $cfg -Raw -Encoding UTF8
try {
    "{0,-8} {1,-8} {2,8} {3,8} {4,9}" -f "theta", "pi", "верно", "молчал", "испортил"
    foreach ($T in 1.5, 2.0, 2.5, 3.0) {
        foreach ($P in 0.02, 0.04, 0.08) {
            $d = $backup | ConvertFrom-Json
            # Add-Member -Force: в старом config.json этих ключей может не быть
            $d | Add-Member -NotePropertyName Core -NotePropertyValue "v5" -Force
            $d | Add-Member -NotePropertyName CoreTheta -NotePropertyValue ([double]$T) -Force
            $d | Add-Member -NotePropertyName CorePi -NotePropertyValue ([double]$P) -Force
            $d | ConvertTo-Json -Depth 10 | Set-Content $cfg -Encoding UTF8
            Remove-Item $report -ErrorAction SilentlyContinue
            Start-Process -FilePath $Exe -ArgumentList "--test", "`"$Test`"" -Wait -NoNewWindow -RedirectStandardOutput $out
            $sum = (Get-Content $report -Encoding UTF8 | Select-String "^Итого:").Line
            # Итого: X/N верно, молчал S, испортил H
            if ($sum -match "Итого: (\d+)/\d+ верно, молчал (\d+), испортил (\d+)") {
                "{0,-8} {1,-8} {2,8} {3,8} {4,9}" -f $T, $P, $Matches[1], $Matches[2], $Matches[3]
            } else { "{0,-8} {1,-8} {2}" -f $T, $P, "нет итога — см. $report" }
        }
    }
} finally {
    Set-Content $cfg $backup -Encoding UTF8 -NoNewline
    "конфиг возвращён"
}
