import Foundation
import FanCurveKit

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    fancurvectl — FanCurve のコマンドライン操作

    デーモン経由:
      status                 現在の温度・ファン回転数・モードを表示
      sensors [--all]        温度センサー一覧（--all で全キー）
      mode <system|curve|manual>
      manual <fan> <rpm>     手動モードの回転数を設定
      probe [fan] [rpm]      ファン制御が効くか実測（約15秒、ファンが回ります）
      reset                  全ファンをシステム制御へ戻す
      config                 現在の設定 JSON を表示
      config set <file.json> 設定 JSON を読み込ませる

    デーモン不要（直接 SMC を叩く / root 必須）:
      diag [fan] [rpm]       制御方式を総当たりして SMC の応答を全部表示（推奨）
      contest [fan] [rpm]    Apple が制御中の高温域で Tg を奪えるか実測（要負荷）
      hold [fan] [rpm] [秒]  先にファンを掴んだまま昇温したらどうなるかを実測（要負荷）
      writetest [fan]        Tg 書き込みが効く条件を4通り試す（アイドルのまま・負荷不要）
      unlocktest [fan] [rpm] Ftst による正式な解除手順を実行し、復帰まで検証（負荷不要）
      keys <KEY>...          任意の SMC キーを読み出す（root 不要・読み取りのみ）
      waitzero <KEY> [秒]    キーが 0 になる瞬間を高頻度で待つ（root 不要・読み取りのみ）
      hang [fan] [rpm]       手動制御のまま後片付けせず居座る（SIGKILL 復帰試験用）
      selftest [fan] [rpm]   デーモン無しで制御可否を実測
      dump                   温度センサーを直接読み出して表示
      watch [秒] [出力.tsv]  温度とファン回転数を1秒ごとに記録（root 不要・書き込み一切なし）
      panic                  直接 SMC を叩いて全ファンをシステム制御へ戻す
    """)
    exit(1)
}

guard let command = args.first else { usage() }

// MARK: - Direct-SMC commands (no daemon required)

func requireRoot() {
    if geteuid() != 0 {
        FileHandle.standardError.write("このコマンドには root 権限が必要です: sudo fancurvectl \(command)\n".data(using: .utf8)!)
        exit(1)
    }
}

func openSMC() {
    do { try SMC.shared.open() }
    catch { print("SMC を開けません: \(error)"); exit(1) }
}

switch command {
case "waitzero":
    // Polls fast enough to time a launchd restart. Reads only, so no root needed.
    openSMC()
    guard args.count > 1 else { print("waitzero <KEY> [秒]"); exit(1) }
    let wkey = args[1]
    let wtimeout = args.count > 2 ? Double(args[2]) ?? 30 : 30
    let wstart = Date()
    var cleared: Double?
    while Date().timeIntervalSince(wstart) < wtimeout {
        if let v = SMC.shared.readUInt8(wkey), v == 0 {
            cleared = Date().timeIntervalSince(wstart)
            break
        }
        usleep(5000)
    }
    if let c = cleared {
        print(String(format: "CLEARED %.3f", c))
    } else {
        print("TIMEOUT")
    }
    SMC.shared.close()
    exit(cleared == nil ? 1 : 0)

case "keys":
    openSMC()
    let rck = Keys.run(Array(args.dropFirst()))
    SMC.shared.close()
    exit(rck)

case "hang":
    requireRoot()
    openSMC()
    let gfan = args.count > 1 ? Int(args[1]) : nil
    let grpm = args.count > 2 ? Double(args[2]) ?? 5000 : 5000
    exit(Hang.run(fanIndex: gfan, rpm: grpm))

case "watch":
    // Deliberately does not require root: this command must be incapable of writing.
    openSMC()
    let seconds = args.count > 1 ? Int(args[1]) ?? 900 : 900
    let defaultName = "fancurve-watch-\(Int(Date().timeIntervalSince1970)).tsv"
    let out = args.count > 2 ? args[2]
        : FileManager.default.currentDirectoryPath + "/" + defaultName
    let rc = Watch.run(seconds: seconds, path: out)
    SMC.shared.close()
    exit(rc)

case "diag":
    requireRoot()
    openSMC()

    // The daemon would fight us for the fans, so park it in system mode — and put the user's
    // mode back afterwards, including when the diagnostic is interrupted.
    let diagClient = DaemonClient()
    var modeToRestore: ControlMode?
    if let current = try? diagClient.send(DaemonRequest(cmd: .getConfig)), let cfg = current.config {
        if cfg.mode != .system,
           let r = try? diagClient.send(DaemonRequest(cmd: .setMode, mode: .system)), r.ok {
            modeToRestore = cfg.mode
            print("（デーモンを一時的にシステム標準モードにしました。終了時に「\(cfg.mode.displayName)」へ戻します）\n")
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    func restoreDaemonMode() {
        guard let mode = modeToRestore else { return }
        modeToRestore = nil
        if let r = try? diagClient.send(DaemonRequest(cmd: .setMode, mode: mode)), r.ok {
            print("デーモンのモードを「\(mode.displayName)」に戻しました。")
        } else {
            print("⚠️ モードを戻せませんでした。手動で: fancurvectl mode \(mode.rawValue)")
        }
    }

    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            // Best effort on Ctrl-C: hand the fans back and let the daemon resume.
            let fc = FanController()
            fc.forceReleaseAll()
            _ = try? DaemonClient().send(DaemonRequest(cmd: .reset))
            print("\n中断されました。fancurvectl mode <元のモード> で戻してください。")
            exit(130)
        }
    }

    let fan = args.count > 1 ? Int(args[1]) : nil
    let rpm = args.count > 2 ? Double(args[2]) ?? 4000 : 4000
    print("ファンを回して各方式を試します。1 ファンあたり 20 秒ほどかかります。\n")
    let rc = Diag.run(fanIndex: fan, requestRPM: rpm, settle: 8)
    restoreDaemonMode()
    SMC.shared.close()
    exit(rc)

case "unlocktest":
    requireRoot()
    openSMC()
    let ufan = args.count > 1 ? Int(args[1]) : nil
    let urpm = args.count > 2 ? Double(args[2]) ?? 4000 : 4000
    let rcu = UnlockTest.run(fanIndex: ufan, rpm: urpm, holdSeconds: 12)
    SMC.shared.close()
    exit(rcu)

case "writetest":
    requireRoot()
    openSMC()
    let wfan = args.count > 1 ? Int(args[1]) : nil
    let rcw = WriteTest.run(fanIndex: wfan)
    SMC.shared.close()
    exit(rcw)

case "hold":
    requireRoot()
    openSMC()
    let hfan = args.count > 1 ? Int(args[1]) : nil
    let hrpm = args.count > 2 ? Double(args[2]) : nil
    let hsec = args.count > 3 ? Double(args[3]) ?? 600 : 600
    let hout = FileManager.default.currentDirectoryPath + "/fancurve-hold-\(Int(Date().timeIntervalSince1970)).tsv"
    let rch = Hold.run(fanIndex: hfan, rpm: hrpm, seconds: hsec, path: hout)
    SMC.shared.close()
    exit(rch)

case "contest":
    requireRoot()
    openSMC()
    let cfan = args.count > 1 ? Int(args[1]) : nil
    let crpm = args.count > 2 ? Double(args[2]) : nil
    let rcc = Contest.run(fanIndex: cfan, requestedRPM: crpm, waitSeconds: 900)
    SMC.shared.close()
    exit(rcc)

case "selftest":
    requireRoot()
    openSMC()
    let fc = FanController()
    fc.enumerateFans()
    guard !fc.fans.isEmpty else { print("ファンが見つかりません（ファンレス機種の可能性）"); exit(1) }
    let idx = args.count > 1 ? Int(args[1]) ?? fc.fans[0].index : fc.fans[0].index
    let want = args.count > 2 ? Double(args[2]) ?? 3500 : 3500
    guard let hw = fc.fans.first(where: { $0.index == idx }) else { print("ファン \(idx) がありません"); exit(1) }

    print("検出したファン:")
    for f in fc.fans { print("  fan\(f.index)  \(Int(f.minRPM))–\(Int(f.maxRPM)) rpm  現在 \(Int(fc.actualRPM(f.index))) rpm  F\(f.index)Md=\(fc.modeByte(f.index))") }
    print("\nfan\(idx) を \(Int(fc.clamp(idx, want))) rpm に上げてみます（最大 \(Int(hw.maxRPM)) rpm）。")
    print("15 秒ほどファンが回ります。終わったら元の状態に戻します…\n")

    let r = fc.probeControlMode(fanIndex: idx, requestRPM: want)
    print("元の状態      : F\(idx)Md=\(r.originalMode)  F\(idx)Tg=\(Int(r.originalTarget))  実回転 \(Int(r.baselineRPM)) rpm")
    print("目標だけ書込  : \(Int(r.tgOnlyRPM)) rpm")
    if r.tgPlusModeRPM >= 0 {
        print("Md=1 + 目標   : \(Int(r.tgPlusModeRPM)) rpm")
    }
    if let e = r.writeError { print("書き込みエラー: \(e)") }
    print("")
    if r.worked {
        print("✅ 制御できます。方式: \(r.needsModeKey ? "F\(idx)Md=1 が必要" : "F\(idx)Tg の書き込みだけで有効")")
    } else {
        print("❌ ファンが応答しませんでした。SIP や機種差の可能性があります。")
    }
    SMC.shared.close()
    exit(r.worked ? 0 : 2)

case "dump":
    openSMC()
    let cat = SensorCatalog()
    cat.discover()
    let readings = cat.readAll()
    print("温度センサー \(readings.count) 個\n")
    for g in SensorGroup.allCases {
        let inGroup = readings.filter { $0.group == g }.sorted { $0.value > $1.value }
        guard !inGroup.isEmpty else { continue }
        let mx = inGroup.first!.value
        print("[\(g.displayName)] 最高 \(String(format: "%.1f", mx)) °C  (\(inGroup.count) 個)")
        for r in inGroup.prefix(6) {
            print("    \(r.key)  \(String(format: "%6.1f", r.value)) °C")
        }
        if inGroup.count > 6 { print("    … 他 \(inGroup.count - 6) 個") }
    }
    let fc = FanController(); fc.enumerateFans()
    print("\nファン:")
    for f in fc.fans {
        print("  fan\(f.index)  \(String(format: "%5.0f", fc.actualRPM(f.index))) rpm  " +
              "目標 \(String(format: "%5.0f", fc.targetRPM(f.index)))  " +
              "範囲 \(Int(f.minRPM))–\(Int(f.maxRPM))  Md=\(fc.modeByte(f.index))")
    }
    SMC.shared.close()
    exit(0)

case "panic":
    requireRoot()
    openSMC()
    let fc = FanController()
    fc.enumerateFans()
    print("Ftst=\(fc.forceTestValue().map(String.init) ?? "?") から復帰します。")
    // Clearing the diagnostic flag is what actually hands the fans back: thermalmonitord
    // reclaims and restores mode 3 on its own. Zeroing the target as well would be a request
    // to stop the fan, so it is only done if we are still the ones in manual mode.
    fc.restoreSystemControl()
    let rec = fc.waitForSystemReclaim(fanIndex: fc.fans.first?.index ?? 0, timeout: 20)
    print(String(format: "Ftst=0 を書きました。mode が 3 に戻るまで %.1f 秒（現在 mode=%d）", rec.seconds, rec.mode))
    for f in fc.fans {
        print("  fan\(f.index)  \(Int(fc.actualRPM(f.index))) rpm  Md=\(fc.modeByte(f.index))  Tg=\(Int(fc.targetRPM(f.index)))")
    }
    print(rec.reclaimed ? "✅ システム制御に戻りました" : "⚠️ まだ mode 3 ではありません")
    SMC.shared.close()
    exit(rec.reclaimed ? 0 : 3)

default:
    break
}

// MARK: - Daemon-backed commands

let client = DaemonClient()

func call(_ req: DaemonRequest) -> DaemonResponse {
    do { return try client.send(req) }
    catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); exit(1) }
}

func bar(_ value: Double, _ maxValue: Double, width: Int = 24) -> String {
    let f = maxValue <= 0 ? 0 : max(0, min(1, value / maxValue))
    let filled = Int((Double(width) * f).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

switch command {
case "status":
    let r = call(DaemonRequest(cmd: .status))
    guard let s = r.status else { print("状態を取得できません: \(r.error ?? "?")"); exit(1) }
    print("モード: \(s.mode.displayName)\(s.emergency ? "   ⚠️ 緊急冷却中" : "")")
    if s.holdingControl {
        print("制御   : 🔒 このアプリが保持中（macOS は介入できません。下限 \(Int(s.boostFloorRPM)) rpm）")
    } else {
        print("制御   : macOS（このアプリは何も握っていません）")
    }
    if let b = s.boostBlockedReason, s.mode != .system {
        print("待機   : \(b)（この間はファンを macOS が管理します）")
    }
    if let f = s.failsafeReason { print("⚠️ フェイルセーフ作動中: \(f)") }
    if let e = s.lastError { print("直近のエラー: \(e)") }
    print("")
    for g in SensorGroup.allCases {
        if let v = s.groupMax[g.rawValue] {
            print(String(format: "  %-12@ %5.1f °C", g.displayName as NSString, v))
        }
    }
    if let m = s.systemMaxC { print(String(format: "  %-12@ %5.1f °C", "システム最高" as NSString, m)) }
    print("")
    for f in s.fans {
        let t = f.sourceTempC.map { String(format: "%.1f°C", $0) } ?? "—"
        let commanded = f.commandedRPM.map { String(format: "指示 %5.0f", $0) } ?? "指示なし  "
        print(String(format: "  %@  %5.0f rpm  [%@]  %@  %@  ← %@ (%@)",
                     f.name, f.actualRPM, bar(f.actualRPM, f.maxRPM), commanded as NSString,
                     f.controlled ? "制御中" : "システム", f.sourceLabel, t))
    }

case "sensors":
    let r = call(DaemonRequest(cmd: .listSensors))
    guard let sensors = r.sensors else { print("取得できません"); exit(1) }
    let showAll = args.contains("--all")
    for g in SensorGroup.allCases {
        let inGroup = sensors.filter { $0.group == g }.sorted { $0.value > $1.value }
        guard !inGroup.isEmpty else { continue }
        print("[\(g.displayName)]  最高 \(String(format: "%.1f", inGroup.first!.value)) °C")
        for s in (showAll ? inGroup[...] : inGroup.prefix(5)) {
            print("    \(s.key)  \(String(format: "%6.1f", s.value)) °C  \(s.name)")
        }
        if !showAll && inGroup.count > 5 { print("    … 他 \(inGroup.count - 5) 個 (--all で全表示)") }
    }

case "mode":
    guard args.count > 1, let m = ControlMode(rawValue: args[1]) else {
        print("mode <system|curve|manual>"); exit(1)
    }
    let r = call(DaemonRequest(cmd: .setMode, mode: m))
    print(r.ok ? "モードを \(m.displayName) にしました" : "失敗: \(r.error ?? "?")")

case "manual":
    guard args.count > 2, let fan = Int(args[1]), let rpm = Double(args[2]) else {
        print("manual <fan> <rpm>"); exit(1)
    }
    let r = call(DaemonRequest(cmd: .setManual, fanIndex: fan, rpm: rpm))
    print(r.ok ? "fan\(fan) を \(Int(rpm)) rpm に設定しました（mode manual で有効）" : "失敗: \(r.error ?? "?")")

case "probe":
    let fan = args.count > 1 ? Int(args[1]) : nil
    let rpm = args.count > 2 ? Double(args[2]) : nil
    print("約15秒、ファンを回して制御可否を確認します…")
    let r = call(DaemonRequest(cmd: .probe, fanIndex: fan, rpm: rpm))
    if let p = r.probe {
        print("baseline \(Int(p.baselineRPM)) rpm → 目標のみ \(Int(p.tgOnlyRPM)) rpm" +
              (p.tgPlusModeRPM >= 0 ? " → Md=1併用 \(Int(p.tgPlusModeRPM)) rpm" : ""))
        print(p.worked ? "✅ 制御できます（\(p.needsModeKey ? "Md キー必要" : "Tg のみで可")）"
                       : "❌ ファンが応答しませんでした")
    } else {
        print("失敗: \(r.error ?? "?")")
    }

case "reset":
    let r = call(DaemonRequest(cmd: .reset))
    print(r.ok ? "全ファンをシステム制御に戻しました" : "失敗: \(r.error ?? "?")")

case "config":
    if args.count > 2, args[1] == "set" {
        guard let data = FileManager.default.contents(atPath: args[2]),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            print("JSON を読めません: \(args[2])"); exit(1)
        }
        let r = call(DaemonRequest(cmd: .setConfig, config: cfg))
        print(r.ok ? "設定を適用しました" : "失敗: \(r.error ?? "?")")
    } else {
        let r = call(DaemonRequest(cmd: .getConfig))
        guard let cfg = r.config, let data = try? cfg.encoded() else { print("取得できません"); exit(1) }
        print(String(data: data, encoding: .utf8)!)
    }

default:
    usage()
}
