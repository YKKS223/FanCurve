#!/bin/bash
# Watches Apple's lifetime servo directly, instead of waiting for it to reach NVRAM.
#
# thermalmonitord has a `com.apple.lifetimeservo` log subsystem whose control loop prints:
#   LSControlLoop N: tempMax T, tempAverage T, AFi F, LS-ris S (up U, down D), target X
# tempMax/tempAverage are what it sees, AFi is the wear acceleration factor it derives, and
# `target` is the die temperature limit it hands to AppleCLPC. If those lines keep appearing
# while this app holds the fans, Apple's wear tracking did not stop.
#
# Debug logging is enabled for that one subsystem and reset again on the way out, including
# on Ctrl-C.
set -uo pipefail
SECONDS_TO_WATCH=${1:-180}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBSYS=com.apple.lifetimeservo
OUT="${SUDO_USER:+/Users/$SUDO_USER}/Desktop"; [ -d "$OUT" ] || OUT="$HOME/Desktop"
LOG="$OUT/lts-watch-$(date +%H%M%S).log"

[ "$EUID" -eq 0 ] || { echo "sudo で実行してください" >&2; exit 1; }

restore() {
    echo
    echo "==> ログ設定を元に戻します"
    log config --subsystem "$SUBSYS" --reset 2>/dev/null
    log config --subsystem com.apple.cltm --reset 2>/dev/null
    echo "    完了"
}
trap restore EXIT INT TERM

echo "==> $SUBSYS のデバッグログを一時的に有効化"
log config --subsystem "$SUBSYS" --mode "level:debug" 2>/dev/null \
    || echo "    （このサブシステムは登録されていないかもしれません。続行します）"
log config --subsystem com.apple.cltm --mode "level:debug" 2>/dev/null

echo "==> ${SECONDS_TO_WATCH} 秒間、寿命サーボの動きを記録します"
echo "    この間に負荷をかけてください（Blender でもローカル LLM でも可）"
echo "    出力: $LOG"
echo

log stream --predicate "subsystem == \"$SUBSYS\" OR senderImagePath CONTAINS \"thermalmonitord\"" \
    --level debug --style compact > "$LOG" 2>&1 &
STREAM=$!
for i in $(seq "$SECONDS_TO_WATCH" -10 1); do
    printf '\r    残り %3d 秒   取得済み %5d 行   ' "$i" "$(wc -l < "$LOG" | tr -d ' ')"
    sleep 10
done
kill "$STREAM" 2>/dev/null
sleep 1
echo; echo

echo "==> 結果"
TOTAL=$(wc -l < "$LOG" | tr -d ' ')
LSLINES=$(grep -c 'LSControlLoop' "$LOG" 2>/dev/null) || LSLINES=0
ISLINES=$(grep -c 'loop .* is:' "$LOG" 2>/dev/null) || ISLINES=0
echo "    全ログ行数        : $TOTAL"
echo "    LSControlLoop 行数: $LSLINES"
echo "    積算器の出力行数  : $ISLINES"
echo

if [ "$ISLINES" -gt 0 ] || [ "$LSLINES" -gt 0 ]; then
    echo "    ✅ 寿命サーボは動いています"
    [ "$LSLINES" -gt 0 ] && grep 'LSControlLoop' "$LOG" | tail -4 | sed 's/^/      /'
    echo
    python3 "$ROOT/scripts/lts-decode-log.py" "$LOG" | sed 's/^/    /'
else
    echo "    観測できませんでした。ログレベルが上がらなかった可能性があります。"
fi
