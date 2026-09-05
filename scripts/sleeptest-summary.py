#!/usr/bin/env python3
"""Reads the TSV from sleeptest.sh and says whether fan control survived the sleep.

A sleep shows up as a gap in the timestamps: the logger is suspended along with everything
else, so nothing can be recorded during it. What matters is the state either side of the gap.
"""
import csv
import datetime
import sys


def parse_time(row):
    return datetime.datetime.strptime(row["time"], "%H:%M:%S")


def number(row, key):
    try:
        return float(row[key])
    except (ValueError, KeyError):
        return float("nan")


def main(path):
    rows = list(csv.DictReader(open(path), delimiter="\t"))
    if len(rows) < 3:
        print("  サンプルが足りません")
        return

    gap = None
    for i in range(1, len(rows)):
        seconds = (parse_time(rows[i]) - parse_time(rows[i - 1])).total_seconds()
        if seconds > 20:
            gap = (i, seconds)
            break

    if gap is None:
        print("  ⚠️ 時刻の空白がありません。この記録の間、Mac はスリープしていません。")
        print(f"  記録: {rows[0]['time']} 〜 {rows[-1]['time']}（{len(rows)} サンプル）")
        return

    index, seconds = gap
    before, after = rows[index - 1], rows[index]
    print(f"  スリープを検出: {before['time']} → {after['time']}（{seconds / 60:.1f} 分）")
    print()
    print("  %-10s %-6s %-6s %-9s %-9s %s" % ("時刻", "Ftst", "Md", "指示Tg", "実回転", "備考"))

    def show(row, note=""):
        print("  %-10s %-6s %-6s %-9s %-9s %s"
              % (row["time"], row["ftst"], row["f0_md"], row["f0_tg"], row["f0_ac"], note))

    show(before, "← スリープ直前")
    show(after, "← 復帰直後")
    for target in (30, 60):
        later = [r for r in rows[index:]
                 if (parse_time(r) - parse_time(after)).total_seconds() >= target]
        if later:
            show(later[0], f"← 復帰 {target} 秒後")
    print()

    wanted = number(before, "f0_tg")
    tolerance = max(300, wanted * 0.1)
    recovered = None
    for row in rows[index:]:
        if abs(number(row, "f0_ac") - wanted) < tolerance:
            recovered = (parse_time(row) - parse_time(after)).total_seconds()
            break

    print("  === 判定 ===")
    if number(before, "ftst") == 1 and number(after, "ftst") == 0:
        print("  ・firmware がスリープで Ftst をリセットしました（文献どおり）")
    else:
        print(f"  ・Ftst は復帰直後も {after['ftst']} でした（リセットされていません）")

    if recovered is not None:
        print(f"  ✅ 復帰 {recovered:.0f} 秒後に指示どおりの回転数（約 {wanted:.0f} rpm）へ戻りました")
        print("     → スリープをまたいでも制御は継続できています")
    else:
        print(f"  ❌ 記録の最後まで、指示値 {wanted:.0f} rpm に戻りませんでした")
        print("     → スリープ復帰後に制御が効かなくなっています。要修正です")


if __name__ == "__main__":
    main(sys.argv[1])
