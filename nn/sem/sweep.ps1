# Сетка порогов n-грамм на винде: NgramMargin x NgramNoContextFactor (порт sweep.sh).
# Оба читаются из %APPDATA%\QSwitcher\config.json при старте прогона, пересборка не нужна.
# В конце конфиг возвращается как был.
#   powershell -File nn\sem\sweep.ps1 [-Test nn\sem\scan-phrases.txt] [-Exe C:\path\QSwitcher.exe]
# Смотреть: строку, где «испортил» минимален при «верно» не ниже нынешнего.
param(
    [string]$Test = "nn\sem\scan-phrases.txt",
    [string]$Exe = "windows\publish\QSwitcher.exe"
)
$ErrorActionPreference = "Stop"
$cfg = Join-Path $env:APPDATA "QSwitcher\config.json"
$report = Join-Path $env:APPDATA "QSwitcher\test-report.txt"
if (-not (Test-Path $cfg)) { Write-Error "нет $cfg" }
if (-not (Test-Path $Test)) { Write-Error "нет $Test" }
if (-not (Test-Path $Exe)) { Write-Error "нет $Exe" }
$backup = Get-Content $cfg -Raw -Encoding UTF8
try {
    "{0,-8} {1,-8} {2,8} {3,8} {4,9}" -f "margin", "factor", "верно", "молчал", "испортил"
    foreach ($M in 0.4, 0.6, 0.9, 1.3) {
        foreach ($F in 1, 2, 3, 4, 6) {
            $d = $backup | ConvertFrom-Json
            $d.NgramMargin = [double]$M
            $d.NgramNoContextFactor = [double]$F
            $d | ConvertTo-Json -Depth 10 | Set-Content $cfg -Encoding UTF8
            Remove-Item $report -ErrorAction SilentlyContinue
            Start-Process -FilePath $Exe -ArgumentList "--test", "`"$Test`"" -Wait -NoNewWindow -RedirectStandardOutput "NUL"
            $sum = (Get-Content $report -Encoding UTF8 | Select-String "^Итого:").Line
            # Итого: X/N верно, молчал S, испортил H
            if ($sum -match "Итого: (\d+)/\d+ верно, молчал (\d+), испортил (\d+)") {
                "{0,-8} {1,-8} {2,8} {3,8} {4,9}" -f $M, $F, $Matches[1], $Matches[2], $Matches[3]
            } else { "{0,-8} {1,-8} {2}" -f $M, $F, "нет итога — см. $report" }
        }
    }
} finally {
    Set-Content $cfg $backup -Encoding UTF8 -NoNewline
    "конфиг возвращён"
}
