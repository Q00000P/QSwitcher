#!/bin/bash
# Сетка порогов n-грамм: ngramMargin x ngramNoContextFactor.
# Оба читаются из config.json при старте, пересборка не нужна.
# В конце конфиг возвращается как был.
#   bash sweep.sh [файл-теста]
# Смотреть: строку, где «испортил» минимален при «верно» не ниже нынешнего.
set -u
CFG="$HOME/Library/Application Support/QSwitcher/config.json"
TEST="${1:-nn/sem/scan-phrases.txt}"
APP="./QSwitcher.app/Contents/MacOS/QSwitcher"
[ -f "$CFG" ] || { echo "нет $CFG"; exit 1; }
[ -f "$TEST" ] || { echo "нет $TEST"; exit 1; }
cp "$CFG" /tmp/config-backup.json
trap 'cp /tmp/config-backup.json "$CFG"; echo "конфиг возвращён"' EXIT

cat > /tmp/qs_set.py << 'PY'
import json, os, sys
p = os.path.expanduser('~/Library/Application Support/QSwitcher/config.json')
d = json.load(open(p))
d['ngramMargin'] = float(sys.argv[1])
d['ngramNoContextFactor'] = float(sys.argv[2])
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PY

cat > /tmp/qs_score.py << 'PY'
import sys, re
ok = silent = harm = 0
cur = None
for l in sys.stdin:
    if l.startswith('--- '):
        cur = l[4:].strip()
    elif l.startswith('    = ') and cur:
        m = re.match(r'\s*= (\S+)\s+(\u2705|\u274c)', l)
        if not m:
            continue
        w = [t for t in cur.split() if t.startswith('*')]
        typed = (w[0].strip('*') if w else cur.split()[-1])
        if m.group(2) == '\u2705':
            ok += 1
        elif m.group(1).lower() == typed.lower():
            silent += 1
        else:
            harm += 1
print(f"{ok} {silent} {harm}")
PY

printf "%-8s %-8s %8s %8s %9s\n" margin factor верно молчал испортил
for M in 0.4 0.6 0.9 1.3; do
  for F in 1 2 3 4 6; do
    python3 /tmp/qs_set.py "$M" "$F"
    R=$("$APP" --test "$TEST" 2>&1 | python3 /tmp/qs_score.py)
    printf "%-8s %-8s %8s %8s %9s\n" "$M" "$F" $R
  done
done
