#!/usr/bin/env python3
"""Reads macOS's own accumulated silicon-wear state. Read-only; changes nothing.

`thermalmonitord` runs a LifetimeServoController that models TDDB (time-dependent dielectric
breakdown) — gate-oxide wear, which accelerates exponentially with temperature. It integrates a
per-core acceleration factor over the life of the machine, persists it in NVRAM, and uses the
total to lower the die temperature targets it hands to AppleCLPC.

Taking a snapshot before and after a hot run answers the question this app cannot answer from
the outside: does that integrator keep advancing while we hold the fans, or does taking control
switch Apple's own wear tracking off?

    ./lts-snapshot.py             print the current state
    ./lts-snapshot.py save NAME   print it and save a copy
    ./lts-snapshot.py check NAME  snapshot now and compare against NAME (one step)
    ./lts-snapshot.py diff A B    compare two saved snapshots
"""
import json
import os
import struct
import subprocess
import sys

STORE = os.path.expanduser("~/Desktop/lts-snapshots")


def unescape(s):
    out = bytearray()
    i = 0
    while i < len(s):
        if s[i] == "%" and i + 2 < len(s):
            try:
                out.append(int(s[i + 1:i + 3], 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(ord(s[i]))
        i += 1
    return bytes(out)


def read_state():
    out = subprocess.run(["nvram", "-p"], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if l.startswith("lts-persistance")), None)
    if not line:
        return None
    blob = unescape(line.split("\t", 1)[1])
    if len(blob) < 16:
        return None
    version, counter, dies, loops = struct.unpack_from("<4I", blob, 0)
    integrators = []
    off = 16
    while off + 8 <= len(blob):
        value, = struct.unpack_from("<d", blob, off)
        integrators.append(value)
        off += 8
    return {"version": version, "counter": counter, "dies": dies,
            "loops": loops, "integrators": integrators}


def show(state, label=""):
    print(f"  version={state['version']}  counter={state['counter']}  "
          f"die={state['dies']}  loop={state['loops']}  {label}")
    for i, v in enumerate(state["integrators"]):
        if v:
            print(f"    積算器[{i}] = {v:,.0f}")


def main():
    state = read_state()
    if not state:
        print("lts-persistance を読めませんでした（この機種にはないかもしれません）")
        return 1

    args = sys.argv[1:]

    # One step, because the snapshot and the comparison always happen at the same moment:
    # after the workload. Two separate commands is one more chance to run them out of order.
    if args and args[0] == "check" and len(args) == 2:
        os.makedirs(STORE, exist_ok=True)
        json.dump(state, open(os.path.join(STORE, "now.json"), "w"))
        args = ["diff", args[1], "now"]

    if args and args[0] == "diff" and len(args) == 3:
        base = os.path.join(STORE, args[1] + ".json")
        if not os.path.exists(base):
            print(f"基準のスナップショットがありません: {base}")
            print("先に  ./lts-snapshot.py save " + args[1] + "  を実行してください")
            return 1
        a = json.load(open(base))
        b = json.load(open(os.path.join(STORE, args[2] + ".json")))
        print(f"=== {args[1]} → {args[2]} ===")
        print(f"  counter: {a['counter']} → {b['counter']}  （差 {b['counter'] - a['counter']:+d}）")
        moved = False
        for i, (x, y) in enumerate(zip(a["integrators"], b["integrators"])):
            if x or y:
                delta = y - x
                if abs(delta) > 0:
                    moved = True
                print(f"  積算器[{i}]: {x:,.0f} → {y:,.0f}  （差 {delta:+,.0f}）")
        print()
        if moved or b["counter"] != a["counter"]:
            print("  ✅ 値が進んでいます。この区間で macOS の寿命積算は動いていました。")
        else:
            # Zero is not a result on its own: the daemon tracks sleep entry and applies a
            # sleep adjustment on the way back, so the write may simply not have happened yet.
            print("  ⚠️ 値が変わっていません。次のどちらかです:")
            print("     (a) アプリ制御中は積算が止まっていた")
            print("     (b) まだ NVRAM に書き出されていないだけ")
            print()
            print("     切り分けの順番:")
            print("       1. 2〜3 分待ってもう一度このコマンドを実行（復帰時の補正待ち）")
            print("       2. それでもゼロなら、3〜5 分のスリープを挟んで再実行")
            print("       3. それでもゼロなら、macOS 標準で同じ負荷をかけて対照実験:")
            print("            sudo scripts/lts-test.sh system")
            print("          標準側でも進まなければ (b)、標準側だけ進むなら (a) が確定します")
        return 0

    print("=== macOS の寿命積算状態（TDDB / LifetimeServo）===")
    show(state)
    if args and args[0] == "save" and len(args) > 1:
        os.makedirs(STORE, exist_ok=True)
        path = os.path.join(STORE, args[1] + ".json")
        json.dump(state, open(path, "w"))
        print(f"\n  保存: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
