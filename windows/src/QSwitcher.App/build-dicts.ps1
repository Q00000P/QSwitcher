# Скачивает и готовит словари ru.txt/en.txt перед сборкой (аналог fetch-dicts.sh).
# Вызывается из QSwitcher.App.csproj (Target DownloadDicts). Если словари уже
# на месте и нормального размера — мгновенный no-op, сборка не замедляется.
$ErrorActionPreference = 'Stop'
$res = Join-Path $PSScriptRoot 'Resources'
$ruPath = Join-Path $res 'ru.txt'
$enPath = Join-Path $res 'en.txt'

function SizeOf($p) { if (Test-Path $p) { (Get-Item $p).Length } else { 0 } }
# ru нормальный ~50 МБ, en ~4 МБ; всё меньше мегабайта — битое/страница 404
if ((SizeOf $ruPath) -gt 1MB -and (SizeOf $enPath) -gt 1MB) { exit 0 }

Write-Host 'QSwitcher: словарей нет — скачиваю и готовлю (разово, пара минут)...'
$tmp = $env:TEMP
curl.exe -fsSL -o "$tmp\qs-ru-raw.txt" 'https://raw.githubusercontent.com/danakt/russian-words/master/russian.txt'
curl.exe -fsSL -o "$tmp\qs-ru-sur.txt" 'https://raw.githubusercontent.com/danakt/russian-words/master/russian_surnames.txt'
curl.exe -fsSL -o "$tmp\qs-en-raw.txt" 'https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt'

$enc1251 = [Text.Encoding]::GetEncoding(1251)
$utf8 = [Text.UTF8Encoding]::new($false)
function Read-Dict($p) {
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    if ($t -notmatch '[а-яА-ЯёЁ]') { $t = [IO.File]::ReadAllText($p, $enc1251) }
    $t
}

$ru = [Collections.Generic.HashSet[string]]::new()
foreach ($f in "$tmp\qs-ru-raw.txt", "$tmp\qs-ru-sur.txt") {
    foreach ($l in (Read-Dict $f) -split "`n") {
        $w = $l.Trim().ToLower()
        if ($w.Length -ge 2 -and $w -cmatch '^[а-яё]+$') { [void]$ru.Add($w) }
    }
}
[IO.File]::WriteAllLines($ruPath, $ru, $utf8)

$en = [Collections.Generic.HashSet[string]]::new()
foreach ($l in [IO.File]::ReadLines("$tmp\qs-en-raw.txt")) {
    $w = $l.Trim().ToLower()
    if ($w.Length -ge 2 -and $w -cmatch '^[a-z]+$') { [void]$en.Add($w) }
}
[IO.File]::WriteAllLines($enPath, $en, $utf8)

Remove-Item "$tmp\qs-ru-raw.txt", "$tmp\qs-ru-sur.txt", "$tmp\qs-en-raw.txt" -ErrorAction SilentlyContinue
Write-Host "QSwitcher: словари готовы (ru: $($ru.Count) слов, en: $($en.Count) слов)"
