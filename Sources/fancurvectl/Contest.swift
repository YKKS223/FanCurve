import Foundation
import FanCurveKit

/// Determines who wins `F%dTg` while Apple's own controller is actively driving the fan.
///
/// The 900-second baseline showed the firmware writing `F%dTg` itself (2,317 → 4,949 rpm), so
/// the register is shared. That leaves one question the app's whole value depends on: in the
/// 80–106 °C band, where Apple holds the fan at its minimum, can a write of ours survive long
/// enough to matter — and does writing faster help?
///
/// Safety: this test only ever asks for **more** airflow. A target below the firmware's own
/// target or below the current speed is refused, so the worst case is a fan running faster
/// than Apple intended. `F%dMd` is never written.
enum Contest {

    private struct Phase {
        let name: String
        let seconds: Double
        let writeHz: Double   // 0 = observe only
    }

    static func run(fanIndex: Int?, requestedRPM: Double?, waitSeconds: Double) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        guard let hw = fc.fans.first(where: { $0.index == (fanIndex ?? fc.fans.first?.index ?? 0) }) else {
            print("ファンが見つかりません。")
            return 1
        }
        let i = hw.index
        let catalog = SensorCatalog()
        catalog.discover()

        func temp() -> Double { catalog.systemMax(in: catalog.readAll()) ?? 0 }

        // --- wait for Apple to be the one driving --------------------------------------
        print("Apple の制御がファンを回し始めるのを待ちます（負荷をかけてください / 最大 \(Int(waitSeconds)) 秒）")
        print("中断は Ctrl-C。書き込みはまだ一切していません。\n")
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < waitSeconds {
            let rpm = fc.actualRPM(i)
            let md = fc.modeByte(i)
            if rpm > 1200 && md == 0 {
                print("\n検出: fan\(i) \(Int(rpm)) rpm, F\(i)Md=\(md), \(String(format: "%.1f", temp())) °C — Apple が制御中です。\n")
                break
            }
            if Int(Date().timeIntervalSince(waitStart)) % 10 == 0 {
                print(String(format: "  待機中… %5.1f °C  fan%d %4.0f rpm  Md=%d",
                             temp(), i, rpm, md))
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard fc.actualRPM(i) > 1200 else {
            print("ファンが回り始めませんでした。負荷が足りないか、時間切れです。")
            return 2
        }

        // --- pick a target that can only mean "cool harder" -----------------------------
        let firmwareTarget = fc.targetRPM(i)
        let actual = fc.actualRPM(i)
        let floor = max(firmwareTarget, actual) + 800
        let target = min(hw.maxRPM, max(requestedRPM ?? (floor + 1200), floor))
        guard target > max(firmwareTarget, actual) else {
            print("要求値 \(Int(target)) rpm が現在値を上回りません。中止します（冷却を弱める書き込みはしません）。")
            return 2
        }
        print("firmware の目標 \(Int(firmwareTarget)) rpm / 実回転 \(Int(actual)) rpm")
        print("こちらの要求   \(Int(target)) rpm（上限 \(Int(hw.maxRPM))）\n")

        var stop = false
        var skipped = 0

        /// Writes only when it can still only mean "cool harder".
        ///
        /// The firmware raises its own target as the machine heats up. If it ever asks for more
        /// than this test does, writing our fixed value would hold the fan *down* — the one
        /// outcome that must not be possible here — so the write is skipped instead.
        func writeIfStillAnIncrease() {
            let current = fc.targetRPM(i)
            guard current <= target + 50 else { skipped += 1; return }
            try? SMC.shared.writeFloat("F\(i)Tg", Float(target))
        }
        let phases = [
            Phase(name: "A: 観測のみ（firmware がどれくらいの頻度で Tg を書くか）", seconds: 6, writeHz: 0),
            Phase(name: "B: 1 回だけ書いて、上書きされるまでの時間を測る",        seconds: 6, writeHz: -1),
            Phase(name: "C: 毎秒 1 回書き続ける（アプリの既定と同じ頻度）",        seconds: 12, writeHz: 1),
            Phase(name: "D: 毎秒 20 回書き続ける",                                seconds: 12, writeHz: 20),
            Phase(name: "E: 毎秒 200 回書き続ける",                               seconds: 12, writeHz: 200),
        ]

        var results: [(String, String)] = []

        for phase in phases where !stop {
            print("── \(phase.name)")
            let start = Date()
            var rpmSamples: [Double] = []
            var tgSamples: [Double] = []
            var writes = 0
            var overwriteLatency: Double?

            if phase.writeHz < 0 {
                // Single write, then poll hard to see how long our value survives.
                writeIfStillAnIncrease()
                writes = 1
                let t0 = Date()
                while Date().timeIntervalSince(t0) < phase.seconds {
                    let tg = fc.targetRPM(i)
                    tgSamples.append(tg)
                    rpmSamples.append(fc.actualRPM(i))
                    if overwriteLatency == nil, abs(tg - target) > 50 {
                        overwriteLatency = Date().timeIntervalSince(t0)
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            } else {
                let interval = phase.writeHz > 0 ? 1.0 / phase.writeHz : 0.05
                var nextSample = Date()
                while Date().timeIntervalSince(start) < phase.seconds {
                    if phase.writeHz > 0 {
                        writeIfStillAnIncrease()
                        writes += 1
                    }
                    if Date() >= nextSample {
                        rpmSamples.append(fc.actualRPM(i))
                        tgSamples.append(fc.targetRPM(i))
                        nextSample = Date().addingTimeInterval(0.25)
                    }
                    Thread.sleep(forTimeInterval: interval)
                }
            }

            let peak = rpmSamples.max() ?? 0
            let last = rpmSamples.last ?? 0
            let held = tgSamples.filter { abs($0 - target) <= 50 }.count
            let heldPct = tgSamples.isEmpty ? 0 : Double(held) / Double(tgSamples.count) * 100

            var line = String(format: "   実回転 最大 %.0f / 終了時 %.0f rpm   Tg がこちらの値だった割合 %.0f%%   書込 %d 回",
                              peak, last, heldPct, writes)
            if let l = overwriteLatency {
                line += String(format: "\n   上書きされるまで %.0f ms", l * 1000)
            } else if phase.writeHz < 0 {
                line += "\n   6 秒間ずっと上書きされませんでした"
            }
            print(line)
            print(String(format: "   温度 %.1f °C\n", temp()))
            results.append((phase.name, line))

            if skipped > 0 {
                print("   （firmware がこちらより高い目標を出したため \(skipped) 回は書き込みを見送りました）")
                skipped = 0
            }
            if temp() > 110 {
                print("⚠️ 110 °C を超えたので中断します。")
                stop = true
            }
            if peak > target + 400 {
                print("⚠️ firmware がこちらの要求を上回って回しています。テストの意味がないので中断します。")
                stop = true
            }
        }

        // Stop writing. The firmware re-asserts its own target on its next cycle; we must not
        // write 0 here, because while Apple is managing the fan that would be a request to slow down.
        print("書き込みを停止しました。firmware が自分の目標値に戻します。")
        Thread.sleep(forTimeInterval: 3)
        print(String(format: "3 秒後: fan%d %.0f rpm  Tg=%.0f  Md=%d  %.1f °C",
                     i, fc.actualRPM(i), fc.targetRPM(i), fc.modeByte(i), temp()))

        print("\n=== 結論 ===")
        print("いずれかのフェーズで実回転が \(Int(target)) rpm 付近まで上がっていれば、80 °C 以上でも制御を奪えます。")
        print("どのフェーズでも firmware の目標値付近から動かなければ、この帯域は Apple の専有です。")
        return 0
    }
}
