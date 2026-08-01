# QSwitcher — полный исходник проекта

Утилита автоматического переключения раскладки RU↔EN для macOS. Собирается универсальным бинарём (Intel + ARM).

## Первый запуск (с нуля)

```bash
cd ~/Downloads
tar -xzf QSwitcher-source.tar.gz
cd QSwitcher
chmod +x *.sh

# 1. Скачать словари (один раз, ~50 МБ из GitHub)
./fetch-dicts.sh

# 2. Собрать .app
./make-app.sh

# 3. Скопировать в /Applications
cp -R QSwitcher.app /Applications/

# 4. Удалить сборочную копию (чтобы не висело в Spotlight)
rm -rf QSwitcher.app

# 5. Запустить и дать Accessibility
open /Applications/QSwitcher.app
```

## Пересборка после правок кода

```bash
cd ~/Downloads/QSwitcher
killall QSwitcher 2>/dev/null
rm -rf .build /Applications/QSwitcher.app QSwitcher.app
./make-app.sh
cp -R QSwitcher.app /Applications/
rm -rf QSwitcher.app
killall QSwitcher 2>/dev/null
open /Applications/QSwitcher.app
```

## DMG для переноса на другой Mac

```bash
./make-dmg.sh
# готовый QSwitcher.dmg в текущей папке
```

На целевом маке после установки:
```bash
xattr -dr com.apple.quarantine /Applications/QSwitcher.app
open /Applications/QSwitcher.app
```

## Хоткеи

- **Option** (одиночное короткое нажатие) — главный хоткей
- **⌘⇧Space** — альтернатива
- **Esc** — отмена последнего автосвитча
- **⌃⇧U** — смена регистра выделенного
- **⌃⇧T** — транслит выделенного

## Конфиг

`~/Library/Application Support/QSwitcher/config.json` — автоперезагрузка каждые 2 сек.

## Пользовательские словари

`~/Library/Application Support/QSwitcher/dicts/ru.txt` и `en.txt`
подмерживаются к основным при старте.

## Лицензия

Использует:
- github.com/graninilya/keyswitcher (MIT) — n-граммы и алгоритм детектора
- github.com/danakt/russian-words — RU словоформы
- github.com/dwyl/english-words — EN словоформы
