#!/usr/bin/env python3
"""Decodes the integrator states thermalmonitord logs, and compares them with NVRAM.

The daemon prints lines like

    die 0 loop 2 is: {length = 8, bytes = 0xb045f7c6df866f41}

where `is` is the integrator state — the accumulated wear for that control loop, as a
little-endian double. NVRAM holds the last persisted copy, which lags. If the live values are
ahead of the persisted ones, the servo has been running since that write.
"""
import glob
import json
import os
import re
import struct
import subprocess
import sys

PATTERN = re.compile(r"die (\d+) loop (\d+) is: \{length = 8, bytes = 0x([0-9a-f]{16})\}")


def nvram_integrators():
    out = subprocess.run(["nvram", "-p"], capture_output=True, text=True).stdout
    line = next((l for l in out.splitlines() if l.startswith("lts-persistance")), None)
    if not line:
        return []
    raw = line.split("\t", 1)[1]
    blob = bytearray()
    i = 0
    while i < len(raw):
        if raw[i] == "%" and i + 2 < len(raw):
            try:
                blob.append(int(raw[i + 1:i + 3], 16)); i += 3; continue
            except ValueError:
                pass
        blob.append(ord(raw[i])); i += 1
    return [struct.unpack_from("<d", bytes(blob), o)[0]
            for o in range(16, len(blob) - 7, 8)]


def main(path):
    latest = {}
    for line in open(path, errors="ignore"):
        m = PATTERN.search(line)
        if m:
            die, loop, hexval = int(m.group(1)), int(m.group(2)), m.group(3)
            latest[(die, loop)] = struct.unpack("<d", bytes.fromhex(hexval))[0]

    if not latest:
        print("積算器の行が見つかりませんでした")
        return 1

    nv = nvram_integrators()
    print("=== 積算器: NVRAM の保存値 vs ログのライブ値 ===")
    print("        NVRAM(保存)      ライブ            差")
    advanced = 0
    for (die, loop), live in sorted(latest.items()):
        saved = nv[loop] if loop < len(nv) else float("nan")
        delta = live - saved
        if delta > 0:
            advanced += 1
        print(f"  loop{loop}  {saved:14,.0f}  {live:14,.0f}   {delta:+10,.0f}")
    print()
    if advanced == len(latest):
        print("✅ すべてのループで保存値より進んでいます。")
        print("   寿命サーボは動作中で、NVRAM への書き出しが遅れているだけです。")
        print("   → このアプリがファンを握っていても、macOS の摩耗積算は止まりません。")
    elif advanced:
        print(f"△ {advanced}/{len(latest)} のループだけ進んでいます。")
    else:
        print("⚠️ 進んでいません。NVRAM の直後に取得したか、積算が止まっています。")
    return 0


if __name__ == "__main__":
    logs = sys.argv[1:] or sorted(glob.glob(os.path.expanduser("~/Desktop/lts-watch-*.log")))[-1:]
    if not logs:
        print("使い方: lts-decode-log.py <lts-watch-*.log>")
        sys.exit(1)
    sys.exit(main(logs[0]))
