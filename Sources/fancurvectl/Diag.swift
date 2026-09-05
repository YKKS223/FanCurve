import Foundation
import FanCurveKit

/// Walks every way of asking the SMC to drive a fan and reports exactly what the
/// firmware said to each one. Written because `F%dMd` is refused on some Apple silicon
/// machines and the failure was otherwise invisible.
enum Diag {

    private static func status() -> String {
        let s = SMC.shared.lastStatus()
        return "SMC status=0x\(String(s, radix: 16)) (\(SMCError.statusName(s)))"
    }

    private static func attempt(_ label: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            print("    \(label): ✅ 受理  \(status())")
            return true
        } catch {
            print("    \(label): ❌ 拒否  \(error)")
            return false
        }
    }

    static func run(fanIndex: Int?, requestRPM: Double, settle: Double) -> Int32 {
        let fc = FanController()
        fc.enumerateFans()
        guard !fc.fans.isEmpty else {
            print("ファンが見つかりません。")
            return 1
        }

        let targets = fanIndex.map { idx in fc.fans.filter { $0.index == idx } } ?? fc.fans
        guard !targets.isEmpty else { print("指定のファンがありません。"); return 1 }

        print("=== 環境 ===")
        print("  euid            : \(geteuid())")
        print("  SIP             : \(sipStatus())")
        print("  ファン数        : \(fc.fans.count)")
        print("")

        var anyWorked = false

        for hw in targets {
            let i = hw.index
            let want = fc.clamp(i, requestRPM)
            print("=== fan\(i) (\(hw.defaultName)) ===")

            for key in ["F\(i)Ac", "F\(i)Mn", "F\(i)Mx", "F\(i)Tg", "F\(i)Md"] {
                if let m = SMC.shared.meta(key) {
                    let v = SMC.shared.readDouble(key).map { String(format: "%.1f", $0) } ?? "—"
                    print(String(format: "  %-5@ type=%-4@ size=%u attr=0x%02x %@%@  値=%@",
                                 key as NSString, m.type as NSString, m.size, m.attributes,
                                 m.isReadable ? "R" : "-", m.isWritable ? "W" : "-", v as NSString))
                }
            }

            print("  [0] ユーザークライアントの open セレクタ")
            let ucOpen = SMC.shared.userClientOpen()
            print("      IOConnectCallScalarMethod(selector 0) → \(ucOpen == 0 ? "✅ 成功" : "kern_return=0x\(String(UInt32(bitPattern: ucOpen), radix: 16))")")
            print("")

            let origMode = fc.modeByte(i)
            let origTarget = fc.targetRPM(i)
            let baseline = fc.actualRPM(i)
            print("  開始状態        : 実回転 \(Int(baseline)) rpm, F\(i)Tg=\(Int(origTarget)), F\(i)Md=\(origMode)")
            print("  目標            : \(Int(want)) rpm")
            print("")

            // --- 1. target only -------------------------------------------------
            print("  [1] F\(i)Tg のみ書き込み")
            let tgOK = attempt("write F\(i)Tg=\(Int(want))") {
                try SMC.shared.writeFloat("F\(i)Tg", Float(want))
            }
            if tgOK {
                print("    読み戻し F\(i)Tg = \(Int(fc.targetRPM(i)))  ※この読み戻しは firmware が嘘をつくので参考値")
                Thread.sleep(forTimeInterval: settle)
                let rpm = fc.actualRPM(i)
                let ok = rpm > baseline + 200 || rpm > want * 0.8
                print("    \(Int(settle)) 秒後の実回転: \(Int(rpm)) rpm  \(ok ? "→ ✅ 効いた" : "→ 反応なし")")
                if ok { anyWorked = true }
            }
            try? SMC.shared.writeFloat("F\(i)Tg", Float(origTarget))
            print("")

            // --- 2. mode key ----------------------------------------------------
            print("  [2] F\(i)Md に各値を書き込み（受理されるか）")
            print("      ⚠️ 元の値に戻せない場合があります（M3 Max では初期値 3 の書き戻しが拒否されます）。")
            print("         戻らなかったときは再起動で firmware の既定状態に戻ります。")
            for value in [UInt8(0), 1, 2, 3] {
                _ = attempt("write F\(i)Md=\(value)") { try SMC.shared.writeUInt8("F\(i)Md", value) }
                let readBack = fc.modeByte(i)
                print("        読み戻し F\(i)Md = \(readBack)")
                try? SMC.shared.writeUInt8("F\(i)Md", origMode)
            }
            print("")

            // --- 3. mode + target ----------------------------------------------
            print("  [3] F\(i)Md=1 と F\(i)Tg の併用")
            let mdOK = attempt("write F\(i)Md=1") { try SMC.shared.writeUInt8("F\(i)Md", 1) }
            if mdOK {
                _ = attempt("write F\(i)Tg=\(Int(want))") { try SMC.shared.writeFloat("F\(i)Tg", Float(want)) }
                Thread.sleep(forTimeInterval: settle)
                let rpm = fc.actualRPM(i)
                let ok = rpm > baseline + 200 || rpm > want * 0.8
                print("    \(Int(settle)) 秒後の実回転: \(Int(rpm)) rpm  \(ok ? "→ ✅ 効いた" : "→ 反応なし")")
                if ok { anyWorked = true }
            } else {
                print("    → この Mac は F\(i)Md を受け付けません。Tg 単独方式で動かす必要があります。")
            }

            // --- restore --------------------------------------------------------
            try? SMC.shared.writeUInt8("F\(i)Md", origMode)
            try? SMC.shared.writeFloat("F\(i)Tg", Float(origTarget))
            print("  復帰            : F\(i)Tg=0 を書き込み済み（読み戻しは信用できないので表示しません）"
                  + ", F\(i)Md=\(fc.modeByte(i))")
            print("")
        }

        print("=== 結論 ===")
        if anyWorked {
            print("✅ この Mac ではファン制御が可能です。上の [1]/[3] のどちらが効いたかを見てください。")
        } else {
            print("❌ どの方式でもファンが反応しませんでした。")
            print("   書き込みが「受理」されているのに回転数が変わらない場合、ファームウェアが値を")
            print("   受け取ってから無視しています。書き込み自体が「拒否」なら権限か SIP の問題です。")
        }
        return anyWorked ? 0 : 2
    }

    private static func sipStatus() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        p.arguments = ["status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "不明" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ") ?? "不明"
    }
}
