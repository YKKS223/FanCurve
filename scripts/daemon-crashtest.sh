#!/bin/bash
# Measures the real exposure window: how long the installed daemon leaves Ftst set after
# being SIGKILLed, with ThrottleInterval=1 in place.
#
# The daemon is parked at a HIGH manual speed first, so if anything goes wrong the machine is
# left cooling too hard rather than not at all.
set -uo pipefail

CTL=/usr/local/bin/fancurvectl
LABEL=com.local.fancurved
RPM=${1:-5000}

if [ "$EUID" -ne 0 ]; then echo "sudo で実行してください: sudo $0" >&2; exit 1; fi
[ -x "$CTL" ] || { echo "先に install.sh を実行してください" >&2; exit 1; }

restore() {
    echo
    echo "==> 後片付け: 手動回転数を 0 に戻し、モードをシステム標準にします"
    "$CTL" manual 0 0 >/dev/null 2>&1
    "$CTL" manual 1 0 >/dev/null 2>&1
    "$CTL" mode system >/dev/null 2>&1
    sleep 2
    "$CTL" keys Ftst F0Md F0Ac | awk -F'\t' '{printf "    %-5s %s\n", $1, $4}'
}
trap restore EXIT INT TERM

echo "==> 0. 開始状態"
"$CTL" keys Ftst F0Md F0Ac | awk -F'\t' '{printf "    %-5s %s\n", $1, $4}'
echo

echo "==> 1. デーモンに ${RPM} rpm を保持させます（高回転なので固着しても安全側）"
"$CTL" manual 0 "$RPM" >/dev/null
"$CTL" manual 1 "$RPM" >/dev/null
"$CTL" mode manual >/dev/null
for _ in $(seq 1 20); do
    FT=$("$CTL" keys Ftst | awk -F'\t' '{print $4}')
    [ "${FT%.*}" = "1" ] && break
    sleep 1
done
sleep 6
"$CTL" status | sed -n '1,3p'
"$CTL" keys Ftst F0Md F0Ac F1Ac | awk -F'\t' '{printf "    %-5s %s\n", $1, $4}'

FT=$("$CTL" keys Ftst | awk -F'\t' '{print $4}')
AC=$("$CTL" keys F0Ac | awk -F'\t' '{print $4}')
if [ "${FT%.*}" != "1" ]; then
    echo; echo "❌ Ftst を保持できていません（$FT）。試験になりません。中止します。"; exit 2
fi
if [ "${AC%.*}" -lt 2000 ] 2>/dev/null; then
    echo; echo "❌ ファンが回っていません（$AC rpm）。中止します。"; exit 2
fi
echo "    ✅ Ftst 保持中・fan0 $AC rpm"
echo

PID=$(pgrep -x fancurved | head -1)
echo "==> 2. Ftst が 0 に戻る瞬間を 5 ms 間隔で監視しつつ、デーモンを kill -9"
"$CTL" waitzero Ftst 30 > /tmp/fc-waitzero.out 2>&1 &
WATCH=$!
sleep 0.3
kill -9 "$PID"
echo "    killed pid=$PID"
wait "$WATCH"
RESULT=$(cat /tmp/fc-waitzero.out)
echo

echo "==> 3. 結果"
if [[ "$RESULT" == CLEARED* ]]; then
    SECS=$(echo "$RESULT" | awk '{print $2}')
    echo "    ✅ Ftst が 0 に戻るまで ${SECS} 秒"
else
    echo "    ❌ 30 秒経っても Ftst が 0 になりませんでした"
fi
NEWPID=$(pgrep -x fancurved | head -1)
echo "    デーモン: 旧 pid=$PID → 新 pid=${NEWPID:-なし}"
echo
echo "    再起動後のログ:"
tail -5 /var/log/fancurved.log | sed 's/^/      /'
