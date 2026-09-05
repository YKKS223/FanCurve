#!/bin/bash
# Measures how long launchd takes to restart a KeepAlive daemon after SIGKILL.
#
# This is the exposure window during which a crashed fan-control daemon would leave Ftst=1
# set. Deliberately uses a throwaway daemon that touches nothing: no SMC access, no fans,
# no heat. The number it produces applies to any KeepAlive LaunchDaemon on this machine.
set -uo pipefail

LABEL="local.fancurve.restartprobe"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
PROBE="/usr/local/libexec/fc-restartprobe.sh"
LOG="/tmp/fc-restartprobe.log"
RUNS=${1:-3}
# launchd will not respawn a job more often than ThrottleInterval (default 10 s), counted
# from the previous *start*. Left unset, a daemon that dies soon after starting can be down
# for over ten seconds — measured at 11.13 s here. Pass a value to see the difference.
THROTTLE=${2:-}

if [ "$EUID" -ne 0 ]; then echo "sudo で実行してください: sudo $0" >&2; exit 1; fi

cleanup() {
    echo
    echo "==> 後片付け"
    launchctl bootout system "$PLIST" 2>/dev/null
    rm -f "$PLIST" "$PROBE"
    echo "    ダミーデーモンを削除しました"
    ls -l "$PLIST" 2>/dev/null && echo "    ⚠️ plist が残っています" || echo "    ✅ plist なし"
}
trap cleanup EXIT INT TERM

if [ -n "$THROTTLE" ]; then
    echo "==> ThrottleInterval=$THROTTLE で測定します"
else
    echo "==> ThrottleInterval 未指定（launchd 既定の 10 秒）で測定します"
fi
echo "==> ダミーデーモンを設置（SMC には一切触れません）"
cat > "$PROBE" <<'PS'
#!/bin/bash
# Records the moment launchd started this process, then waits to be killed.
python3 -c 'import time; print("%.3f" % time.time())' >> /tmp/fc-restartprobe.log
while true; do sleep 3600; done
PS
chmod 755 "$PROBE"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$PROBE</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
$( [ -n "$THROTTLE" ] && printf '    <key>ThrottleInterval</key><integer>%s</integer>' "$THROTTLE" )
</dict>
</plist>
PL
chmod 644 "$PLIST"
: > "$LOG"

launchctl bootout system "$PLIST" 2>/dev/null
launchctl bootstrap system "$PLIST" || { echo "bootstrap 失敗"; exit 1; }
sleep 3

echo "==> ${RUNS} 回 kill -9 して、再起動までの実時間を測ります"
echo
for n in $(seq 1 "$RUNS"); do
    PID=$(pgrep -f "$PROBE" | head -1)
    if [ -z "$PID" ]; then echo "  [$n] プロセスが見つかりません"; continue; fi
    LASTSTART=$(tail -1 "$LOG")
    BEFORE=$(wc -l < "$LOG")
    KILLED=$(python3 -c 'import time; print("%.3f" % time.time())')
    AGE=$(python3 -c "print('%.1f' % ($KILLED - $LASTSTART))")
    kill -9 "$PID"
    for _ in $(seq 1 300); do
        [ "$(wc -l < "$LOG")" -gt "$BEFORE" ] && break
        sleep 0.05
    done
    STARTED=$(tail -1 "$LOG")
    if [ "$(wc -l < "$LOG")" -gt "$BEFORE" ]; then
        printf "  [%d] 起動から %ss で kill → 再起動まで %.2f 秒\n" "$n" "$AGE" \
            "$(python3 -c "print($STARTED - $KILLED)")"
    else
        echo "  [$n] ❌ 15 秒待っても再起動しませんでした"
    fi
    sleep 4
done

echo
echo "==> 参考: 起動直後に Ftst=0 を書く場合の追加コスト"
echo "    SMC のオープン + 1 バイト書き込みのみ（センサー走査より前に実行する設計）"
