import Foundation
import FanCurveKit

/// Finds out what actually makes an `F%dTg` write take effect, at idle, with no load.
///
/// `diag` spun the fan up with a single write; the `hold` loop wrote the same key at 2 Hz and
/// the fan never moved. Those two differ in more than one way, so each difference is tried
/// separately here. Nothing is inferred: every write reports the SMC status byte, and success
/// is judged only by the fan physically spinning up.
enum WriteTest {

    private static func rpm(_ fc: FanController, _ i: Int) -> Double { fc.actualRPM(i) }

    /// Writes and reports the firmware's answer instead of swallowing it.
    @discardableResult
    private static func write(_ key: String, _ value: Float) -> String {
        do {
            try SMC.shared.writeFloat(key, value)
            return "✅ 受理 (status=0x\(String(SMC.shared.lastStatus(), radix: 16)))"
        } catch {
            return "❌ \(error)"
        }
    }

    private static func waitUntilStopped(_ fc: FanController, _ i: Int, timeout: Double = 180) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if rpm(fc, i) < 500 { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    static func run(fanIndex: Int?) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        guard let hw = fc.fans.first(where: { $0.index == (fanIndex ?? fc.fans.first?.index ?? 0) }) else {
            print("ファンが見つかりません。"); return 1
        }
        let i = hw.index
        let catalog = SensorCatalog()
        catalog.discover()
        func temp() -> Double { catalog.systemMax(in: catalog.readAll()) ?? 0 }

        let target: Float = 4000
        print("fan\(i) で \(Int(target)) rpm の書き込み方法を 4 通り試します。負荷は不要です。")
        print("各回 10 秒回して、止めて、次へ進みます。全体で約 3 分。\n")

        guard rpm(fc, i) < 500 else {
            print("ファンが回っています（\(Int(rpm(fc, i))) rpm）。止まるまで待ってから実行してください。")
            return 2
        }

        struct Trial { let name: String; let body: (FanController, Int, Float) -> [String] }

        let trials: [Trial] = [
            Trial(name: "1) 1 回だけ書いて 10 秒待つ（diag と同じ）") { fc, i, t in
                var log = [write("F\(i)Tg", t)]
                Thread.sleep(forTimeInterval: 10)
                log.append("10 秒後: \(Int(rpm(fc, i))) rpm")
                return log
            },
            Trial(name: "2) user client の open を呼んでから 1 回書く") { fc, i, t in
                let rc = SMC.shared.userClientOpen()
                var log = ["open selector → \(rc == 0 ? "成功" : "kern=\(rc)")"]
                log.append(write("F\(i)Tg", t))
                Thread.sleep(forTimeInterval: 10)
                log.append("10 秒後: \(Int(rpm(fc, i))) rpm")
                return log
            },
            Trial(name: "3) 0.5 秒ごとに書き直す（hold と同じ／間に Tg を読む）") { fc, i, t in
                var log: [String] = []
                var statuses: [String] = []
                for n in 0..<20 {
                    _ = fc.targetRPM(i)                    // hold はここで読んでいた
                    let s = write("F\(i)Tg", t)
                    if n < 3 { statuses.append(s) }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                log.append("最初の 3 回: " + statuses.joined(separator: " / "))
                log.append("10 秒後: \(Int(rpm(fc, i))) rpm")
                return log
            },
            Trial(name: "4) 0.5 秒ごとに書き直す（間に Tg を読まない）") { fc, i, t in
                var log: [String] = []
                var statuses: [String] = []
                for n in 0..<20 {
                    let s = write("F\(i)Tg", t)
                    if n < 3 { statuses.append(s) }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                log.append("最初の 3 回: " + statuses.joined(separator: " / "))
                log.append("10 秒後: \(Int(rpm(fc, i))) rpm")
                return log
            },
        ]

        var results: [(String, Double)] = []
        for trial in trials {
            print("── \(trial.name)")
            print("   開始時: \(Int(rpm(fc, i))) rpm, \(String(format: "%.1f", temp())) °C")
            for line in trial.body(fc, i, target) { print("   \(line)") }
            let reached = rpm(fc, i)
            results.append((trial.name, reached))
            print("   → \(reached > 800 ? "✅ 回った" : "❌ 回らなかった")\n")

            print("   解放して停止を待ちます…")
            _ = write("F\(i)Tg", 0)
            if !waitUntilStopped(fc, i) { print("   ⚠️ 止まりませんでした。中断します。"); break }
            print("   停止しました。\n")
        }

        print("=== まとめ ===")
        for (name, reached) in results {
            print(String(format: "  %@  → %.0f rpm  %@", name as NSString, reached,
                         reached > 800 ? "✅" : "❌"))
        }
        print("\n最終状態: fan\(i) \(Int(rpm(fc, i))) rpm, Tg=\(Int(fc.targetRPM(i))), Md=\(fc.modeByte(i))")
        return 0
    }
}
