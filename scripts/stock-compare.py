#!/usr/bin/env python3
"""Compares macOS's own fan behaviour between two `ab-test.sh A` runs (e.g. before/after an
OS update). Same Blender scene, same cool-down start, the app holding nothing.

    python3 stock-compare.py <old.tsv> <new.tsv>

The frames file is found next to each TSV (`...-frames.txt`).

Definitions, fixed so two runs are measured the same way:
  * times are seconds from load start (first sample above 20 W), not from when logging began
  * "spinning" means above 0 rpm; macOS's first step is ~450 rpm, well under the rated minimum
  * time above a temperature is summed from the timestamps, not counted in rows — under load
    the 1 Hz logger sometimes slips to 2 s, so row counts come out ~10 % short
"""
import csv
import os
import sys

FAN_MIN = (2317, 2502)
FAN_MAX = (6898, 7450)


def load(path):
    rows = []
    for r in csv.DictReader(open(path), delimiter="\t"):
        try:
            rows.append({k: float(r[k]) for k in
                         ("elapsed", "sysmax", "cpu", "gpu", "watts", "f0_rpm", "f1_rpm")})
        except (ValueError, KeyError):
            continue
    return rows


def frames(tsv):
    path = tsv[:-4] + "-frames.txt"
    times, total = [], None
    if os.path.exists(path):
        for line in open(path):
            p = line.split()
            if len(p) >= 3 and p[0] == "BENCH_FRAME":
                times.append(float(p[2]))
            elif len(p) >= 2 and p[0] == "BENCH_TOTAL":
                total = float(p[1])
    return times, total


def seconds_at_or_above(rows, c):
    s = 0.0
    for a, b in zip(rows, rows[1:]):
        if a["sysmax"] >= c:
            s += b["elapsed"] - a["elapsed"]
    return s


def first(rows, pred):
    return next((r for r in rows if pred(r)), None)


def summarise(path):
    rows = load(path)
    ft, total = frames(path)
    start = first(rows, lambda r: r["watts"] > 20) or rows[0]
    t0 = start["elapsed"]
    rows = [dict(r, elapsed=r["elapsed"] - t0) for r in rows if r["elapsed"] >= t0]
    spin = first(rows, lambda r: r["f0_rpm"] > 0 or r["f1_rpm"] > 0)
    ramp = first(rows, lambda r: r["f0_rpm"] > FAN_MIN[0] + 300 or r["f1_rpm"] > FAN_MIN[1] + 300)
    peak = max(rows, key=lambda r: r["sysmax"])
    busy = [r for r in rows if r["watts"] > 20] or rows
    out = {
        "負荷開始からの計測時間 (秒)": rows[-1]["elapsed"],
        "負荷開始時 システム最高 (°C)": rows[0]["sysmax"],
        "ファンが回り始めた時刻 (秒)": spin["elapsed"] if spin else None,
        "  回り始めの温度 (°C)": spin["sysmax"] if spin else None,
        "最低回転を超えて上がり始めた時刻 (秒)": ramp["elapsed"] if ramp else None,
        "  上がり始めの温度 (°C)": ramp["sysmax"] if ramp else None,
        "最高温度 (°C)": peak["sysmax"],
        "  到達時刻 (秒)": peak["elapsed"],
        "100 °C 以上 (秒)": seconds_at_or_above(rows, 100),
        "105 °C 以上 (秒)": seconds_at_or_above(rows, 105),
        "110 °C 以上 (秒)": seconds_at_or_above(rows, 110),
        "fan0 最高 (rpm)": max(r["f0_rpm"] for r in rows),
        "fan1 最高 (rpm)": max(r["f1_rpm"] for r in rows),
        "fan0 最高 (定格比 %)": 100 * max(r["f0_rpm"] for r in rows) / FAN_MAX[0],
        "平均温度 負荷中 (°C)": sum(r["sysmax"] for r in busy) / len(busy),
        "平均電力 負荷中 (W)": sum(r["watts"] for r in busy) / len(busy),
        "最初の 3 フレーム平均 (秒)": sum(ft[:3]) / 3 if len(ft) >= 3 else None,
        "最後の 5 フレーム平均 (秒)": sum(ft[-5:]) / 5 if len(ft) >= 5 else None,
        "レンダリング総時間 (秒)": total,
        "完了フレーム数": float(len(ft)),
    }
    return out


def fmt(v):
    if v is None:
        return "—"
    return f"{v:,.0f}" if abs(v) >= 1000 else f"{v:.1f}"


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    a, b = summarise(sys.argv[1]), summarise(sys.argv[2])
    la, lb = os.path.basename(sys.argv[1]), os.path.basename(sys.argv[2])
    w = max(len(k) for k in a) + 2
    print(f"{'':{w}}{la:>22}{lb:>22}{'差':>10}")
    for k in a:
        va, vb = a[k], b[k]
        d = "" if va is None or vb is None else ("+" if vb - va >= 0 else "") + fmt(vb - va)
        print(f"{k:{w}}{fmt(va):>22}{fmt(vb):>22}{d:>10}")


main()
