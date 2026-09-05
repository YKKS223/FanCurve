#!/bin/bash
# Records SMC fan state across a sleep/wake cycle. Reads only — writes nothing, needs no root.
#
# Run it in manual mode at a fixed speed, not under a real workload: otherwise a workload that
# pauses over the sleep would lower the temperature, the boost would subside on its own, and
# there would be no way to tell that apart from sleep having broken the control.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$ROOT/.build/release/fancurvectl"
LOG=${1:-$HOME/Desktop/fancurve-sleeptest.tsv}

summarise() {
    echo
    echo "=== 記録終了 ==="
    python3 "$ROOT/scripts/sleeptest-summary.py" "$LOG"
    echo
    echo "  TSV: $LOG"
    echo "  戻すには: fancurvectl manual 0 0 && fancurvectl manual 1 0 && fancurvectl mode curve"
    exit 0
}
trap summarise INT TERM

echo "スリープ前後の SMC 状態を記録します（読み取りのみ・root 不要）"
echo "出力: $LOG"
echo
echo "  1) 先に手動モードで固定回転にしてください（温度を変数から外すため）:"
echo "       fancurvectl manual 0 4000 && fancurvectl manual 1 4000 && fancurvectl mode manual"
echo "  2) ファンが 4,000 rpm で回っているのを確認したら、このまま Mac をスリープ（2 分ほど）"
echo "  3) 復帰させ、1 分ほど放置してから Ctrl-C"
echo

printf 'time\tftst\tf0_md\tf0_tg\tf0_ac\tf1_ac\tcpu\n' > "$LOG"

while true; do
    read -r FT MD TG AC AC1 < <("$CTL" keys Ftst F0Md F0Tg F0Ac F1Ac | awk -F'\t' '{printf "%s ", $4}')
    CPU=$("$CTL" dump 2>/dev/null | awk '/^\[CPU\]/{print $3}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date '+%H:%M:%S')" "$FT" "$MD" "$TG" "$AC" "$AC1" "${CPU:-}" >> "$LOG"
    printf '\r  %s  Ftst=%-5s Md=%-5s Tg=%-8s fan0=%-9s fan1=%-9s %s °C   ' \
        "$(date '+%H:%M:%S')" "$FT" "$MD" "$TG" "$AC" "$AC1" "${CPU:-?}"
    sleep 2
done
