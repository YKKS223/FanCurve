import Foundation
import FanCurveKit

/// Deliberately leaves the machine in manual fan control and then never cleans up, so the
/// caller can SIGKILL this process and watch whether macOS recovers on its own.
///
/// This answers by experiment what the literature is contradictory about: whether
/// `thermalmonitord` can reclaim the fans while `Ftst` is still set. The target is deliberately
/// a **high** RPM — if the state does turn out to be sticky, the machine is left cooling too
/// hard rather than not at all, which is loud but harmless.
enum Hang {

    static func run(fanIndex: Int?, rpm: Double) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        guard let hw = fc.fans.first(where: { $0.index == (fanIndex ?? fc.fans.first?.index ?? 0) }) else {
            print("ファンが見つかりません."); return 1
        }
        let i = hw.index
        // Refuse a low target: a stuck low fan is the one outcome this test must not create.
        let target = max(rpm, hw.maxRPM * 0.6)

        let report = fc.unlockManualControl(fanIndex: i)
        print("unlock: \(report.detail)")
        guard report.succeeded else {
            fc.restoreSystemControl()
            print("手動モードに入れませんでした。Ftst=0 に戻して終了します。")
            return 2
        }
        switch fc.setManualTarget(i, rpm: target) {
        case .success(let v): print("target: \(Int(v)) rpm")
        case .failure(let e): print("target 書き込み失敗: \(e)")
        }
        print("READY pid=\(getpid())")
        fflush(stdout)

        // No signal handling, no cleanup: the caller is expected to SIGKILL us.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
}

/// Read-only dump of arbitrary SMC keys, for watching state from outside a test.
enum Keys {
    static func run(_ names: [String]) -> Int32 {
        for name in names {
            guard let meta = SMC.shared.meta(name) else { print("\(name)\tなし"); continue }
            let raw = SMC.shared.readRaw(name)
            let hex = raw?.bytes.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "-"
            let value = SMC.shared.readDouble(name).map { String(format: "%.1f", $0) } ?? "-"
            print("\(name)\t\(meta.type)\t\(hex)\t\(value)")
        }
        return 0
    }
}
