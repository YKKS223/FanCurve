#!/bin/bash
# Verifies that the daemon hands the fans back when macOS shuts it down.
#
# At reboot/shutdown/logout, launchd sends SIGTERM and waits (ExitTimeOut=20) before SIGKILL.
# That is the one shutdown path we can actually catch, so it needs testing. The evidence is in
# /var/log/fancurved.log, which survives a reboot:
#
#   "シグナル 15 を受信"                       → the handler ran
#   "Ftst=0 を書いてシステム制御に戻しました"    → and released the fans
#   NO "起動時に Ftst=1 が残っていたため"        → nothing was left behind for start-up to clean
#
# That last line is the real judge: it only appears when the shutdown path failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL=/usr/local/bin/fancurvectl
LOG=/var/log/fancurved.log
MARKER="/Library/Application Support/FanCurve/shutdown-test.marker"   # /tmp is cleared on reboot

keys() { "$ROOT/.build/release/fancurvectl" keys Ftst F0Md F0Ac | awk -F'\t' '{printf "  %-5s %s\n",$1,$4}'; }

case "${1:-}" in

sigterm)
    # Same signal launchd sends at shutdown, without rebooting anything.
    [ "$EUID" -eq 0 ] || { echo "sudo で実行してください" >&2; exit 1; }
    echo "==> 手動モードで 4,000 rpm を保持させます"
    "$CTL" manual 0 4000 >/dev/null; "$CTL" manual 1 4000 >/dev/null; "$CTL" mode manual >/dev/null
    sleep 8
    keys
    FT=$("$ROOT/.build/release/fancurvectl" keys Ftst | awk -F'\t' '{print $4}')
    [ "${FT%.*}" = "1" ] || { echo "❌ Ftst を保持できていません。中止します。"; "$CTL" mode system >/dev/null; exit 2; }
    echo "  ✅ 保持中"
    echo
    echo "==> launchd と同じ SIGTERM を送り、Ftst が 0 になるまでを測ります"
    "$ROOT/.build/release/fancurvectl" waitzero Ftst 30 > /tmp/fc-term.out &
    W=$!
    sleep 0.3
    launchctl kill TERM system/com.local.fancurved
    wait "$W"
    R=$(cat /tmp/fc-term.out)
    if [[ "$R" == CLEARED* ]]; then
        echo "  ✅ $(echo "$R" | awk '{print $2}') 秒で Ftst=0 になりました（SIGTERM ハンドラが動作）"
    else
        echo "  ❌ 30 秒経っても解放されませんでした"
    fi
    echo
    echo "==> ログ"
    tail -4 "$LOG" | sed 's/^/    /'
    echo
    echo "==> 後片付け"
    sleep 2
    "$CTL" manual 0 0 >/dev/null 2>&1; "$CTL" manual 1 0 >/dev/null 2>&1
    "$CTL" mode curve >/dev/null 2>&1
    sleep 3   # let the control loop run once, or this snapshot catches a mid-transition state
    keys
    ;;

prepare)
    [ "$EUID" -eq 0 ] || { echo "sudo で実行してください" >&2; exit 1; }
    echo "==> 手動モードで 4,000 rpm を保持させます（再起動/システム終了の直前状態を作ります）"
    "$CTL" manual 0 4000 >/dev/null; "$CTL" manual 1 4000 >/dev/null; "$CTL" mode manual >/dev/null
    sleep 8
    keys
    FT=$("$ROOT/.build/release/fancurvectl" keys Ftst | awk -F'\t' '{print $4}')
    [ "${FT%.*}" = "1" ] || { echo "❌ Ftst を保持できていません。中止します。"; "$CTL" mode system >/dev/null; exit 2; }
    mkdir -p "$(dirname "$MARKER")"
    wc -l < "$LOG" > "$MARKER"
    date '+%Y-%m-%d %H:%M:%S' >> "$MARKER"
    echo "  ✅ 保持中。ログの現在行数を記録しました"
    echo
    echo "  この状態のまま、Apple メニューから「再起動」または「システム終了」してください。"
    echo "  起動したら:  sudo $0 check"
    ;;

check)
    if [ -f "$MARKER" ]; then
        FROM=$(head -1 "$MARKER")
        echo "==> シャットダウン前の状態: $(tail -1 "$MARKER")"
    else
        # The marker is only a convenience. The log alone is enough: the last "稼働中" line is
        # this boot's daemon, so everything before it belongs to the previous shutdown.
        FROM=$(grep -n '稼働中' "$LOG" | tail -1 | cut -d: -f1)
        FROM=$((FROM > 12 ? FROM - 12 : 1))
        echo "==> マーカーがないので、ログの最後の起動位置から判定します"
    fi
    echo
    echo "==> 前回終了時のログ（$FROM 行目以降）"
    tail -n +"$((FROM))" "$LOG" | head -20 | sed 's/^/    /'
    echo
    echo "  === 判定 ==="
    REST=$(tail -n +"$((FROM))" "$LOG")
    if grep -q 'シグナル 15 を受信' <<<"$REST"; then
        echo "  ✅ SIGTERM を受け取っていました"
    else
        echo "  ❌ SIGTERM のログがありません（猶予なく殺された可能性）"
    fi
    if grep -q 'Ftst=0 を書いてシステム制御に戻しました' <<<"$REST"; then
        echo "  ✅ 終了時に Ftst=0 を書いています"
    else
        echo "  ❌ 解放のログがありません"
    fi
    if grep -q '起動時に Ftst=.* が残っていたため' <<<"$REST"; then
        echo "  ❌ 起動時に後始末が必要でした → シャットダウン経路で解放できていません"
    else
        echo "  ✅ 起動時の後始末は不要でした → シャットダウン時に正しく解放されています"
    fi
    echo
    rm -f "$MARKER"
    echo "==> 現在の状態"; keys
    echo
    echo "  戻すには: fancurvectl manual 0 0 && fancurvectl manual 1 0 && fancurvectl mode curve"
    ;;

*)
    echo "使い方:"
    echo "  sudo $0 sigterm   再起動せずに SIGTERM 経路だけを試す（すぐ終わります）"
    echo "  sudo $0 prepare   再起動/システム終了の直前状態を作る"
    echo "  sudo $0 check     起動後に、前回の終了が正しかったか判定する"
    ;;
esac
