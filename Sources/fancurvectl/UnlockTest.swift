import Foundation
import FanCurveKit

/// Runs the documented M3+ unlock sequence once and reports every step, then proves the
/// machine goes back to exactly where it started.
///
/// The point of the third phase is the one that matters: writing `Ftst = 0` must hand the fan
/// back and let `thermalmonitord` restore mode 3. If it does, manual control costs nothing
/// permanent, which is the question this whole test exists to answer.
enum UnlockTest {

    /// Cleared on every exit path, including Ctrl-C, so diagnostic mode is never left engaged.
    nonisolated(unsafe) static var controller: FanController?

    static func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                UnlockTest.controller?.restoreSystemControl()
                print("\n中断されました。Ftst=0 を書いてシステム制御に戻しました。")
                exit(130)
            }
        }
    }

    static func run(fanIndex: Int?, rpm: Double, holdSeconds: Double) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        controller = fc
        installSignalHandlers()

        guard let hw = fc.fans.first(where: { $0.index == (fanIndex ?? fc.fans.first?.index ?? 0) }) else {
            print("ファンが見つかりません。"); return 1
        }
        let i = hw.index
        let mdKey = fc.modeKey(i)
        let catalog = SensorCatalog()
        catalog.discover()
        func temp() -> Double { catalog.systemMax(in: catalog.readAll()) ?? 0 }
        func state() -> String {
            String(format: "Ftst=%d  %@=%d  Tg=%.0f  Ac=%.0f rpm  %.1f °C",
                   fc.forceTestValue() ?? 255, mdKey as NSString,
                   SMC.shared.readUInt8(mdKey) ?? 255,
                   fc.targetRPM(i), fc.actualRPM(i), temp())
        }

        func cleanUp() {
            fc.restoreSystemControl()
        }

        print("=== 0. 開始状態 ===")
        print("  \(state())")
        print("  \(FanController.forceTestKey) キー: \(fc.supportsForceTest ? "あり（書き込み可）" : "なし")")
        print("  mode キー名: \(mdKey)")
        print("")

        // --- 1. unlock ------------------------------------------------------------------
        print("=== 1. 手動モードへの移行 ===")
        let report = fc.unlockManualControl(fanIndex: i)
        print("  直接書き込みの試行回数 : \(report.modeWriteAttempts)")
        print("  Ftst を使ったか        : \(report.usedForceTest ? "はい" : "いいえ（直接書き込みで通った）")")
        if report.usedForceTest {
            print(String(format: "  mode が 3 を抜けるまで : %.1f 秒（%d → %d）",
                         report.yieldSeconds, report.initialMode, report.modeAfterForceTest))
        }
        print("  結果                   : \(report.detail)")
        print("  \(state())")
        guard report.succeeded else {
            print("\n❌ 手動モードに入れませんでした。後片付けをします。")
            cleanUp()
            print("  \(state())")
            return 2
        }
        print("  ✅ 手動モードに入りました\n")

        // --- 2. does the fan actually move? ---------------------------------------------
        print("=== 2. 目標 \(Int(fc.clamp(i, rpm))) rpm を書いて \(Int(holdSeconds)) 秒待つ ===")
        switch fc.setManualTarget(i, rpm: rpm) {
        case .success(let applied): print("  書き込み \(Int(applied)) rpm: ✅ 受理")
        case .failure(let e):       print("  書き込み: ❌ \(e)")
        }
        var peak = 0.0
        let start = Date()
        while Date().timeIntervalSince(start) < holdSeconds {
            Thread.sleep(forTimeInterval: 2)
            let now = fc.actualRPM(i)
            peak = max(peak, now)
            print(String(format: "   %2.0f 秒: %4.0f rpm   %@", Date().timeIntervalSince(start), now, state() as NSString))
        }
        let spun = peak > 800
        print(spun ? "\n  ✅ ファンが回りました（最大 \(Int(peak)) rpm）\n"
                   : "\n  ❌ ファンが回りませんでした\n")

        // --- 3. the question that matters: does it hand back cleanly? --------------------
        print("=== 3. システム制御へ復帰（Ftst=0） ===")
        cleanUp()
        print("  Ftst=0 を書きました。thermalmonitord の回収を待ちます…")
        let reclaim = fc.waitForSystemReclaim(fanIndex: i, timeout: 20)
        print(String(format: "  mode が 3 に戻るまで: %.1f 秒（現在 mode=%d）", reclaim.seconds, reclaim.mode))
        print("  \(state())")

        print("\n=== 結論 ===")
        print(spun ? "制御       : ✅ Ftst 経由で手動制御できます"
                   : "制御       : ❌ 手動モードには入れたがファンが回りませんでした")
        if reclaim.reclaimed {
            print("後始末     : ✅ Ftst=0 で mode 3 に戻りました。**固定化しません**")
        } else {
            print("後始末     : ⚠️ mode が \(reclaim.mode) のままです（3 に戻っていません）")
            print("             負荷をかけて thermalmonitord を動かすか、様子を見てください。")
        }
        return spun && reclaim.reclaimed ? 0 : 3
    }
}
