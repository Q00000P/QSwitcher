# AutoSwitcher — полный исходник проекта

Утилита автоматического переключения раскладки RU↔EN для macOS,
аналог Punto Switcher. Собирается универсальным бинарём (Intel + ARM).

## Первый запуск (с нуля)

```bash
cd ~/Downloads
tar -xzf AutoSwitcher-source.tar.gz
cd AutoSwitcher
chmod +x *.sh

# 1. Скачать словари (один раз, ~50 МБ из GitHub)
./fetch-dicts.sh

# 2. Собрать .app
./make-app.sh

# 3. Скопировать в /Applications
cp -R AutoSwitcher.app /Applications/

# 4. Удалить сборочную копию (чтобы не висело в Spotlight)
rm -rf AutoSwitcher.app

# 5. Запустить и дать Accessibility
open /Applications/AutoSwitcher.app
```

## Пересборка после правок кода

```bash
cd ~/Downloads/AutoSwitcher
killall AutoSwitcher 2>/dev/null
rm -rf .build /Applications/AutoSwitcher.app AutoSwitcher.app
./make-app.sh
cp -R AutoSwitcher.app /Applications/
rm -rf AutoSwitcher.app
killall AutoSwitcher 2>/dev/null
open /Applications/AutoSwitcher.app
```

## DMG для переноса на другой Mac

```bash
./make-dmg.sh
# готовый AutoSwitcher.dmg в текущей папке
```

На целевом маке после установки:
```bash
xattr -dr com.apple.quarantine /Applications/AutoSwitcher.app
open /Applications/AutoSwitcher.app
```

## Хоткеи

- **Option** (одиночное короткое нажатие) — главный хоткей
- **⌘⇧Space** — альтернатива
- **Esc** — отмена последнего автосвитча
- **⌃⇧U** — смена регистра выделенного
- **⌃⇧T** — транслит выделенного

## Конфиг

`~/Library/Application Support/AutoSwitcher/config.json` — автоперезагрузка каждые 2 сек.

## Пользовательские словари

`~/Library/Application Support/AutoSwitcher/dicts/ru.txt` и `en.txt`
подмерживаются к основным при старте.

## Лицензия

Использует:
- github.com/graninilya/keyswitcher (MIT) — n-граммы и алгоритм детектора
- github.com/danakt/russian-words — RU словоформы
- github.com/dwyl/english-words — EN словоформы
