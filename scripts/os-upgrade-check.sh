#!/bin/bash
# Read-only snapshot of everything FanCurve's safety assumptions rest on, for use before and
# after a macOS update. Writes nothing to the SMC and needs no root.
#
#   scripts/os-upgrade-check.sh snapshot <file>          record the current state
#   scripts/os-upgrade-check.sh compare  <baseline-file> record now and diff the parts that matter
#
# A major update replaces thermalmonitord and usually the SMC firmware with it. Every rule in
# FINDINGS.md (Ftst unlock, Md=3 meaning "parked", Ftst surviving sleep, no hardware deadman)
# was measured on one OS build, so a changed line here means "re-measure before trusting it".
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$ROOT/.build/release/fancurvectl"

snapshot() {
    echo "# FanCurve ベースライン  $(date '+%Y-%m-%d %H:%M:%S')"
    echo; echo "## OS / 機種"; sw_vers; sysctl -n hw.model machdep.cpu.brand_string
    echo; echo "## thermalmonitord（macOS の熱管理本体）"
    shasum -a 256 /usr/libexec/thermalmonitord; ls -l /usr/libexec/thermalmonitord
    echo; echo "## SMC キー（読み取りのみ）"
    "$CTL" keys FNum Ftst F0Md F1Md F0Tg F1Tg F0Ac F1Ac F0Mn F1Mn F0Mx F1Mx F0md F1md 2>&1
    echo; echo "## センサーとファン（直接読み出し）"; "$CTL" dump 2>&1
    echo; echo "## デーモン"; /usr/local/bin/fancurvectl status 2>&1 | head -4
    echo; echo "## 寿命積算器 NVRAM"; python3 "$ROOT/scripts/lts-snapshot.py" 2>&1 | head -25
}

# Only the lines whose change would invalidate a measured assumption. Temperatures and rpm
# move on their own and would bury the signal.
essentials() {
    grep -E '^(ProductVersion|BuildVersion)|/usr/libexec/thermalmonitord$|^(FNum|Ftst|F[01](Md|md|Mn|Mx))[[:space:]]|^温度センサー|  fan[0-9] ' "$1" \
        | sed -E 's/^(  fan[0-9]).*範囲 ([0-9]+–[0-9]+)  (Md=[0-9]+)$/\1  範囲 \2  \3/'
}

case "${1:-}" in
    snapshot)
        [ -n "${2:-}" ] || { echo "使い方: $0 snapshot <file>" >&2; exit 1; }
        snapshot > "$2" 2>&1; echo "記録しました: $2" ;;
    compare)
        [ -f "${2:-}" ] || { echo "使い方: $0 compare <baseline-file>" >&2; exit 1; }
        NOW="$(dirname "$2")/fancurve-baseline-$(sw_vers -productVersion).txt"
        snapshot > "$NOW" 2>&1
        echo "今回の記録: $NOW"; echo
        echo "=== 安全上の前提に関わる差分（- 更新前 / + 現在）==="
        if diff <(essentials "$2") <(essentials "$NOW"); then
            echo "（差分なし）"
        fi
        echo
        echo "OS バージョンと thermalmonitord のハッシュが変わるのは当然です。"
        echo "それ以外（Ftst / Md / Mn / Mx / md / センサー数）が変わっていたら、再インストール前に相談してください。" ;;
    *)
        sed -n '2,8p' "$0"; exit 1 ;;
esac
