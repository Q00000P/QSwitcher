#!/bin/bash
# Сборка и прогоны по сигналу — для работы с ассистентом без ручных команд.
#
#   ./dev-watch.sh          запустить в Терминале и оставить (Ctrl+C — выход)
#
# Ждёт файл .qs-go в корне репозитория. Первая строка — ОДНА из фиксированных задач:
#   build              swift build (arm64, release) — проверка компиляции
#   app                ./make-app.sh — полная сборка QSwitcher.app
#   selftest           самопроверка ядра 5 против эталона на Python
#   test <файл>        прогон фраз (только nn/sem/*.txt или nn/lm/*.txt)
#   install            закрыть QSwitcher, поставить свежий QSwitcher.app в /Applications, запустить
#   stop               выйти
# Произвольные команды не выполняются. Вывод — в .qs-out.log (последняя строка «=== end …»).
cd "$(dirname "$0")" || exit 1
APP_BIN="QSwitcher.app/Contents/MacOS/QSwitcher"
echo "👀 dev-watch: жду задачи в $(pwd)/.qs-go  (Ctrl+C — выход)"
while true; do
    if [ -f .qs-go ]; then
        cmd=$(head -1 .qs-go | tr -d '\r')
        rm -f .qs-go
        echo "▶ $(date '+%H:%M:%S') $cmd"
        if [ "$cmd" = "stop" ]; then
            echo "=== end stop" > .qs-out.log
            echo "⏹ стоп"
            exit 0
        fi
        {
            echo "=== $(date '+%H:%M:%S') $cmd"
            rc=0
            case "$cmd" in
                build)
                    swift build -c release --arch arm64 2>&1; rc=$? ;;
                app)
                    ./make-app.sh 2>&1; rc=$? ;;
                selftest)
                    # Не дольше минуты: зависло — снимаем стек (sample) и убиваем
                    "$APP_BIN" --selftest-core 2>&1 &
                    pid=$!
                    for _ in $(seq 1 60); do kill -0 $pid 2>/dev/null || break; sleep 1; done
                    if kill -0 $pid 2>/dev/null; then
                        echo "⏱ висит больше минуты — стек процесса:"
                        sample $pid 3 2>&1 | grep -v "^$" | head -150
                        kill -9 $pid 2>/dev/null
                    fi
                    wait $pid; rc=$? ;;
                "test "*)
                    f="${cmd#test }"
                    case "$f" in
                        nn/sem/*.txt|nn/lm/*.txt)
                            if [ -f "$f" ]; then
                                "$APP_BIN" --test "$f" 2>&1 &
                                pid=$!
                                for _ in $(seq 1 600); do kill -0 $pid 2>/dev/null || break; sleep 1; done
                                if kill -0 $pid 2>/dev/null; then
                                    echo "⏱ висит больше 10 минут — стек процесса:"
                                    sample $pid 3 2>&1 | grep -v "^$" | head -150
                                    kill -9 $pid 2>/dev/null
                                fi
                                wait $pid; rc=$?
                            else echo "нет файла $f"; rc=2; fi ;;
                        *) echo "прогон только для nn/sem/*.txt и nn/lm/*.txt"; rc=2 ;;
                    esac ;;
                install)
                    if [ -x "$APP_BIN" ]; then
                        killall QSwitcher 2>/dev/null; sleep 1
                        rm -rf /Applications/QSwitcher.app && cp -R QSwitcher.app /Applications/ \
                            && open /Applications/QSwitcher.app && echo "установлено и запущено"
                        rc=$?
                    else
                        echo "сначала app"; rc=2
                    fi ;;
                *)
                    echo "неизвестная задача: $cmd"; rc=2 ;;
            esac
            echo "=== end $(date '+%H:%M:%S') rc=$rc"
        } > .qs-out.tmp 2>&1
        mv -f .qs-out.tmp .qs-out.log
        tail -1 .qs-out.log
    fi
    sleep 1
done
