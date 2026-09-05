#!/bin/bash
# Does macOS keep tracking silicon wear while this app holds the fans?
#
# thermalmonitord integrates a TDDB acceleration factor over time and persists it to NVRAM.
# If that integrator advances across a hot run under app control, Apple's wear tracking is
# still running and taking the fans did not switch it off. Run it once under app control and
# once under macOS standard: a delta in one and not the other is the answer.
#
#   sudo ./lts-test.sh app       hot run with this app controlling
#   sudo ./lts-test.sh system    hot run with macOS controlling (the control case)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL=/usr/local/bin/fancurvectl
READ="$ROOT/.build/release/fancurvectl"
SNAP="python3 $ROOT/scripts/lts-snapshot.py"
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
MODE=${1:-}
FRAMES=${2:-20}
OUT="${SUDO_USER:+/Users/$SUDO_USER}/Desktop"; [ -d "$OUT" ] || OUT="$HOME/Desktop"
TSV="$OUT/lts-$MODE.tsv"

case "$MODE" in app|system) ;; *) echo "使い方: sudo $0 <app|system> [frames]" >&2; exit 1 ;; esac
[ "$EUID" -eq 0 ] || { echo "sudo で実行してください" >&2; exit 1; }

cleanup() { kill "${WATCH:-0}" 2>/dev/null; }
trap cleanup EXIT INT TERM

echo "=== 1. 基準となる寿命積算値を保存 ==="
$SNAP save "lts-$MODE-before" | sed 's/^/  /'
echo

echo "=== 2. 制御を $MODE に設定 ==="
if [ "$MODE" = "app" ]; then
    "$CTL" mode curve >/dev/null
    sleep 5
else
    "$CTL" mode system >/dev/null
    sleep 3
fi
"$CTL" status | sed -n '1,3p' | sed 's/^/  /'
echo

echo "=== 3. 高負荷（${FRAMES} フレーム、約 $((FRAMES * 55 / 60)) 分）==="
echo "    この間は放置してください。ファンが回ります。"
"$READ" watch 3600 "$TSV" >/dev/null 2>&1 &
WATCH=$!
sleep 2
"$BLENDER" -b --factory-startup -P "$ROOT/scripts/benchmark-scene.py" -- "$FRAMES" 2048 1920 GPU 2>&1 \
    | grep --line-buffered -E 'BENCH_FRAME|BENCH_TOTAL' | sed 's/^/    /'
kill "$WATCH" 2>/dev/null; sleep 1
echo

echo "=== 4. どれだけ高温に晒されたか ==="
python3 - "$TSV" <<'PY' | sed 's/^/  /'
import csv, sys
rows=[r for r in csv.DictReader(open(sys.argv[1]), delimiter='\t')]
t=[float(r['sysmax']) for r in rows if r.get('sysmax')]
ft=set(r.get('ftst') for r in rows)
print("記録 %d 秒  Ftst=%s" % (len(t), ",".join(sorted(x for x in ft if x))))
for lo in (100,105,110):
    print("  %d °C 以上: %d 秒" % (lo, sum(1 for x in t if x>=lo)))
print("  最高温度  : %.1f °C" % max(t))
PY
echo

echo "=== 5. NVRAM への書き出しを促すため 60 秒スリープします ==="
echo "    復帰させたら、続けて次を実行してください:"
echo
echo "      python3 $ROOT/scripts/lts-snapshot.py check lts-$MODE-before"
echo
read -r -p "    いまスリープしますか？ [y/N] " ans
if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
    "$CTL" mode system >/dev/null 2>&1
    sleep 2
    pmset sleepnow
    echo "    （復帰したら上のコマンドを実行してください）"
else
    "$CTL" mode curve >/dev/null 2>&1
    echo "    スリープを挟まない場合、書き出しは定期タスク待ちになります。"
fi
