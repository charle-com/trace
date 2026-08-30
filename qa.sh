#!/usr/bin/env bash
# QA automatisée : lance l'app en mode --qa, capture la fenêtre depuis le shell, affiche le résultat.
# usage : ./qa.sh <dossier-sortie> [options passées à l'app : --scenario route|open|empty --open f.gpx --layer id --overlay a,b --profile raw --wait s]
set -uo pipefail
cd "$(dirname "$0")"
OUT="$1"; shift
APP="./build/Tracé.app/Contents/MacOS/Trace"
rm -rf "$OUT"; mkdir -p "$OUT"
caffeinate -u -t 60 &
"$APP" -ApplePersistenceIgnoreState YES -autosave "${QA_AUTOSAVE:-NO}" -autosaveFolder "$OUT/autosave" --qa "$OUT" --hold 7 "$@" 2> "$OUT/stderr.log" &
PID=$!
for i in $(seq 1 90); do
  sleep 1
  if [[ -f "$OUT/window.txt" ]]; then
    sleep 1.5
    screencapture -x -l "$(cat "$OUT/window.txt")" "$OUT/window.png" 2>&1
    break
  fi
  kill -0 $PID 2>/dev/null || break
done
for i in $(seq 1 30); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill -0 $PID 2>/dev/null && { echo "TIMEOUT : kill"; kill $PID; }
echo "--- QA log ---"; grep "\[QA\]" "$OUT/stderr.log"
echo "--- result ---"; [[ -f "$OUT/result.json" ]] && python3 -c "import json,sys; d=json.load(open('$OUT/result.json')); d.pop('log',None); print(json.dumps(d, ensure_ascii=False))"
ls -la "$OUT" | grep -E "png|gpx"
