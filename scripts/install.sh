#!/bin/bash
# Installs the daemon as a LaunchDaemon, the CLI into /usr/local/bin and the app into /Applications.
# Must be run with sudo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.local.fancurved"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$EUID" -ne 0 ]; then
    echo "sudo で実行してください:  sudo $0" >&2
    exit 1
fi

BIN="$ROOT/.build/release"
if [ ! -x "$BIN/fancurved" ]; then
    echo "リリースビルドがありません。先に scripts/build.sh を（sudo なしで）実行してください。" >&2
    exit 1
fi

echo "==> 既存のデーモンを停止"
launchctl bootout system "$PLIST" 2>/dev/null || true
sleep 1

echo "==> バイナリを配置"
install -d -m 755 /usr/local/libexec /usr/local/bin
install -m 755 -o root -g wheel "$BIN/fancurved"   /usr/local/libexec/fancurved
install -m 755 -o root -g wheel "$BIN/fancurvectl" /usr/local/bin/fancurvectl

echo "==> LaunchDaemon を配置"
install -m 644 -o root -g wheel "$ROOT/Resources/$LABEL.plist" "$PLIST"

echo "==> 設定ディレクトリを作成"
install -d -m 755 "/Library/Application Support/FanCurve"

echo "==> デーモンを起動"
launchctl bootstrap system "$PLIST"
sleep 2

if [ -d "$ROOT/build/FanCurve.app" ]; then
    # The app stays resident in the menu bar after its window is closed, so reopening it just
    # re-shows the old process. Without this, a fresh bundle sits on disk unused.
    if pgrep -f 'FanCurve.app/Contents/MacOS/FanCurveApp' >/dev/null; then
        echo "==> 実行中の FanCurve.app を終了します（新しいバイナリを反映させるため）"
        pkill -f 'FanCurve.app/Contents/MacOS/FanCurveApp'
        sleep 1
    fi
    echo "==> FanCurve.app を /Applications へ"
    rm -rf /Applications/FanCurve.app
    cp -R "$ROOT/build/FanCurve.app" /Applications/FanCurve.app
    chown -R root:wheel /Applications/FanCurve.app
fi

echo
if /usr/local/bin/fancurvectl status >/dev/null 2>&1; then
    echo "✅ インストール完了。デーモンは稼働中です。"
    echo
    /usr/local/bin/fancurvectl status
    echo
    echo "次の一歩:"
    echo "  1) ファン制御が効くか実測:  sudo fancurvectl probe"
    echo "  2) アプリを開く:            open /Applications/FanCurve.app"
    echo
    echo "  ※ アプリはメニューバーに常駐します。ウィンドウを閉じても終了しません。"
    echo "     更新を反映するには、メニューバーの「終了」か ⌘Q で完全に終了してください。"
else
    echo "⚠️ デーモンに接続できません。ログを確認してください: /var/log/fancurved.log"
    tail -20 /var/log/fancurved.log 2>/dev/null || true
    exit 1
fi
