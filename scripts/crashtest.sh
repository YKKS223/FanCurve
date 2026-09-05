#!/bin/bash
# Answers: if a fan-control process is SIGKILLed while Ftst=1 and the fan is in manual mode,
# does macOS take the fans back on its own?
#
# The fan is deliberately parked at a HIGH speed first, so a sticky state is loud, not hot.
set -uo pipefail
CTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/release/fancurvectl"
FAN=${1:-0}
RPM=${2:-5000}
WATCH=${3:-90}

if [ "$EUID" -ne 0 ]; then echo "sudo で実行してください: sudo $0" >&2; exit 1; fi

show() { "$CTL" keys Ftst "F${FAN}Md" "F${FAN}Tg" "F${FAN}Ac" | awk -F'\t' '{printf "  %-5s %s\n", $1, $4}'; }

echo "=== 0. 開始状態 ==="; show; echo

echo "=== 1. 手動制御に入って居座るプロセスを起動 ==="
"$CTL" hang "$FAN" "$RPM" > /tmp/fc-hang.log 2>&1 &
HANG=$!
for _ in $(seq 1 30); do grep -q READY /tmp/fc-hang.log && break; sleep 0.5; done
cat /tmp/fc-hang.log
sleep 10
echo "  --- 10 秒後 ---"; show

# Without this check a failed unlock would leave the machine already in Ftst=0 / mode 3,
# and the watch loop below would report "recovered" at t=0 without anything being tested.
read -r PRE_FTST PRE_MD PRE_AC < <("$CTL" keys Ftst "F${FAN}Md" "F${FAN}Ac" | awk -F'\t' '{printf "%s ", $4}')
if [ "${PRE_FTST%.*}" = "0" ] && [ "${PRE_MD%.*}" = "3" ]; then
    echo
    echo "❌ 手動制御に入れていません（Ftst=$PRE_FTST, Md=$PRE_MD）。試験になりません。中止します。"
    kill -9 "$HANG" 2>/dev/null; wait "$HANG" 2>/dev/null
    "$CTL" panic
    exit 2
fi
if [ "${PRE_AC%.*}" -lt 800 ] 2>/dev/null; then
    echo
    echo "❌ ファンが回っていません（$PRE_AC rpm）。固着しても安全と言えないので中止します。"
    kill -9 "$HANG" 2>/dev/null; wait "$HANG" 2>/dev/null
    "$CTL" panic
    exit 2
fi
echo "  ✅ 手動制御中・ファン $PRE_AC rpm で回転中。この状態で kill します。"
echo

echo "=== 2. SIGKILL（後片付けを一切させない） ==="
kill -9 "$HANG" 2>/dev/null
wait "$HANG" 2>/dev/null
echo "  killed pid=$HANG"
echo

echo "=== 3. macOS が自力で回収するかを ${WATCH} 秒観測 ==="
printf "  %5s  %-6s %-6s %-8s %s\n" "秒" "Ftst" "Md" "Tg" "Ac(rpm)"
RECOVERED=""
for t in $(seq 0 3 "$WATCH"); do
    read -r FTST MD TG AC < <("$CTL" keys Ftst "F${FAN}Md" "F${FAN}Tg" "F${FAN}Ac" | awk -F'\t' '{printf "%s ", $4}')
    printf "  %5s  %-6s %-6s %-8s %s\n" "$t" "$FTST" "$MD" "$TG" "$AC"
    if [ -z "$RECOVERED" ] && [ "${FTST%.*}" = "0" ] && [ "${MD%.*}" = "3" ]; then
        RECOVERED="$t"
    fi
    sleep 3
done

echo
if [ -n "$RECOVERED" ]; then
    echo "✅ ${RECOVERED} 秒で macOS が自力で回収しました（Ftst=0, Md=3）。"
    echo "   クラッシュしても OS 側に戻る = 安全策は存在します。"
else
    echo "❌ ${WATCH} 秒経っても回収されませんでした。"
    echo "   クラッシュ時に自動復帰しない = アプリ側の後片付けが唯一の安全策ということです。"
    echo "   いま手動で戻します（Ftst=0）…"
    "$CTL" panic
    echo "   最終状態:"; show
fi
