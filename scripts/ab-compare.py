#!/usr/bin/env python3
"""Compares two ab-test runs.

The question is whether holding Ftst relaxes the SoC's thermal limiter. Watts alone are
ambiguous, so the render time is the primary signal: identical work, so if run B finishes
faster at the same fan speed and temperature, the limiter behaved differently.
"""
import csv
import os
import statistics
import sys


def load(path):
    rows = list(csv.DictReader(open(path), delimiter="\t"))
    out = []
    for r in rows:
        try:
            out.append({
                "elapsed": float(r["elapsed"]),
                "temp": float(r["sysmax"]),
                "watts": float(r["watts"]),
                "rpm0": float(r["f0_rpm"]),
                "rpm1": float(r["f1_rpm"]),
                "ftst": float(r.get("ftst", 255)),
            })
        except (ValueError, KeyError):
            continue
    return out


def frames(path):
    if not os.path.exists(path):
        return [], None
    times, total = [], None
    for line in open(path):
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "BENCH_FRAME":
            times.append(float(parts[2]))
        elif len(parts) >= 2 and parts[0] == "BENCH_TOTAL":
            total = float(parts[1])
    return times, total


def steady(rows, skip_fraction=0.35):
    """Drop the warm-up: only the thermally settled tail is comparable."""
    start = int(len(rows) * skip_fraction)
    return rows[start:] if len(rows) > 10 else rows


def describe(label, path):
    rows = load(path)
    if not rows:
        print(f"  {label}: データがありません ({path})")
        return None
    tail = steady(rows)
    ft = frames(path.replace(".tsv", "-frames.txt"))
    stats = {
        "label": label,
        "n": len(rows),
        "temp": statistics.mean(r["temp"] for r in tail),
        "temp_max": max(r["temp"] for r in rows),
        "watts": statistics.mean(r["watts"] for r in tail if r["watts"] > 0),
        "rpm0": statistics.mean(r["rpm0"] for r in tail),
        "rpm1": statistics.mean(r["rpm1"] for r in tail),
        "ftst": statistics.mode(r["ftst"] for r in tail),
        "frames": ft[0],
        "total": ft[1],
        "rows": rows,
    }
    print(f"  {label}  サンプル {stats['n']}  Ftst={stats['ftst']:.0f}")
    print(f"    定常時の平均温度 : {stats['temp']:.1f} °C  (最高 {stats['temp_max']:.1f})")
    print(f"    定常時の平均電力 : {stats['watts']:.1f} W")
    print(f"    定常時の平均回転 : fan0 {stats['rpm0']:.0f} / fan1 {stats['rpm1']:.0f} rpm")
    if stats["total"]:
        print(f"    レンダリング総時間: {stats['total']:.1f} 秒"
              f"  (フレーム平均 {statistics.mean(stats['frames']):.2f} 秒)")
    print()
    return stats


def main(a_path, b_path):
    print("=== 各条件 ===")
    a = describe("A (macOS 標準)", a_path)
    b = describe("B (アプリ制御)", b_path)
    if not a or not b:
        return

    print("=== 比較 ===")
    print(f"  回転数の差   : fan0 {b['rpm0'] - a['rpm0']:+.0f} rpm"
          "   ← 小さいほど条件が揃っています")
    print(f"  温度の差     : {b['temp'] - a['temp']:+.1f} °C")
    print(f"  電力の差     : {b['watts'] - a['watts']:+.1f} W")
    if a["total"] and b["total"]:
        delta = (b["total"] - a["total"]) / a["total"] * 100
        print(f"  所要時間の差 : {b['total'] - a['total']:+.1f} 秒 ({delta:+.1f} %)")
    print()

    print("=== 解釈 ===")
    if abs(b["rpm0"] - a["rpm0"]) > 600:
        print("  ⚠️ 回転数が揃っていません。B の rpm を A の平均に合わせて取り直してください。")
        print("     このままでは「冷却の差」と「制御の差」を区別できません。")
        return
    if not (a["total"] and b["total"]):
        print("  レンダリング時間が取れていないため、性能の比較ができません。")
        return

    faster = (a["total"] - b["total"]) / a["total"] * 100
    fa, fb = a["frames"], b["frames"]
    tail = min(5, len(fa), len(fb))
    tail_a = statistics.mean(fa[-tail:]) if tail else 0
    tail_b = statistics.mean(fb[-tail:]) if tail else 0

    print(f"  総時間では B が {faster:+.1f} % 速い")
    if tail:
        tail_delta = (tail_a - tail_b) / tail_a * 100
        print(f"  ただし最後の {tail} フレームでは B が {tail_delta:+.1f} % "
              f"（A {tail_a:.1f} 秒 / B {tail_b:.1f} 秒）")
    print()

    # The total alone is misleading. macOS leaves the fans stopped for the first minute of a
    # load, so run A pays a large penalty early that has nothing to do with any limiter.
    if tail and abs((tail_a - tail_b) / tail_a * 100) > 5 and faster > 0:
        print("  ⚠️ 総時間と定常状態で符号が逆です。この差は「リミッターの違い」ではなく")
        print("     「立ち上がりの冷却の違い」で説明できます。macOS は負荷開始から")
        print("     しばらくファンを回さないため、A は序盤に大きく損をしています。")
        print("     熱履歴が違う以上、この実験でリミッターの挙動は分離できません。")
    elif faster > 3:
        print("  定常状態でも B が速いので、冷却以外の要因（リミッターの緩み）が示唆されます。")
    else:
        print("  所要時間に有意な差はありません。")

    print()
    print("  === 熱ストレス（こちらが本題）===")
    print("  TDDB による劣化は温度に対して指数的なので、平均より高温側の裾が効きます。")
    for lo in (100, 105, 110, 115):
        ca = sum(1 for r in a["rows"] if r["temp"] >= lo)
        cb = sum(1 for r in b["rows"] if r["temp"] >= lo)
        print(f"    {lo} °C 以上: A {ca:4d} 秒 / B {cb:4d} 秒")
    print(f"    最高温度  : A {a['temp_max']:.1f} °C / B {b['temp_max']:.1f} °C")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("使い方: ab-compare.py <ab-A.tsv> <ab-B.tsv>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
