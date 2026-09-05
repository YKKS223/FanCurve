import Foundation
import FanCurveKit

/// Grabs the fan **before** Apple's controller wants it, then holds a high target while the
/// machine heats up — the operating mode a boost feature would actually use.
///
/// This is the case `contest` did not cover. `contest` started once Apple was already driving
/// the fan and showed we cannot wrest it back. Here we start from `F%dMd == 3` (fan stopped,
/// firmware target 0, nobody driving) and watch what happens as the die crosses 80 °C:
/// either Apple's controller engages and overwrites us down to its own minimum, or it never
/// engages because the fan is already doing the job.
enum Hold {

    static func run(fanIndex: Int?, rpm requestedRPM: Double?, seconds: Double, path: String) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        guard let hw = fc.fans.first(where: { $0.index == (fanIndex ?? fc.fans.first?.index ?? 0) }) else {
            print("ファンが見つかりません。"); return 1
        }
        let i = hw.index
        let catalog = SensorCatalog()
        catalog.discover()
        func temp() -> Double { catalog.systemMax(in: catalog.readAll()) ?? 0 }
        func watts() -> Double { SMC.shared.readDouble("PSTR") ?? 0 }

        // --- must start from a fan Apple is not driving --------------------------------
        print("Apple がファンを手放すのを待ちます（回転が止まるまで / 最大 10 分）")
        print("いまファンが回っている場合は、負荷を止めて冷えるのを待ってください。\n")
        let waitStart = Date()
        while Date().timeIntervalSince(waitStart) < 600 {
            let r = fc.actualRPM(i), md = fc.modeByte(i), tg = fc.targetRPM(i)
            if r < 500 && tg == 0 {
                print("\n開始条件を満たしました: fan\(i) \(Int(r)) rpm, Tg=0, Md=\(md), \(String(format: "%.1f", temp())) °C\n")
                break
            }
            if Int(Date().timeIntervalSince(waitStart)) % 15 == 0 {
                print(String(format: "  待機中… fan%d %4.0f rpm  Tg=%4.0f  Md=%d  %5.1f °C",
                             i, r, tg, md, temp()))
                fflush(stdout)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard fc.actualRPM(i) < 500, fc.targetRPM(i) == 0 else {
            print("ファンが止まりませんでした。時間切れです。"); return 2
        }

        let target = min(hw.maxRPM, requestedRPM ?? 6000)
        print("目標 \(Int(target)) rpm を 2 Hz で書き続けます（\(Int(seconds)) 秒）。")
        print("開始したら負荷をかけてください。80 °C を超えた瞬間に何が起きるかを見ます。")
        print("Ctrl-C で中断。\n")

        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            print("ファイルを作成できません: \(path)"); return 1
        }
        handle.write("elapsed\ttemp\twatts\tours\ttg_readback\trpm\tmd\theld\n".data(using: .utf8)!)

        var takeoverAt: (elapsed: Double, temp: Double, watts: Double, appleTarget: Double)?
        var maxTempWhileHeld = 0.0
        var maxRPM = 0.0
        var skipped = 0
        var writeErrors = 0
        var abortedNoEffect = false
        let start = Date()
        var lastPrint = Date.distantPast

        while Date().timeIntervalSince(start) < seconds {
            let readback = fc.targetRPM(i)

            // Only ever ask for more airflow. If the firmware has decided it wants a higher
            // target than ours, leave it alone rather than holding the fan down.
            if readback <= target + 50 {
                do { try SMC.shared.writeFloat("F\(i)Tg", Float(target)) }
                catch {
                    writeErrors += 1
                    if writeErrors <= 3 { print("   書き込み失敗: \(error)") }
                }
            } else {
                skipped += 1
            }

            Thread.sleep(forTimeInterval: 0.5)

            let elapsed = Date().timeIntervalSince(start)
            let tg = fc.targetRPM(i)
            let rpm = fc.actualRPM(i)
            let md = fc.modeByte(i)
            let t = temp(), w = watts()
            // "Held" means the fan is physically doing what we asked. An earlier version of
            // this test treated a Tg readback of 0 as "held", which reported success while the
            // fan sat at 0 rpm and the die climbed to 117 °C. Judge by the tachometer only.
            let held = rpm >= target * 0.6
            maxRPM = max(maxRPM, rpm)
            if held { maxTempWhileHeld = max(maxTempWhileHeld, t) }

            if !held && takeoverAt == nil && elapsed > 3 {
                takeoverAt = (elapsed, t, w, tg)
                print(String(format: "\n⚠️  %.0f 秒 / %.1f °C / %.0f W で Apple が引き取りました。firmware の目標 %.0f rpm\n",
                             elapsed, t, w, tg))
            }

            handle.write(String(format: "%.0f\t%.1f\t%.1f\t%.0f\t%.0f\t%.0f\t%d\t%d\n",
                                elapsed, t, w, target, tg, rpm, md, held ? 1 : 0)
                            .data(using: .utf8)!)

            // Refuse to keep "testing" while doing nothing: if the fan has not responded
            // within 20 s of writing, the write is not working and heating the machine
            // further proves nothing.
            if elapsed > 20, maxRPM < 800 {
                print("\n❌ 20 秒書き続けてもファンが回りません。書き込みが効いていないので中断します。")
                print("   （書き込みエラー \(writeErrors) 回）")
                abortedNoEffect = true
                break
            }

            if Date().timeIntervalSince(lastPrint) >= 5 {
                lastPrint = Date()
                print(String(format: "%4.0f s  %5.1f °C  %5.1f W  fan%d %4.0f rpm  Tg=%4.0f  Md=%d  %@",
                             elapsed, t, w, i, rpm, tg, md, held ? "保持" : "★奪われた"))
                fflush(stdout)
            }
        }
        handle.closeFile()

        // Release only if we still own the fan. If Apple took over, writing anything here
        // would be a request to slow down.
        let finalReadback = fc.targetRPM(i)
        if abs(finalReadback - target) <= 100 {
            try? SMC.shared.writeFloat("F\(i)Tg", 0)
            print("\nファンを解放しました（Tg=0）。")
        } else {
            print("\nApple が制御中のため、何も書かずに終了します。")
        }

        if abortedNoEffect {
            print("\n先に `sudo fancurvectl writetest` で書き込みが効く条件を確かめてください。")
            return 3
        }

        print("\n=== 結論 ===")
        print(String(format: "こちらが保持できた最高温度 : %.1f °C", maxTempWhileHeld))
        print(String(format: "到達した最大回転数         : %.0f rpm（要求 %.0f）", maxRPM, target))
        if skipped > 0 { print("firmware がこちらより高い目標を出したため書き込みを見送った回数: \(skipped)") }
        if let t = takeoverAt {
            print(String(format: "Apple が引き取った時点       : %.0f 秒 / %.1f °C / %.0f W → firmware 目標 %.0f rpm",
                         t.elapsed, t.temp, t.watts, t.appleTarget))
            print("→ 先に掴んでいても、この温度で Apple に取り上げられます。ブーストの上限はここです。")
        } else {
            print("Apple は最後まで引き取りませんでした。")
            print("→ 先に掴んでおけば 80 °C を超えても制御を維持できます。ブースト方式は成立します。")
        }
        print("\nTSV: \(path)")
        return 0
    }
}
