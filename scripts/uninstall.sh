#!/bin/bash
# Removes everything and, importantly, hands the fans back to the Mac's own controller first.
set -euo pipefail

LABEL="com.local.fancurved"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$EUID" -ne 0 ]; then
    echo "sudo で実行してください:  sudo $0" >&2
    exit 1
fi

echo "==> ファンをシステム制御へ戻す"
/usr/local/bin/fancurvectl reset 2>/dev/null || true

echo "==> デーモンを停止"
launchctl bootout system "$PLIST" 2>/dev/null || true
sleep 1

# Belt and braces: talk to the SMC directly in case the daemon had already died
# while still holding the fans in forced mode.
/usr/local/bin/fancurvectl panic 2>/dev/null || true

echo "==> ファイルを削除"
rm -f "$PLIST"
rm -f /usr/local/libexec/fancurved
rm -f /usr/local/bin/fancurvectl
rm -rf /Applications/FanCurve.app
rm -f /var/run/fancurved.sock
rm -f /var/log/fancurved.log

echo
echo "アンインストールしました。"
echo "設定は残してあります: /Library/Application Support/FanCurve"
echo "設定も消す場合:  sudo rm -rf '/Library/Application Support/FanCurve'"
