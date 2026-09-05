#!/bin/bash
# One half of an A/B comparison: does holding Ftst change how the SoC throttles?
#
# The hypothesis, from a community reverse-engineering note, is that Ftst=1 stops the
# LifetimeServoController asserting die temperature targets to AppleCLPC — i.e. taking the fans
# might also relax the performance limiter. If so, the same render finishes *faster* under the
# app at the same fan speed, which is a far clearer signal than watts.
#
# Two confounds are handled here rather than left to chance:
#   * initial temperature — waits for the machine to cool before starting
#   * start time          — the script launches the render itself
#
#   sudo ./ab-test.sh A              macOS standard
#   sudo ./ab-test.sh B 4800         app in manual mode at a fixed RPM
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL=/usr/local/bin/fancurvectl
READ="$ROOT/.build/release/fancurvectl"
BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
OUT="${SUDO_USER:+/Users/$SUDO_USER}/Desktop"
[ -d "$OUT" ] || OUT="$HOME/Desktop"

LABEL=${1:-}
RPM=${2:-0}
FRAMES=${3:-13}
SAMPLES=${4:-2048}
WIDTH=${5:-1920}
DEVICE=${6:-GPU}
COOL_TO=${COOL_TO:-60}

[ "$EUID" -eq 0 ] || { echo "sudo で実行してください" >&2; exit 1; }
[ -n "$LABEL" ] || { echo "使い方: sudo $0 <A|B> [rpm] [frames] [samples]" >&2; exit 1; }
[ -x "$BLENDER" ] || { echo "Blender が見つかりません" >&2; exit 1; }

TSV="$OUT/ab-$LABEL.tsv"
FRAMELOG="$OUT/ab-$LABEL-frames.txt"
PWRLOG="$OUT/ab-$LABEL-power.txt"

cleanup() {
    kill "${WATCH:-0}" "${PMSET:-0}" 2>/dev/null
    "$CTL" manual 0 0 >/dev/null 2>&1
    "$CTL" manual 1 0 >/dev/null 2>&1
    "$CTL" mode system >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

temp() { "$READ" dump 2>/dev/null | awk '/^\[CPU\]/{print $3}'; }
fan()  { "$READ" keys F0Ac | awk -F'\t' '{printf "%.0f", $4}'; }

echo "==> 0. 機体が冷えるのを待ちます（${COOL_TO} °C 未満・ファン停止まで）"
"$CTL" mode system >/dev/null 2>&1
for _ in $(seq 1 240); do
    T=$(temp); F=$(fan)
    printf '\r    %s °C  fan %s rpm      ' "$T" "$F"
    if [ "${T%.*}" -lt "$COOL_TO" ] 2>/dev/null && [ "${F:-9999}" -lt 500 ] 2>/dev/null; then break; fi
    sleep 5
done
echo; echo "    開始温度 $(temp) °C"

echo "==> 1. モードを設定"
if [ "$LABEL" = "A" ]; then
    "$CTL" mode system >/dev/null
    echo "    macOS 標準（アプリは何も握りません）"
else
    # Read run A's own log rather than making the user copy a number across: the two fans
    # settle at different speeds, and matching each one is what keeps the comparison about
    # the limiter rather than about cooling.
    if [ "$RPM" -eq 0 ]; then
        [ -f "$OUT/ab-A.tsv" ] || { echo "先に A を実行してください（$OUT/ab-A.tsv がありません）" >&2; exit 1; }
        # Look the columns up by name: the TSV gained an `ftst` column partway through this
        # project, and hard-coded indices silently read the wrong ones.
        read -r RPM0 RPM1 < <(awk -F'\t' '
            NR==1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
            { n++; a[n] = $col["f0_rpm"]; b[n] = $col["f1_rpm"] }
            END {
                start = int(n * 0.35); if (start < 1) start = 1
                for (i = start; i <= n; i++) { if (a[i] > 500) { s0 += a[i]; c0++ }
                                               if (b[i] > 500) { s1 += b[i]; c1++ } }
                printf "%.0f %.0f", (c0 ? s0/c0 : 0), (c1 ? s1/c1 : 0)
            }' "$OUT/ab-A.tsv")
        echo "    A の定常平均から: fan0 ${RPM0} rpm / fan1 ${RPM1} rpm"
    else
        RPM0=$RPM; RPM1=$RPM
    fi
    [ "${RPM0:-0}" -gt 0 ] || { echo "A の平均回転数を読み取れませんでした" >&2; exit 1; }
    "$CTL" manual 0 "$RPM0" >/dev/null; "$CTL" manual 1 "$RPM1" >/dev/null
    "$CTL" mode manual >/dev/null
    sleep 8
    FT=$("$READ" keys Ftst | awk -F'\t' '{print $4}')
    if [ "${FT%.*}" != "1" ]; then
        echo "    ❌ アプリが制御を握れていません（Ftst=$FT）"
        echo "       FanCurve.app が起動しているか、電源に接続されているか確認してください"
        exit 2
    fi
    echo "    アプリが fan0 ${RPM0} / fan1 ${RPM1} rpm で保持中（Ftst=1、実測 fan0 $(fan) rpm）"
fi

echo "==> 2. 計測開始"
"$READ" watch 1800 "$TSV" > /dev/null 2>&1 &
WATCH=$!
powermetrics --samplers cpu_power,thermal -i 2000 > "$PWRLOG" 2>/dev/null &
PMSET=$!
sleep 2

echo "==> 3. レンダリング（${DEVICE} / ${WIDTH}px / ${FRAMES} フレーム × ${SAMPLES} samples）"
echo "    最初にウォームアップを 1 フレーム流します（計測対象外）"
"$BLENDER" -b --factory-startup -P "$ROOT/scripts/benchmark-scene.py" -- "$FRAMES" "$SAMPLES" "$WIDTH" "$DEVICE" 2>&1 \
    | grep --line-buffered -E 'BENCH_' | tee "$FRAMELOG"

echo
echo "==> 4. 計測終了"
kill "$WATCH" "$PMSET" 2>/dev/null
sleep 1
echo "    $TSV"
echo "    $FRAMELOG"
echo "    $PWRLOG"
echo
echo "    総時間: $(grep BENCH_TOTAL "$FRAMELOG" | awk '{print $2}') 秒"
echo
if [ "$LABEL" = "A" ]; then
    MEAN=$(awk -F'\t' 'NR>1 && $5>500 {s+=$5; n++} END {if(n) printf "%.0f", s/n}' "$TSV")
    echo "    A の fan0 平均回転数: ${MEAN:-不明} rpm"
    echo "    → 次はそのまま:  sudo $0 B"
    echo "       （回転数は A のログから自動で読み取ります）"
else
    echo "    → 比較:  python3 $ROOT/scripts/ab-compare.py $OUT/ab-A.tsv $OUT/ab-B.tsv"
fi
